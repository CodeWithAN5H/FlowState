-- 20261102090300_session_reports.sql
--
-- Study-session reports and the attribution policy in docs/MILESTONE_2_PLAN.md §9.
--
-- The single most important property of this table: a client can submit the time it recorded, and
-- nothing else. `server_observed_*` columns are not in the client INSERT grant, so a synced
-- offline session cannot be promoted to observed time by the client that uploaded it. There is no
-- duration cap, no plausibility heuristic, and no rejection path — an offline session is accepted
-- at face value and stays self-reported.

create table public.session_reports (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The device's own identifier for the session. Unique per user, which makes a retried upload
  -- idempotent instead of duplicating study time.
  local_session_uuid uuid not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  -- The device's claim. Always present, never clamped.
  client_duration_ms bigint not null,
  -- Populated only by trusted server code when the backend itself saw the session start and end
  -- (or received heartbeats). Null for every offline or locally recorded session.
  server_observed_ms bigint,
  observed_start_at timestamptz,
  observed_end_at timestamptz,
  received_at timestamptz not null default now(),
  -- Derived, not writable: the honest attribution label. A row is self-reported exactly when the
  -- server recorded no observation of it.
  is_self_reported boolean generated always as (server_observed_ms is null) stored,
  constraint session_reports_order check (ended_at > started_at),
  constraint session_reports_client_duration_positive check (client_duration_ms > 0),
  constraint session_reports_observed_non_negative check (
    server_observed_ms is null or server_observed_ms >= 0
  ),
  -- Observation is all-or-nothing: either the server watched this session and knows the window,
  -- or it did not watch at all.
  constraint session_reports_observed_consistent check (
    (server_observed_ms is null and observed_start_at is null and observed_end_at is null)
    or (server_observed_ms is not null and observed_start_at is not null and observed_end_at is not null)
  ),
  constraint session_reports_observed_order check (
    observed_start_at is null or observed_end_at >= observed_start_at
  )
);

create unique index session_reports_idempotency_key
  on public.session_reports (user_id, local_session_uuid);

create index session_reports_room_received_idx
  on public.session_reports (room_id, received_at desc);

create index session_reports_user_received_idx
  on public.session_reports (user_id, received_at desc);

comment on table public.session_reports is
  'Reported study time for a room. Self-reported unless server_observed_ms is set; there is no '
  'anti-cheat, cap, or reconciliation logic (Milestone 2 plan §9.2).';
comment on column public.session_reports.client_duration_ms is
  'Duration claimed by the device. Accepted as-is and never clamped.';
comment on column public.session_reports.server_observed_ms is
  'Duration the backend itself observed. Null means the session is self-reported.';
comment on column public.session_reports.is_self_reported is
  'Derived label: true when the server observed nothing. Used for display, not for exclusion.';

-- Heartbeats are server-side evidence only. Clients hold no privilege on this table at all, so a
-- client cannot fabricate observation for its own report.
create table public.session_heartbeats (
  id bigint generated always as identity primary key,
  session_report_id uuid not null references public.session_reports (id) on delete cascade,
  at timestamptz not null default now(),
  unique (session_report_id, at)
);

create index session_heartbeats_report_idx on public.session_heartbeats (session_report_id, at);

-- Row level security --------------------------------------------------------------
alter table public.session_reports enable row level security;
revoke all on public.session_reports from anon, authenticated;

grant select on public.session_reports to authenticated;
-- Note the column list: a client may submit its own claim, and has no privilege on the observed
-- columns or the derived label.
grant insert (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms)
  on public.session_reports to authenticated;

-- A member can read the reports that feed their room's statistics, and their own reports
-- everywhere. A removed member loses the room view, matching message access.
create policy session_reports_select
  on public.session_reports
  for select
  to authenticated
  using (user_id = (select auth.uid()) or app.is_room_member(room_id));

-- Reporting requires a live membership. This is an authorization rule, not a duration check: the
-- length is accepted, the room relationship is verified. A session recorded offline for a room the
-- user still belongs to uploads normally and remains self-reported.
create policy session_reports_insert_own
  on public.session_reports
  for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and app.is_room_member(room_id)
  );

-- Reports are immutable. No UPDATE or DELETE grant exists, so neither a device nor a room owner
-- can rewrite reported time after the fact.

alter table public.session_heartbeats enable row level security;
revoke all on public.session_heartbeats from anon, authenticated;
-- No policies on purpose: this table is writable and readable only by trusted server code
-- (SECURITY DEFINER functions or the service role). An unprivileged client gets nothing.
