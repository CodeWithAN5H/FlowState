-- Committed fixture state shared by every test case. Each case runs inside a transaction that is
-- rolled back, so cases never see each other's changes.
--
--   alice  owns "Quiet Room" and is friends with bob
--   bob    is a member of the room
--   carol  is outside the room and has a pending friend request to alice
--   dave   has blocked bob (which removes their seeded friendship)

insert into auth.users (id, email) values
  ('a1000000-0000-4000-8000-000000000001', 'alice@flowstate.test'),
  ('a1000000-0000-4000-8000-000000000002', 'bob@flowstate.test'),
  ('a1000000-0000-4000-8000-000000000003', 'carol@flowstate.test'),
  ('a1000000-0000-4000-8000-000000000004', 'dave@flowstate.test');

-- The sign-up trigger created these rows with a null handle; claim a handle for each.
update public.profiles set handle = 'alice', display_name = 'Alice' where id = tests.alice();
update public.profiles set handle = 'bob',   display_name = 'Bob'   where id = tests.bob();
update public.profiles set handle = 'carol', display_name = 'Carol' where id = tests.carol();
update public.profiles set handle = 'dave',  display_name = 'Dave'  where id = tests.dave();

insert into public.friendships (user_low, user_high)
values
  (least(tests.alice(), tests.bob()), greatest(tests.alice(), tests.bob())),
  (least(tests.dave(), tests.bob()), greatest(tests.dave(), tests.bob()));

insert into public.friend_requests (id, from_user, to_user)
values ('c1000000-0000-4000-8000-000000000001', tests.carol(), tests.alice());

-- Blocking dave -> bob exercises the trigger that ends the friendship above.
insert into public.blocks (blocker, blocked)
values (tests.dave(), tests.bob());

insert into public.rooms (id, name, owner_id)
values (tests.room(), 'Quiet Room', tests.alice());

insert into public.room_members (room_id, user_id, role)
values
  (tests.room(), tests.alice(), 'owner'),
  (tests.room(), tests.bob(), 'member');

insert into public.room_messages (id, room_id, author_id, body) values
  ('f1000000-0000-4000-8000-000000000001', tests.room(), tests.alice(), 'Welcome to the quiet room.'),
  ('f1000000-0000-4000-8000-000000000002', tests.room(), tests.bob(), 'Thanks!');

insert into public.room_sessions (id, room_id, leader_id, mode, starts_at, ends_at)
values (
  'f2000000-0000-4000-8000-000000000001',
  tests.room(),
  tests.alice(),
  'focus',
  now() + interval '1 hour',
  now() + interval '2 hours'
);

-- sha256 of the plaintext code, which is what the RPC stores.
insert into public.room_invites (id, room_id, created_by, code_hash, max_uses, expires_at, revoked_at) values
  ('f3000000-0000-4000-8000-000000000001', tests.room(), tests.alice(),
   encode(sha256(convert_to('aaaaaaaaaa', 'UTF8')), 'hex'), 1, now() + interval '1 day', null),
  ('f3000000-0000-4000-8000-000000000002', tests.room(), tests.alice(),
   encode(sha256(convert_to('bbbbbbbbbb', 'UTF8')), 'hex'), 1, now() - interval '1 day', null),
  ('f3000000-0000-4000-8000-000000000003', tests.room(), tests.alice(),
   encode(sha256(convert_to('cccccccccc', 'UTF8')), 'hex'), 1, now() + interval '1 day', now()),
  ('f3000000-0000-4000-8000-000000000004', tests.room(), tests.alice(),
   encode(sha256(convert_to('dddddddddd', 'UTF8')), 'hex'), 2, now() + interval '2 days', null);

-- Alice: one session recorded offline (self-reported) and one the server observed.
-- Bob: one session recorded offline.
insert into public.session_reports
  (id, room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms)
values
  ('f4000000-0000-4000-8000-000000000001', tests.room(), tests.alice(),
   'e1000000-0000-4000-8000-000000000001',
   now() - interval '3 hours', now() - interval '2 hours', 1800000),
  ('f4000000-0000-4000-8000-000000000003', tests.room(), tests.bob(),
   'e1000000-0000-4000-8000-000000000003',
   now() - interval '90 minutes', now() - interval '80 minutes', 600000);

insert into public.session_reports
  (id, room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms,
   server_observed_ms, observed_start_at, observed_end_at)
values
  ('f4000000-0000-4000-8000-000000000002', tests.room(), tests.alice(),
   'e1000000-0000-4000-8000-000000000002',
   now() - interval '2 hours', now() - interval '1 hour', 1200000,
   900000, now() - interval '2 hours', now() - interval '70 minutes');

insert into public.session_heartbeats (session_report_id, at)
values ('f4000000-0000-4000-8000-000000000002', now() - interval '100 minutes');
