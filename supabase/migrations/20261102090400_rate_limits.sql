-- 20261102090400_rate_limits.sql
--
-- Invitation redemption attempts.
--
-- The plan (§6) requires rate limiting that prevents code enumeration. Failures have to be
-- recorded durably, which is why public.redeem_room_invite() returns an outcome instead of
-- raising: a raised exception would roll back the attempt row it just wrote, and the limiter
-- would never see it.

create table public.invite_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null default false
);

create index invite_attempts_user_time_idx
  on public.invite_attempts (user_id, attempted_at desc);

comment on table public.invite_attempts is
  'Redemption attempts per user, used to rate limit invitation-code guessing. Server-side only.';

alter table public.invite_attempts enable row level security;
revoke all on public.invite_attempts from anon, authenticated;
-- No policies on purpose: only SECURITY DEFINER functions touch this table. A client that could
-- read it would learn how many codes have been tried; a client that could write it could clear
-- its own limiter.
