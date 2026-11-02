-- Study-time attribution (plan §9): self-reported time counts, and syncing never implies
-- observation.

-- case: an offline session uploads and stays self-reported
select tests.as_user(tests.bob());
insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms)
values (tests.room(), tests.bob(), 'e1000000-0000-4000-8000-000000000009', now() - interval '5 hours', now() - interval '4 hours', 3600000);
select tests.eq('the upload is stored', (select count(*) from public.session_reports where user_id = tests.bob())::text, '2');
select tests.eq('it is still self-reported after arriving', (select is_self_reported::text from public.session_reports where local_session_uuid = 'e1000000-0000-4000-8000-000000000009'), 'true');
select tests.eq('no observed duration was invented', (select coalesce(server_observed_ms::text, 'none') from public.session_reports where local_session_uuid = 'e1000000-0000-4000-8000-000000000009'), 'none');
select tests.eq('no observed window was invented', (select coalesce(observed_start_at::text, 'none') from public.session_reports where local_session_uuid = 'e1000000-0000-4000-8000-000000000009'), 'none');

-- case: a client cannot claim observation
select tests.as_user(tests.bob());
select tests.expect_error('cannot submit an observed duration', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms, server_observed_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', gen_random_uuid(), now() - interval '1 hour', now(), 60000, 60000)$$);
select tests.expect_error('cannot submit an observed window', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms, observed_start_at, observed_end_at) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', gen_random_uuid(), now() - interval '1 hour', now(), 60000, now() - interval '1 hour', now())$$);
select tests.expect_error('cannot set the derived label', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms, is_self_reported) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', gen_random_uuid(), now() - interval '1 hour', now(), 60000, false)$$);
select tests.expect_error('cannot rewrite reported time', $$update public.session_reports set client_duration_ms = 1 where user_id = 'a1000000-0000-4000-8000-000000000002'$$);
select tests.expect_error('cannot write heartbeats', $$insert into public.session_heartbeats (session_report_id, at) values ('f4000000-0000-4000-8000-000000000001', now())$$);
select tests.expect_error('cannot delete a report', $$delete from public.session_reports where user_id = 'a1000000-0000-4000-8000-000000000002'$$);

-- case: durations are accepted, not capped or repaired
select tests.as_user(tests.bob());
insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms)
values (tests.room(), tests.bob(), 'e1000000-0000-4000-8000-000000000010', now() - interval '200 hours', now(), 720000000);
select tests.eq('a 200-hour claim is stored as claimed', (select client_duration_ms::text from public.session_reports where local_session_uuid = 'e1000000-0000-4000-8000-000000000010'), '720000000');
select tests.eq('and it is still self-reported', (select is_self_reported::text from public.session_reports where local_session_uuid = 'e1000000-0000-4000-8000-000000000010'), 'true');

-- case: duplicate uploads do not double count
select tests.as_user(tests.bob());
select tests.expect_error('the same local session cannot be uploaded twice', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000003', now() - interval '90 minutes', now() - interval '80 minutes', 600000)$$);
select tests.eq('the retry did not create a second report', (select count(*) from public.session_reports where user_id = tests.bob())::text, '1');

-- case: the leaderboard counts self-reported time and labels the split
select tests.as_user(tests.alice());
select tests.eq('alice self-reported total', (select self_reported_ms::text from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id = tests.alice()), '1800000');
select tests.eq('alice observed total', (select observed_ms::text from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id = tests.alice()), '1200000');
select tests.eq('alice combined total', (select total_ms::text from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id = tests.alice()), '3000000');
select tests.eq('bob self-reported time is counted', (select self_reported_ms::text from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id = tests.bob()), '600000');
select tests.eq('both members are listed', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day'))::text, '2');

-- case: only members see a room board
select tests.as_user(tests.carol());
select tests.eq('a non-member board is empty', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day'))::text, '0');
select tests.expect_error('a non-member cannot report', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003', gen_random_uuid(), now() - interval '1 hour', now(), 60000)$$);

-- case: removed members keep history but lose the board
select tests.as_user(tests.alice());
select public.remove_room_member(tests.room(), tests.bob());
select tests.check('bob''s recorded time stays with the room', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id = tests.bob()) = 1);
select tests.as_user(tests.bob());
select tests.eq('the removed member cannot see other members', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where user_id <> tests.bob())::text, '0');

-- case: observed sessions keep the claim and the observation apart
select tests.as_user(tests.alice());
select tests.eq('the observed session is not flagged self-reported', (select is_self_reported::text from public.session_reports where id = 'f4000000-0000-4000-8000-000000000002'), 'false');
select tests.eq('the observed duration is recorded', (select server_observed_ms::text from public.session_reports where id = 'f4000000-0000-4000-8000-000000000002'), '900000');
select tests.eq('the client claim is preserved unchanged', (select client_duration_ms::text from public.session_reports where id = 'f4000000-0000-4000-8000-000000000002'), '1200000');
select tests.check('one member shows both attributions', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day') where self_reported_ms > 0 and observed_ms > 0) = 1);
