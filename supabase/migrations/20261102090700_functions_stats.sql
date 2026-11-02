-- 20261102090700_functions_stats.sql
--
-- Friend-group statistics (plan §9.2).
--
-- Self-reported time counts here. The function splits the total by attribution so a caller can
-- label the numbers honestly instead of presenting every minute as if the server had watched it.
--
-- SECURITY INVOKER (the default, stated for emphasis): the row level security policies on
-- session_reports decide who may read what. A member sees their room's reports; a non-member sees
-- nothing and gets an empty result rather than an error, which leaks no membership information.

create function public.room_leaderboard(
  p_room uuid,
  p_since timestamptz,
  p_until timestamptz
)
returns table (
  user_id uuid,
  handle text,
  display_name text,
  session_count bigint,
  self_reported_ms bigint,
  observed_ms bigint,
  total_ms bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    r.user_id,
    p.handle,
    p.display_name,
    count(*)::bigint as session_count,
    coalesce(
      sum(case when r.is_self_reported then r.client_duration_ms else 0 end),
      0
    )::bigint as self_reported_ms,
    coalesce(
      sum(case when r.is_self_reported then 0 else r.client_duration_ms end),
      0
    )::bigint as observed_ms,
    coalesce(sum(r.client_duration_ms), 0)::bigint as total_ms
  from public.session_reports r
  join public.profiles p on p.id = r.user_id
  where r.room_id = p_room
    and r.received_at >= p_since
    and r.received_at < p_until
  group by r.user_id, p.handle, p.display_name
  order by total_ms desc, p.display_name asc;
$$;

comment on function public.room_leaderboard(uuid, timestamptz, timestamptz) is
  'Per-member room totals split into self-reported and observed time. Offline sessions count; '
  'observed_ms is not a verification claim, only a record that the backend saw the session.';

revoke all on function public.room_leaderboard(uuid, timestamptz, timestamptz) from public;
grant execute on function public.room_leaderboard(uuid, timestamptz, timestamptz) to authenticated;
