-- Access control across identity, rooms, membership, messages and blocks.
--
-- Every case starts from the committed fixture in seed.sql, runs as an ordinary `authenticated`
-- or `anon` role, and is rolled back by the harness.

-- case: anonymous callers get nothing
select tests.as_anon();
select tests.expect_error('anon cannot select profiles', 'select count(*) from public.profiles');
select tests.expect_error('anon cannot select rooms', 'select count(*) from public.rooms');
select tests.expect_error('anon cannot select messages', 'select count(*) from public.room_messages');
select tests.expect_error('anon cannot select reports', 'select count(*) from public.session_reports');
select tests.expect_error('anon cannot select memberships', 'select count(*) from public.room_members');
select tests.expect_error('anon cannot redeem an invite', $$select public.redeem_room_invite('aaaaaaaaaa')$$);
select tests.expect_error('anon cannot send a friend request', $$select public.send_friend_request('alice')$$);
select tests.expect_error('anon cannot create a room', $$select public.create_room('x')$$);

-- case: private profile columns are not exposed
select tests.as_user(tests.alice());
select tests.eq('the public profile columns are readable', (select count(*) from public.profiles)::text, '4');
select tests.eq('a handle is visible for discovery', (select handle from public.profiles where id = tests.bob()), 'bob');
select tests.expect_error('presence is not readable by clients', 'select last_seen_at from public.profiles');
select tests.expect_error('the account creation time is not writable', $$update public.profiles set created_at = now() where id = 'a1000000-0000-4000-8000-000000000001'$$);
select tests.expect_error('presence is not writable by clients', $$update public.profiles set last_seen_at = now() where id = 'a1000000-0000-4000-8000-000000000001'$$);

-- case: a user may edit only their own profile
select tests.as_user(tests.bob());
update public.profiles set display_name = 'Bobby' where id = tests.bob();
select tests.eq('own display name updated', (select display_name from public.profiles where id = tests.bob()), 'Bobby');
update public.profiles set display_name = 'Renamed' where id = tests.alice();
select tests.eq('another profile is untouched', (select display_name from public.profiles where id = tests.alice()), 'Alice');
select tests.expect_error('the account id cannot be rewritten', $$update public.profiles set id = 'a1000000-0000-4000-8000-000000000009' where id = 'a1000000-0000-4000-8000-000000000002'$$);

-- case: rooms are invisible to non-members
select tests.as_user(tests.carol());
select tests.eq('no rooms', (select count(*) from public.rooms)::text, '0');
select tests.eq('no messages', (select count(*) from public.room_messages)::text, '0');
select tests.eq('no roster', (select count(*) from public.room_members)::text, '0');
select tests.eq('no reports', (select count(*) from public.session_reports)::text, '0');
select tests.eq('no schedule', (select count(*) from public.room_sessions)::text, '0');
select tests.eq('no invitations', (select count(*) from public.room_invites)::text, '0');
select tests.eq('empty leaderboard', (select count(*) from public.room_leaderboard(tests.room(), now() - interval '1 day', now() + interval '1 day'))::text, '0');

-- case: a member sees their own room
select tests.as_user(tests.bob());
select tests.eq('one room', (select count(*) from public.rooms)::text, '1');
select tests.eq('its name', (select name from public.rooms), 'Quiet Room');
select tests.eq('both messages', (select count(*) from public.room_messages)::text, '2');
select tests.eq('the roster', (select count(*) from public.room_members)::text, '2');
select tests.eq('the schedule', (select count(*) from public.room_sessions)::text, '1');

-- case: removed members lose room access
select tests.as_user(tests.alice());
select public.remove_room_member(tests.room(), tests.bob());
select tests.as_user(tests.bob());
select tests.eq('the room is gone', (select count(*) from public.rooms)::text, '0');
select tests.eq('messages are gone', (select count(*) from public.room_messages)::text, '0');
select tests.eq('the removed membership row is kept as history', (select count(*) from public.room_members)::text, '1');
select tests.eq('only their own reports remain', (select count(*) from public.session_reports)::text, '1');

-- case: a removed member cannot post or report
select tests.as_user(tests.alice());
select public.remove_room_member(tests.room(), tests.bob());
select tests.as_user(tests.bob());
select tests.expect_error('cannot post after removal', $$insert into public.room_messages (room_id, author_id, body) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'still here')$$);
select tests.expect_error('cannot report after removal', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', gen_random_uuid(), now() - interval '1 hour', now(), 60000)$$);

-- case: user ids cannot be spoofed
select tests.as_user(tests.bob());
select tests.expect_error('cannot post as another author', $$insert into public.room_messages (room_id, author_id, body) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'spoofed')$$);
select tests.expect_error('cannot report as another user', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', gen_random_uuid(), now() - interval '1 hour', now(), 60000)$$);
select tests.expect_error('cannot add a member directly', $$insert into public.room_members (room_id, user_id) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003')$$);
select tests.expect_error('cannot promote themselves to owner', $$insert into public.room_members (room_id, user_id, role) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'owner')$$);

-- case: ownership cannot be seized
select tests.as_user(tests.bob());
select tests.expect_error('the owner column cannot be rewritten', $$update public.rooms set owner_id = 'a1000000-0000-4000-8000-000000000002' where id = 'b1000000-0000-4000-8000-000000000001'$$);
select tests.expect_error('a member cannot transfer ownership', $$select public.transfer_room_ownership('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002')$$);
select tests.expect_error('a member cannot remove the owner', $$select public.remove_room_member('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001')$$);
select tests.expect_error('a non-member cannot remove anyone', $$select public.remove_room_member('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002')$$);

-- case: blocks are private and stop requests
select tests.as_user(tests.alice());
select tests.eq('an uninvolved user sees no blocks', (select count(*) from public.blocks)::text, '0');
select tests.as_user(tests.dave());
select tests.eq('the blocker sees their own block', (select count(*) from public.blocks)::text, '1');
select tests.as_user(tests.bob());
select tests.eq('the blocked user learns nothing from the table', (select count(*) from public.blocks)::text, '0');
select tests.expect_error('the blocked user cannot send a request', $$select public.send_friend_request('dave')$$);
select tests.as_user(tests.dave());
select tests.expect_error('the blocker cannot send a request either', $$select public.send_friend_request('bob')$$);
select tests.eq('the block ended the friendship', (select count(*) from public.friendships where user_low = least(tests.dave(), tests.bob()) and user_high = greatest(tests.dave(), tests.bob()))::text, '0');
