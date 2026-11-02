-- 20261102090100_social.sql
--
-- Friendships, friend requests, and blocks.
--
-- All mutation flows through the SECURITY DEFINER functions in 20261102090500_functions_social.sql:
-- clients hold SELECT only (plus their own block rows), so a client cannot create a friendship
-- unilaterally, accept its own request, or forge a sender.

create type public.friend_request_status as enum ('pending', 'accepted', 'declined', 'cancelled');

-- A friendship is a single unordered row. The ordered-pair constraint keeps one representation
-- so uniqueness is enforced by the primary key instead of by application convention.
create table public.friendships (
  user_low uuid not null references public.profiles (id) on delete cascade,
  user_high uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_low, user_high),
  constraint friendships_ordered check (user_low < user_high)
);

create index friendships_user_high_idx on public.friendships (user_high);

comment on table public.friendships is
  'Mutual friendship. One row per pair, ordered so the primary key enforces uniqueness.';

create table public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references public.profiles (id) on delete cascade,
  to_user uuid not null references public.profiles (id) on delete cascade,
  status public.friend_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_not_self check (from_user <> to_user),
  constraint friend_requests_responded_once check ((status = 'pending') = (responded_at is null))
);

-- At most one pending request per pair in either direction, so two people cannot queue
-- duplicate or crossed requests. Answered requests are kept as history.
create unique index friend_requests_pending_pair_key
  on public.friend_requests (least(from_user, to_user), greatest(from_user, to_user))
  where status = 'pending';

create index friend_requests_to_user_idx
  on public.friend_requests (to_user, created_at desc)
  where status = 'pending';

create index friend_requests_from_user_created_idx
  on public.friend_requests (from_user, created_at desc);

create table public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  constraint blocks_not_self check (blocker <> blocked)
);

create index blocks_blocked_idx on public.blocks (blocked);

-- Symmetric block lookup used by the SECURITY DEFINER friendship functions. It is intentionally
-- not executable by clients: a client-scoped version would let someone probe who blocks whom.
create function app.block_exists_between(p_user_a uuid, p_user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.blocks b
     where (b.blocker = p_user_a and b.blocked = p_user_b)
        or (b.blocker = p_user_b and b.blocked = p_user_a)
  );
$$;

revoke all on function app.block_exists_between(uuid, uuid) from public;

-- Blocking is authoritative: it ends the friendship and cancels any pending request in either
-- direction, in one transaction with the block itself.
create function app.on_block_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friendships
   where user_low = least(new.blocker, new.blocked)
     and user_high = greatest(new.blocker, new.blocked);

  update public.friend_requests
     set status = 'cancelled', responded_at = now()
   where status = 'pending'
     and ((from_user = new.blocker and to_user = new.blocked)
       or (from_user = new.blocked and to_user = new.blocker));

  return null;
end;
$$;

revoke all on function app.on_block_created() from public;

create trigger blocks_after_insert
  after insert on public.blocks
  for each row execute function app.on_block_created();

-- Row level security --------------------------------------------------------------
alter table public.friendships enable row level security;
revoke all on public.friendships from anon, authenticated;
grant select on public.friendships to authenticated;

create policy friendships_select_participant
  on public.friendships
  for select
  to authenticated
  using (
    user_low = (select auth.uid())
    or user_high = (select auth.uid())
  );

alter table public.friend_requests enable row level security;
revoke all on public.friend_requests from anon, authenticated;
grant select on public.friend_requests to authenticated;

create policy friend_requests_select_participant
  on public.friend_requests
  for select
  to authenticated
  using (
    from_user = (select auth.uid())
    or to_user = (select auth.uid())
  );

-- A block row is visible only to the person who created it. The blocked user learns nothing from
-- the table; they simply find that requests and new friendships are refused.
alter table public.blocks enable row level security;
revoke all on public.blocks from anon, authenticated;
grant select, insert, delete on public.blocks to authenticated;

create policy blocks_select_own
  on public.blocks
  for select
  to authenticated
  using (blocker = (select auth.uid()));

create policy blocks_insert_own
  on public.blocks
  for insert
  to authenticated
  with check (blocker = (select auth.uid()));

create policy blocks_delete_own
  on public.blocks
  for delete
  to authenticated
  using (blocker = (select auth.uid()));
