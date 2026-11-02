-- 20261102090600_functions_rooms.sql
--
-- Room lifecycle, invitations, and membership changes.
--
-- Clients hold no INSERT/UPDATE/DELETE privilege on rooms, room_members, or room_invites, so these
-- functions are the only write path. Each re-checks ownership or membership explicitly, because a
-- SECURITY DEFINER function bypasses the RLS policies that would otherwise apply.

-- pgcrypto is the only extension this schema depends on, and plan §2 explicitly allows it. It
-- provides gen_random_bytes(), the only way to obtain cryptographically secure random bytes from
-- inside SQL, which invitation codes require.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regprocedure('extensions.gen_random_bytes(integer)') is null then
    raise exception 'pgcrypto must be installed in the extensions schema for invitation codes'
      using errcode = '58P01';
  end if;
end;
$$;

create type public.invite_redemption as (room_id uuid, outcome text);

create function public.create_room(
  p_name text,
  p_invite_policy public.room_invite_policy default 'owner_only'
)
returns public.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_room public.rooms;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- The name constraint on public.rooms rejects an empty or overlong name.
  insert into public.rooms (name, owner_id, invite_policy)
  values (btrim(coalesce(p_name, '')), v_me, coalesce(p_invite_policy, 'owner_only'))
  returning * into v_room;

  insert into public.room_members (room_id, user_id, role)
  values (v_room.id, v_me, 'owner');

  return v_room;
end;
$$;

