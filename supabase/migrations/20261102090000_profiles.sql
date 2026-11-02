-- 20261102090000_profiles.sql
--
-- Milestone 2A: backend foundation. Profiles are the only public view of a user.
--
-- FlowState stays local-first (§1 of docs/MILESTONE_2_PLAN.md): nothing here is required for
-- tasks, habits, notes, the timer, insights, settings, or backup/restore. These objects exist so
-- the optional social features of Milestone 2 have a place to live.
--
-- Account-level data (email, password hashes, MFA factors, sessions) stays in auth.users, which is
-- never exposed through the public schema. A profile holds only what another member may see:
-- an id, a claimed handle, a display name, and an account creation time.

create schema if not exists app;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  -- Null until the user claims a handle (phase 2C). Unique among non-null handles, so an
  -- unclaimed profile never blocks another sign-up.
  handle text,
  display_name text not null default 'Friend',
  created_at timestamptz not null default now(),
  -- Durable presence fallback (plan §7). Not readable through any client role: presence is
  -- written by public.touch_presence() and read from trusted server code only, so a client
  -- cannot claim to be online.
  last_seen_at timestamptz not null default now(),
  constraint profiles_handle_format check (
    handle is null
    or (handle = lower(handle) and handle ~ '^[a-z0-9][a-z0-9_]{2,19}$')
  ),
  constraint profiles_display_name_length check (
    char_length(btrim(display_name)) between 1 and 40
  )
);

create unique index profiles_handle_key
  on public.profiles (handle)
  where handle is not null;

comment on table public.profiles is
  'Public identity for a signed-in user. Mirrors auth.users by id; holds no email or credentials.';
comment on column public.profiles.handle is
  'Optional unique lowercase handle, claimed in phase 2C. Null until claimed.';
comment on column public.profiles.last_seen_at is
  'Durable presence fallback, updated only through public.touch_presence().';

-- Create the profile row when an auth user appears. Runs as the migration owner so it can write
-- to public.profiles even though clients hold no INSERT grant.
create function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function app.handle_new_user() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- Row level security --------------------------------------------------------------
--
-- Handles are the discovery mechanism for friend requests (phase 2D), so an authenticated user
-- may read the public columns of any profile. That is deliberate: the table holds no email,
-- no credentials, and no presence data. Private columns are protected by column privileges
-- rather than by row filtering, because a handle lookup must be able to find a non-friend.
alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select (id, handle, display_name, created_at) on public.profiles to authenticated;
grant update (handle, display_name) on public.profiles to authenticated;

create policy profiles_select_public_columns
  on public.profiles
  for select
  to authenticated
  using (true);

-- A user may only edit their own handle and display name. id, created_at, and last_seen_at are
-- not in the UPDATE grant, so they cannot be rewritten even by the row's owner.
create policy profiles_update_self
  on public.profiles
  for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Presence ------------------------------------------------------------------------
--
-- Clients cannot write last_seen_at directly (no column privilege). This is the only supported
-- path, and it ignores any supplied user id.
create function public.touch_presence()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- At most one write per 30 seconds per user, per plan §7.
  update public.profiles
     set last_seen_at = now()
   where id = v_me
     and last_seen_at < now() - interval '30 seconds';

  return (select last_seen_at from public.profiles where id = v_me);
end;
$$;

revoke all on function public.touch_presence() from public;
grant execute on function public.touch_presence() to authenticated;
