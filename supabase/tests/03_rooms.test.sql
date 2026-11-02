-- Room lifecycle: creation, membership, invitations, schedules and messages.

-- case: creating a room makes you its owner
select tests.as_user(tests.carol());
select public.create_room('Study Hall');
select tests.eq('the creator sees exactly one room', (select count(*) from public.rooms)::text, '1');
select tests.check('the creator is the owner', (select app.is_room_owner(id) from public.rooms));
select tests.eq('the roster has one owner', (select count(*) from public.room_members)::text, '1');
select tests.expect_error('an empty name is refused', $$select public.create_room('   ')$$);

-- case: the invite policy decides who may invite
select tests.as_user(tests.bob());
select tests.expect_error('a member cannot invite under owner_only', $$select public.create_room_invite('b1000000-0000-4000-8000-000000000001')$$);
select tests.expect_error('a member cannot revoke an invitation they did not create', $$select public.revoke_room_invite('f3000000-0000-4000-8000-000000000004')$$);
update public.rooms set name = 'Hijacked' where id = tests.room();
select tests.as_user(tests.alice());
select tests.eq('a member cannot rename the room', (select name from public.rooms where id = tests.room()), 'Quiet Room');
update public.rooms set invite_policy = 'all_members' where id = tests.room();
select tests.eq('the owner can change the policy', (select invite_policy::text from public.rooms where id = tests.room()), 'all_members');
select tests.as_user(tests.bob());
select tests.eq('a member can invite under all_members', (select count(*) from public.create_room_invite(tests.room()))::text, '1');
select tests.eq('a member sees only their own invitations', (select count(*) from public.room_invites)::text, '1');
select tests.as_user(tests.alice());
select tests.eq('the owner sees every invitation', (select count(*) from public.room_invites)::text, '5');

-- case: invitation codes are hashed and randomised
select tests.as_user(tests.alice());
select tests.expect_error('the stored hash is not readable by clients', 'select code_hash from public.room_invites');
select tests.check('a generated code looks like a random code', (select code ~ '^[a-f0-9]{10}$' from public.create_room_invite(tests.room())));
select tests.check('two generated codes differ', (
  select count(distinct code) = 2
    from (
      select code from public.create_room_invite(tests.room())
      union all
      select code from public.create_room_invite(tests.room())
    ) codes
));

-- case: a valid invitation joins the room
select tests.as_user(tests.carol());
select tests.eq('the code is accepted', (select outcome from public.redeem_room_invite('aaaaaaaaaa')), 'joined');
select tests.eq('the room is now visible', (select count(*) from public.rooms)::text, '1');
select tests.eq('the roster shows three', (select count(*) from public.room_members)::text, '3');
select tests.eq('messages are now readable', (select count(*) from public.room_messages)::text, '2');
select tests.eq('redeeming again is idempotent', (select outcome from public.redeem_room_invite('aaaaaaaaaa')), 'already_member');
select tests.eq('the roster did not grow', (select count(*) from public.room_members)::text, '3');

-- case: a single-use code cannot be redeemed twice
select tests.as_user(tests.carol());
select tests.eq('the first redemption joins', (select outcome from public.redeem_room_invite('aaaaaaaaaa')), 'joined');
select tests.as_user(tests.dave());
select tests.eq('the second is refused as exhausted', (select outcome from public.redeem_room_invite('aaaaaaaaaa')), 'exhausted');
select tests.eq('the second user did not join', (select count(*) from public.rooms)::text, '0');

-- case: expired and revoked invitations are refused
select tests.as_user(tests.carol());
select tests.eq('an expired code', (select outcome from public.redeem_room_invite('bbbbbbbbbb')), 'expired');
select tests.eq('a revoked code', (select outcome from public.redeem_room_invite('cccccccccc')), 'revoked');
select tests.eq('an unknown code', (select outcome from public.redeem_room_invite('zzzzzzzzzz')), 'invalid');
select tests.eq('and nothing joined', (select count(*) from public.rooms)::text, '0');

-- case: a multi-use code allows exactly its uses
select tests.as_user(tests.carol());
select tests.eq('the first use', (select outcome from public.redeem_room_invite('dddddddddd')), 'joined');
select tests.as_user(tests.dave());
select tests.eq('the second use', (select outcome from public.redeem_room_invite('dddddddddd')), 'joined');
select tests.as_user(tests.alice());
select tests.eq('the uses counter stops at the maximum', (select uses::text from public.room_invites where id = 'f3000000-0000-4000-8000-000000000004'), '2');

-- case: guessing codes is rate limited
select tests.as_user(tests.carol());
select count(public.redeem_room_invite('bad000000' || g.i::text)) from generate_series(1, 10) as g(i);
select tests.eq('the next attempt is refused', (select outcome from public.redeem_room_invite('aaaaaaaaaa')), 'rate_limited');
select tests.eq('a valid code is refused while limited', (select outcome from public.redeem_room_invite('dddddddddd')), 'rate_limited');
select tests.eq('and the caller is still outside', (select count(*) from public.rooms)::text, '0');