-- The code is generated server-side and returned exactly once. Only its SHA-256 hash is stored, so
-- neither a database read nor a later API call can recover a working invitation.
create function public.create_room_invite(
  p_room uuid,
  p_max_uses integer default 1,
  p_expires_in interval default interval '7 days'
)
returns table (invite_id uuid, code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_room public.rooms;
  v_code text;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select * into v_room from public.rooms r where r.id = p_room;

  if not found then
    raise exception 'room not found' using errcode = 'P0002';
  end if;

  if v_room.archived_at is not null then
    raise exception 'this room is archived' using errcode = '22023';
  end if;

  if not (
    app.is_room_owner(p_room)
    or (v_room.invite_policy = 'all_members' and app.is_room_member(p_room))
  ) then
    raise exception 'not allowed to create invitations for this room' using errcode = '42501';
  end if;

  if p_expires_in is null or p_expires_in <= interval '0' or p_expires_in > interval '30 days' then
    raise exception 'invitation expiry must be more than 0 and at most 30 days'
      using errcode = '22023';
  end if;

  if coalesce(p_max_uses, 1) < 1 or coalesce(p_max_uses, 1) > 100 then
    raise exception 'invitation uses must be between 1 and 100' using errcode = '22023';
  end if;

  -- Minting is unbounded otherwise: every active code is a credential that grants room access, so a
  -- member with invite rights could create an unlimited number of them. The cap bounds both that
  -- and the row growth it causes.
  if (
    select count(*)
      from public.room_invites i
     where i.room_id = p_room
       and i.revoked_at is null
       and i.expires_at > now()
       and i.uses < i.max_uses
  ) >= 25 then
    raise exception 'this room already has too many active invitations' using errcode = '42901';
  end if;

  -- 128 bits of entropy from the platform CSPRNG: 16 random bytes rendered as 32 lowercase hex
  -- characters. Only the SHA-256 digest is stored, so a database read cannot recover a working code.
  v_code := encode(extensions.gen_random_bytes(16), 'hex');

  insert into public.room_invites (room_id, created_by, code_hash, max_uses, expires_at)
  values (
    p_room,
    v_me,
    encode(sha256(convert_to(v_code, 'UTF8')), 'hex'),
    coalesce(p_max_uses, 1),
    now() + p_expires_in
  )
  returning id into v_id;

  return query select v_id, v_code;
end;
$$;

create function public.revoke_room_invite(p_invite uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_invite public.room_invites;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select * into v_invite from public.room_invites i where i.id = p_invite;

  if not found then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;

  if not (v_invite.created_by = v_me or app.is_room_owner(v_invite.room_id)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  update public.room_invites
     set revoked_at = coalesce(revoked_at, now())
   where id = p_invite;
end;
$$;

-- Returns an outcome rather than raising on failure so the attempt is still recorded after a
-- rejection; see 20261102090400_rate_limits.sql.
create function public.redeem_room_invite(p_code text)
returns public.invite_redemption
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_hash text;
  v_invite public.room_invites;
  v_room public.rooms;
  v_failures integer;
begin
  if v_me is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- Opportunistic housekeeping: attempts are only interesting for a short window.
  delete from public.invite_attempts a where a.attempted_at < now() - interval '2 days';

  select count(*)
    into v_failures
    from public.invite_attempts a
   where a.user_id = v_me
     and not a.succeeded
     and a.attempted_at > now() - interval '10 minutes';

  if v_failures >= 10 then
    return (null::uuid, 'rate_limited'::text);
  end if;

  v_hash := encode(
    sha256(convert_to(lower(btrim(coalesce(p_code, ''))), 'UTF8')),
    'hex'
  );

  -- FOR UPDATE serialises concurrent redemptions of the same invitation, so a single-use code
  -- cannot be consumed twice by two devices at the same moment.
  select * into v_invite from public.room_invites i where i.code_hash = v_hash for update;

  if not found then
    insert into public.invite_attempts (user_id) values (v_me);
    return (null::uuid, 'invalid'::text);
  end if;

  select * into v_room from public.rooms r where r.id = v_invite.room_id;

  if v_room.archived_at is not null then
    insert into public.invite_attempts (user_id) values (v_me);
    return (null::uuid, 'archived'::text);
  end if;

  -- Redeeming a code for a room you are already in is idempotent, not an error.
  if app.is_active_member(v_invite.room_id, v_me) then
    insert into public.invite_attempts (user_id, succeeded) values (v_me, true);
    return (v_invite.room_id, 'already_member'::text);
  end if;

  if v_invite.revoked_at is not null then
    insert into public.invite_attempts (user_id) values (v_me);
    return (null::uuid, 'revoked'::text);
  end if;

  if v_invite.expires_at <= now() then
    insert into public.invite_attempts (user_id) values (v_me);
    return (null::uuid, 'expired'::text);
  end if;

  if v_invite.uses >= v_invite.max_uses then
    insert into public.invite_attempts (user_id) values (v_me);
    return (null::uuid, 'exhausted'::text);
  end if;

  update public.room_invites set uses = uses + 1 where id = v_invite.id;

  insert into public.room_members (room_id, user_id, role)
  values (v_invite.room_id, v_me, 'member');

  insert into public.invite_attempts (user_id, succeeded) values (v_me, true);

  return (v_invite.room_id, 'joined'::text);
end;
$$;

create function public.leave_room(p_room uuid)
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

  if app.is_room_owner(p_room) then
    raise exception 'the owner must transfer ownership before leaving'
      using errcode = '42501';
  end if;

  update public.room_members
     set removed_at = now()
   where room_id = p_room
     and user_id = v_me
     and removed_at is null;

  if not found then
    raise exception 'not a member of this room' using errcode = 'P0002';
  end if;
end;
$$;

create function public.transfer_room_ownership(p_room uuid, p_new_owner uuid)
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

  if not app.is_room_owner(p_room) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if p_new_owner is null or p_new_owner = v_me then
    raise exception 'choose another member as the new owner' using errcode = '22023';
  end if;

  if not app.is_active_member(p_room, p_new_owner) then
    raise exception 'the new owner must be a current member' using errcode = 'P0002';
  end if;

  -- Demote first: the partial unique index allows exactly one live owner per room.
  update public.room_members
     set role = 'member'
   where room_id = p_room
     and user_id = v_me
     and removed_at is null;

  update public.room_members
     set role = 'owner'
   where room_id = p_room
     and user_id = p_new_owner
     and removed_at is null;

  update public.rooms
     set owner_id = p_new_owner
   where id = p_room;
end;
$$;

create function public.remove_room_member(p_room uuid, p_user uuid)
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

  if not app.is_room_owner(p_room) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if p_user is null or p_user = v_me then
    raise exception 'use leave_room to leave your own room' using errcode = '22023';
  end if;

  update public.room_members
     set removed_at = now()
   where room_id = p_room
     and user_id = p_user
     and removed_at is null;

  if not found then
    raise exception 'that user is not a member of this room' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.create_room(text, public.room_invite_policy) from public;
revoke all on function public.create_room_invite(uuid, integer, interval) from public;
revoke all on function public.revoke_room_invite(uuid) from public;
revoke all on function public.redeem_room_invite(text) from public;
revoke all on function public.leave_room(uuid) from public;
revoke all on function public.transfer_room_ownership(uuid, uuid) from public;
revoke all on function public.remove_room_member(uuid, uuid) from public;

grant execute on function public.create_room(text, public.room_invite_policy) to authenticated;
grant execute on function public.create_room_invite(uuid, integer, interval) to authenticated;
grant execute on function public.revoke_room_invite(uuid) to authenticated;
grant execute on function public.redeem_room_invite(text) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.transfer_room_ownership(uuid, uuid) to authenticated;
grant execute on function public.remove_room_member(uuid, uuid) to authenticated;
