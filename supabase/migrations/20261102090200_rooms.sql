-- 20261102090200_rooms.sql
--
-- Private study rooms, membership intervals, invitations, messages, and the group schedule.
--
-- A room is private by construction: there is no directory and no discovery endpoint. Access
-- follows one rule — a live membership row — and every helper below derives the caller from
-- auth.uid() rather than from an argument, so a client cannot ask "is someone else a member?"

create type public.room_invite_policy as enum ('owner_only', 'all_members');
create type public.room_member_role as enum ('owner', 'member');
create type public.room_session_mode as enum ('focus', 'break');

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  invite_policy public.room_invite_policy not null default 'owner_only',
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint rooms_name_length check (char_length(btrim(name)) between 1 and 40)
);

create index rooms_owner_idx on public.rooms (owner_id);

comment on table public.rooms is
  'Private study room. Reachable only through membership; there is no public listing.';

-- Membership is stored as intervals rather than a single boolean so a removed member can rejoin
-- later without erasing the earlier period (plan §3). A session report can therefore always be
-- attributed to the membership it happened under.
create table public.room_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.room_member_role not null default 'member',
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  constraint room_members_removed_after_join check (removed_at is null or removed_at >= joined_at)
);

create unique index room_members_active_key
  on public.room_members (room_id, user_id)
  where removed_at is null;

-- Exactly one live owner per room.
create unique index room_members_owner_key
  on public.room_members (room_id)
  where role = 'owner' and removed_at is null;

create index room_members_user_idx
  on public.room_members (user_id)
  where removed_at is null;

create table public.room_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  -- SHA-256 of the lowercase code. The plaintext code is returned to the creator once and never
  -- stored, so a database leak does not hand out working invitations.
  code_hash text not null unique,
  max_uses integer not null default 1,
  uses integer not null default 0,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint room_invites_max_uses_range check (max_uses between 1 and 100),
  constraint room_invites_uses_count check (uses >= 0 and uses <= max_uses),
  constraint room_invites_hash_format check (code_hash ~ '^[a-f0-9]{64}$')
);

create index room_invites_room_idx on public.room_invites (room_id, created_at desc);

create table public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  -- Nullable and ON DELETE SET NULL so deleting an account leaves the message as "deleted user"
  -- instead of destroying the room's history (plan §5).
  author_id uuid references public.profiles (id) on delete set null,
  body text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint room_messages_body_length check (char_length(btrim(body)) between 1 and 500)
);

create index room_messages_room_created_idx on public.room_messages (room_id, created_at desc);
create index room_messages_author_recent_idx on public.room_messages (author_id, created_at desc);

create table public.room_sessions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  leader_id uuid not null references public.profiles (id) on delete cascade,
  mode public.room_session_mode not null default 'focus',
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint room_sessions_order check (ends_at > starts_at)
);

create index room_sessions_room_start_idx on public.room_sessions (room_id, starts_at desc);

comment on table public.room_sessions is
  'Leader-started group schedule for a room. This is the entity the phase brief calls '
  'room_schedules; the plan names it room_sessions and there is no separate schedule/instance '
  'split in the approved model.';

-- Helpers -------------------------------------------------------------------------
--
-- SECURITY DEFINER so a membership check does not recurse through the room_members policy,
-- with a pinned empty search_path and fully-qualified names to prevent resolution attacks.
-- Each caller-scoped helper takes only a room id and resolves the caller from auth.uid().
create function app.is_room_member(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.room_members m
     where m.room_id = p_room
       and m.user_id = auth.uid()
       and m.removed_at is null
  );
$$;

create function app.is_room_owner(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.room_members m
     where m.room_id = p_room
       and m.user_id = auth.uid()
       and m.role = 'owner'
       and m.removed_at is null
  );
$$;

-- Used by triggers and RPCs that must confirm some *other* user is a live member (assigning a
-- schedule leader, promoting an owner). Deliberately not executable by clients: it would answer
-- "is this other user a member?".
create function app.is_active_member(p_room uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.room_members m
     where m.room_id = p_room
       and m.user_id = p_user
       and m.removed_at is null
  );
$$;

revoke all on function app.is_room_member(uuid) from public;
revoke all on function app.is_room_owner(uuid) from public;
revoke all on function app.is_active_member(uuid, uuid) from public;

-- Policies call these as the signed-in user, so the caller needs USAGE on schema app plus
-- EXECUTE on the two caller-scoped helpers. They return a boolean about the caller only.
grant usage on schema app to authenticated;
grant execute on function app.is_room_member(uuid) to authenticated;
grant execute on function app.is_room_owner(uuid) to authenticated;

-- Schedule guard -----------------------------------------------------------------
--
-- The leader check lives in a trigger rather than in the policy, because app.is_active_member()
-- must not be executable by clients. A trigger function owned by the migration role can call it
-- without granting that privilege.
create function app.room_sessions_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.is_active_member(new.room_id, new.leader_id) then
    raise exception 'the schedule leader must be a current member of the room'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function app.room_sessions_before_insert() from public;

create trigger room_sessions_before_insert
  before insert on public.room_sessions
  for each row execute function app.room_sessions_before_insert();

