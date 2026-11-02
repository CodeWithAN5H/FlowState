-- 20261102090500_functions_social.sql
--
-- Friend requests, acceptance, and unfriending.
--
-- Every function derives the caller from auth.uid(); no function accepts a "from" user id, so a
-- client cannot create a request as somebody else. All are SECURITY DEFINER, which is what lets
-- them write to tables where clients hold no INSERT privilege — so each one has to re-check
-- authorization itself rather than relying on RLS.

create function public.send_friend_request(p_handle text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_target uuid;
  v_recent integer;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select p.id
    into v_target
    from public.profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if v_target is null then
    raise exception 'no profile with that handle' using errcode = 'P0002';
  end if;

  if v_target = v_me then
    raise exception 'you cannot send a friend request to yourself' using errcode = '22023';
  end if;

  if app.block_exists_between(v_me, v_target) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if exists (
    select 1
      from public.friendships f
     where f.user_low = least(v_me, v_target)
       and f.user_high = greatest(v_me, v_target)
  ) then
    raise exception 'already friends' using errcode = '23505';
  end if;

  select count(*)
    into v_recent
    from public.friend_requests r
   where r.from_user = v_me
     and r.created_at > now() - interval '1 day';

  if v_recent >= 20 then
    raise exception 'friend request rate limit reached' using errcode = '42901';
  end if;

  insert into public.friend_requests (from_user, to_user)
  values (v_me, v_target)
  returning id into v_id;

  return v_id;
exception
  when unique_violation then
    raise exception 'a friend request already exists between you' using errcode = '23505';
end;
$$;

create function public.respond_friend_request(p_request uuid, p_accept boolean)
returns public.friend_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_request public.friend_requests;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select *
    into v_request
    from public.friend_requests r
   where r.id = p_request
     for update;

  if not found then
    raise exception 'friend request not found' using errcode = 'P0002';
  end if;

  -- Only the recipient answers a request. The sender can only cancel it.
  if v_request.to_user <> v_me then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = '22023';
  end if;

  if coalesce(p_accept, false)
     and app.block_exists_between(v_request.from_user, v_request.to_user) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  update public.friend_requests
     set status = case
                    when coalesce(p_accept, false) then 'accepted'::public.friend_request_status
                    else 'declined'::public.friend_request_status
                  end,
         responded_at = now()
   where id = p_request
  returning * into v_request;

  if coalesce(p_accept, false) then
    insert into public.friendships (user_low, user_high)
    values (
      least(v_request.from_user, v_request.to_user),
      greatest(v_request.from_user, v_request.to_user)
    )
    on conflict (user_low, user_high) do nothing;
  end if;

  return v_request;
end;
$$;

create function public.cancel_friend_request(p_request uuid)
returns void
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

  update public.friend_requests
     set status = 'cancelled', responded_at = now()
   where id = p_request
     and from_user = v_me
     and status = 'pending';

  if not found then
    raise exception 'pending friend request not found' using errcode = 'P0002';
  end if;
end;
$$;

create function public.remove_friend(p_other uuid)
returns void
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

  if p_other is null or p_other = v_me then
    raise exception 'invalid friend' using errcode = '22023';
  end if;

  -- The ordered pair is built from the caller and the target, so this can only remove a
  -- friendship the caller is part of.
  delete from public.friendships
   where user_low = least(v_me, p_other)
     and user_high = greatest(v_me, p_other);

  if not found then
    raise exception 'not friends' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.send_friend_request(text) from public;
revoke all on function public.respond_friend_request(uuid, boolean) from public;
revoke all on function public.cancel_friend_request(uuid) from public;
revoke all on function public.remove_friend(uuid) from public;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.cancel_friend_request(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