-- case: leaving and ownership transfer
select tests.as_user(tests.alice());
select tests.expect_error('the owner cannot leave', $$select public.leave_room('b1000000-0000-4000-8000-000000000001')$$);
select tests.expect_error('ownership cannot go to a non-member', $$select public.transfer_room_ownership('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003')$$);
select public.transfer_room_ownership(tests.room(), tests.bob());
select tests.eq('the new owner holds the owner role', (select role::text from public.room_members where user_id = tests.bob() and removed_at is null), 'owner');
select tests.eq('the old owner keeps a member role', (select role::text from public.room_members where user_id = tests.alice() and removed_at is null), 'member');
select tests.eq('the owner column follows the transfer', (select owner_id::text from public.rooms where id = tests.room()), 'a1000000-0000-4000-8000-000000000002');
select tests.as_user(tests.bob());
select tests.check('the new owner passes the owner check', app.is_room_owner(tests.room()));
select tests.expect_error('the owner cannot remove themselves', $$select public.remove_room_member('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002')$$);
select public.remove_room_member(tests.room(), tests.alice());
select tests.as_user(tests.alice());
select tests.eq('the removed former owner cannot see the room', (select count(*) from public.rooms)::text, '0');

-- case: a member can leave but needs a code to return
select tests.as_user(tests.bob());
select public.leave_room(tests.room());
select tests.eq('the membership interval is closed', (select count(*) from public.room_members where removed_at is not null)::text, '1');
select tests.eq('the room is no longer visible', (select count(*) from public.rooms)::text, '0');
select tests.eq('a code lets them return', (select outcome from public.redeem_room_invite('dddddddddd')), 'joined');
select tests.eq('both intervals are kept', (select count(*) from public.room_members)::text, '3');

-- case: only the owner controls the schedule
select tests.as_user(tests.bob());
delete from public.room_sessions;
select tests.eq('a member cannot delete the schedule', (select count(*) from public.room_sessions)::text, '1');
select tests.expect_error('a member cannot create a schedule', $$insert into public.room_sessions (room_id, leader_id, mode, starts_at, ends_at) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'focus', now() + interval '3 hours', now() + interval '4 hours')$$);
select tests.as_user(tests.alice());
insert into public.room_sessions (room_id, leader_id, mode, starts_at, ends_at) values (tests.room(), tests.bob(), 'focus', now() + interval '3 hours', now() + interval '4 hours');
select tests.eq('the owner schedules a session', (select count(*) from public.room_sessions)::text, '2');
select tests.expect_error('the leader must be a current member', $$insert into public.room_sessions (room_id, leader_id, mode, starts_at, ends_at) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000003', 'focus', now() + interval '5 hours', now() + interval '6 hours')$$);
select tests.expect_error('a schedule must end after it starts', $$insert into public.room_sessions (room_id, leader_id, mode, starts_at, ends_at) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'focus', now() + interval '6 hours', now() + interval '5 hours')$$);

-- case: messages enforce authorship, length and rate
select tests.as_user(tests.bob());
insert into public.room_messages (room_id, author_id, body) values (tests.room(), tests.bob(), 'hello again');
select tests.eq('a member can post', (select count(*) from public.room_messages)::text, '3');
select tests.expect_error('a blank message is rejected', $$insert into public.room_messages (room_id, author_id, body) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', '   ')$$);
select tests.expect_error('an overlong message is rejected', $$insert into public.room_messages (room_id, author_id, body) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', repeat('x', 501))$$);
select tests.expect_error('the rate limit aborts a burst', $$insert into public.room_messages (room_id, author_id, body) select 'b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002', 'spam' from generate_series(1, 30)$$);
select tests.eq('no burst was stored', (select count(*) from public.room_messages)::text, '3');

-- case: messages can be soft deleted but never edited
select tests.as_user(tests.bob());
select tests.expect_error('a body cannot be edited', $$update public.room_messages set body = 'edited' where author_id = 'a1000000-0000-4000-8000-000000000002'$$);
update public.room_messages set deleted_at = now() where author_id = tests.bob() and body = 'Thanks!';
select tests.eq('the author still sees their own deleted message', (select count(*) from public.room_messages)::text, '2');
select tests.eq('exactly one message is deleted', (select count(*) from public.room_messages where deleted_at is not null)::text, '1');
select tests.expect_error('a deleted message cannot be restored', $$update public.room_messages set deleted_at = null where deleted_at is not null$$);
update public.room_messages set deleted_at = now() where author_id = tests.alice();
select tests.eq('a member cannot delete another author''s message', (select count(*) from public.room_messages where deleted_at is not null and author_id = tests.alice())::text, '0');
select tests.as_user(tests.alice());
select tests.eq('the owner still sees both rows', (select count(*) from public.room_messages)::text, '2');
update public.room_messages set deleted_at = now() where author_id = tests.alice();
select tests.as_user(tests.bob());
select tests.eq('another author''s deleted message is hidden from a member', (select count(*) from public.room_messages)::text, '1');

-- case: non-members cannot write to a room
select tests.as_user(tests.dave());
select tests.expect_error('a non-member cannot post', $$insert into public.room_messages (room_id, author_id, body) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000004', 'let me in')$$);
select tests.expect_error('a non-member cannot report time', $$insert into public.session_reports (room_id, user_id, local_session_uuid, started_at, ended_at, client_duration_ms) values ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000004', gen_random_uuid(), now() - interval '1 hour', now(), 60000)$$);
update public.rooms set archived_at = now() where id = tests.room();
select tests.as_user(tests.alice());
select tests.eq('the non-member archive attempt changed nothing', (select coalesce(archived_at::text, 'none') from public.rooms where id = tests.room()), 'none');