-- Message guards ------------------------------------------------------------------
--
-- Length is a constraint; frequency is enforced here so an insert cannot slip past a client-side
-- check. Both raise and abort the statement, which is the intended outcome for a rate limit.
create function app.room_messages_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent integer;
begin
  select count(*)
    into v_recent
    from public.room_messages m
   where m.author_id = new.author_id
     and m.created_at > now() - interval '1 minute';

  if v_recent >= 20 then
    raise exception 'message rate limit reached' using errcode = '42901';
  end if;

  return new;
end;
$$;

-- Milestone 2 has no message editing: the only permitted update is a soft delete, and a deleted
-- message cannot be restored. One exception is required: deleting an account sets author_id to NULL
-- through the foreign key (ON DELETE SET NULL), and that internal update fires this trigger. Without
-- the exception, account deletion would fail with "messages cannot be edited". A client cannot
-- exploit it, because author_id is not in the UPDATE grant at all.
create function app.room_messages_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.body is distinct from old.body
     or new.room_id is distinct from old.room_id then
    raise exception 'messages cannot be edited' using errcode = '22023';
  end if;

  -- Author changes are refused except the foreign-key anonymisation, which can only clear it.
  if new.author_id is distinct from old.author_id and new.author_id is not null then
    raise exception 'a message cannot be reassigned to another author' using errcode = '22023';
  end if;

  if old.deleted_at is not null and new.deleted_at is null then
    raise exception 'a deleted message cannot be restored' using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function app.room_messages_before_insert() from public;
revoke all on function app.room_messages_before_update() from public;

create trigger room_messages_before_insert
  before insert on public.room_messages
  for each row execute function app.room_messages_before_insert();

create trigger room_messages_before_update
  before update on public.room_messages
  for each row execute function app.room_messages_before_update();

-- Row level security: rooms --------------------------------------------------------
alter table public.rooms enable row level security;
revoke all on public.rooms from anon, authenticated;
grant select (id, name, owner_id, invite_policy, created_at, archived_at) on public.rooms to authenticated;
grant update (name, invite_policy, archived_at) on public.rooms to authenticated;

create policy rooms_select_member
  on public.rooms
  for select
  to authenticated
  using (app.is_room_member(id));

-- Owner-only edits, and owner_id is not in the UPDATE grant: handing the room over must go
-- through public.transfer_room_ownership(), which also rewrites the membership roles.
create policy rooms_update_owner
  on public.rooms
  for update
  to authenticated
  using (app.is_room_owner(id))
  with check (app.is_room_owner(id));

-- Row level security: membership ---------------------------------------------------
alter table public.room_members enable row level security;
revoke all on public.room_members from anon, authenticated;
grant select on public.room_members to authenticated;

-- A member sees the roster of their own room. Everyone can always see their own membership rows,
-- including a removed one, so a client can tell that it was removed rather than that the room
-- vanished.
create policy room_members_select
  on public.room_members
  for select
  to authenticated
  using (user_id = (select auth.uid()) or app.is_room_member(room_id));

-- Row level security: invitations --------------------------------------------------
alter table public.room_invites enable row level security;
revoke all on public.room_invites from anon, authenticated;
-- code_hash is deliberately absent from the grant: not even the owner can read a stored hash.
grant select (id, room_id, created_by, max_uses, uses, expires_at, revoked_at, created_at)
  on public.room_invites to authenticated;

create policy room_invites_select_inviter
  on public.room_invites
  for select
  to authenticated
  using (app.is_room_owner(room_id) or created_by = (select auth.uid()));

-- Row level security: messages -----------------------------------------------------
alter table public.room_messages enable row level security;
revoke all on public.room_messages from anon, authenticated;
grant select on public.room_messages to authenticated;
grant insert (room_id, author_id, body) on public.room_messages to authenticated;
grant update (deleted_at) on public.room_messages to authenticated;

-- A removed member loses message access immediately, which is what makes removal meaningful.
create policy room_messages_select_member
  on public.room_messages
  for select
  to authenticated
  using (
    app.is_room_member(room_id)
    and (
      deleted_at is null
      or author_id = (select auth.uid())
      or app.is_room_owner(room_id)
    )
  );

create policy room_messages_insert_member
  on public.room_messages
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and app.is_room_member(room_id)
  );

-- Soft delete only: the column grant exposes deleted_at alone, and the trigger rejects any
-- attempt to touch the body, author, or room.
create policy room_messages_update_delete
  on public.room_messages
  for update
  to authenticated
  using (
    app.is_room_member(room_id)
    and (author_id = (select auth.uid()) or app.is_room_owner(room_id))
  )
  with check (app.is_room_member(room_id));

-- Row level security: schedule -----------------------------------------------------
alter table public.room_sessions enable row level security;
revoke all on public.room_sessions from anon, authenticated;
grant select on public.room_sessions to authenticated;
grant insert (room_id, leader_id, mode, starts_at, ends_at) on public.room_sessions to authenticated;
grant delete on public.room_sessions to authenticated;

create policy room_sessions_select_member
  on public.room_sessions
  for select
  to authenticated
  using (app.is_room_member(room_id));

create policy room_sessions_insert_owner
  on public.room_sessions
  for insert
  to authenticated
  with check (app.is_room_owner(room_id));

create policy room_sessions_delete_owner
  on public.room_sessions
  for delete
  to authenticated
  using (app.is_room_owner(room_id));
