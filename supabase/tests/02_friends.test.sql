-- Friendship flow: requests, acceptance, cancellation, blocking, handle rules.

-- case: accepting a request creates a mutual friendship
select tests.as_user(tests.alice());
select tests.eq('one pending request is visible', (select count(*) from public.friend_requests)::text, '1');
select tests.eq('one friendship to start', (select count(*) from public.friendships)::text, '1');
select public.respond_friend_request('c1000000-0000-4000-8000-000000000001', true);
select tests.eq('a friendship is created', (select count(*) from public.friendships)::text, '2');
select tests.eq('the request is answered', (select status::text from public.friend_requests where id = 'c1000000-0000-4000-8000-000000000001'), 'accepted');
select tests.as_user(tests.carol());
select tests.eq('the other side sees it too', (select count(*) from public.friendships)::text, '1');

-- case: only the recipient can answer a request
select tests.as_user(tests.bob());
select tests.expect_error('a third party cannot accept', $$select public.respond_friend_request('c1000000-0000-4000-8000-000000000001', true)$$);
select tests.as_user(tests.carol());
select tests.expect_error('the sender cannot accept their own request', $$select public.respond_friend_request('c1000000-0000-4000-8000-000000000001', true)$$);
select tests.as_user(tests.alice());
select public.respond_friend_request('c1000000-0000-4000-8000-000000000001', false);
select tests.eq('declining creates no friendship', (select count(*) from public.friendships)::text, '1');
select tests.expect_error('a request cannot be answered twice', $$select public.respond_friend_request('c1000000-0000-4000-8000-000000000001', true)$$);

-- case: friend requests are validated
select tests.as_user(tests.alice());
select tests.expect_error('a self request is refused', $$select public.send_friend_request('alice')$$);
select tests.expect_error('an existing friendship is refused', $$select public.send_friend_request('bob')$$);
select tests.expect_error('an unknown handle is refused', $$select public.send_friend_request('nobody')$$);
select tests.as_user(tests.carol());
select tests.expect_error('a duplicate pending request is refused', $$select public.send_friend_request('alice')$$);

-- case: handles stay unique and well formed
select tests.as_user(tests.dave());
select tests.expect_error('an uppercase handle is rejected', $$update public.profiles set handle = 'ALICE' where id = 'a1000000-0000-4000-8000-000000000004'$$);
select tests.expect_error('a duplicate handle is rejected', $$update public.profiles set handle = 'alice' where id = 'a1000000-0000-4000-8000-000000000004'$$);
select tests.expect_error('a too-short handle is rejected', $$update public.profiles set handle = 'ab' where id = 'a1000000-0000-4000-8000-000000000004'$$);
update public.profiles set handle = 'dave_2' where id = tests.dave();
select tests.eq('a valid handle is accepted', (select handle from public.profiles where id = tests.dave()), 'dave_2');

-- case: unfriending only affects your own friendships
select tests.as_user(tests.carol());
select tests.expect_error('cannot remove a friendship you are not in', $$select public.remove_friend('a1000000-0000-4000-8000-000000000002')$$);
select tests.as_user(tests.alice());
select public.remove_friend(tests.bob());
select tests.eq('the friendship is gone for the caller', (select count(*) from public.friendships)::text, '0');

-- case: a cancelled request stays as history
select tests.as_user(tests.carol());
select public.cancel_friend_request('c1000000-0000-4000-8000-000000000001');
select tests.eq('the request is cancelled, not deleted', (select status::text from public.friend_requests where id = 'c1000000-0000-4000-8000-000000000001'), 'cancelled');
select tests.expect_error('it cannot be cancelled twice', $$select public.cancel_friend_request('c1000000-0000-4000-8000-000000000001')$$);
select tests.expect_error('the recipient cannot cancel it', $$select public.cancel_friend_request('c1000000-0000-4000-8000-000000000001')$$);
