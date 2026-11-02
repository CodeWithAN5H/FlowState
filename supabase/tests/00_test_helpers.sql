-- Test-only helpers. Never apply this file to a hosted project: it can switch roles, and it lives
-- outside supabase/migrations so `supabase db push` will not pick it up.
create schema if not exists tests;

-- Fixed identifiers for the seeded fixtures.
create function tests.alice() returns uuid language sql immutable as $$ select 'a1000000-0000-4000-8000-000000000001'::uuid $$;
create function tests.bob() returns uuid language sql immutable as $$ select 'a1000000-0000-4000-8000-000000000002'::uuid $$;
create function tests.carol() returns uuid language sql immutable as $$ select 'a1000000-0000-4000-8000-000000000003'::uuid $$;
create function tests.dave() returns uuid language sql immutable as $$ select 'a1000000-0000-4000-8000-000000000004'::uuid $$;
create function tests.room() returns uuid language sql immutable as $$ select 'b1000000-0000-4000-8000-000000000001'::uuid $$;

-- Assume a signed-in identity exactly the way PostgREST/GoTrue do: the JWT claims are placed in
-- request.jwt.claims and the role becomes `authenticated`.
create function tests.as_user(p_user uuid) returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text,
    true
  );
  execute 'set local role authenticated';
end;
$$;

create function tests.as_anon() returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  execute 'set local role anon';
end;
$$;

create function tests.check(p_label text, p_ok boolean) returns boolean
language plpgsql
as $$
begin
  if p_ok is null or not p_ok then
    raise exception 'FAILED: %', p_label;
  end if;
  return true;
end;
$$;

create function tests.eq(p_label text, p_actual text, p_expected text) returns boolean
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAILED: % (got %, expected %)',
      p_label, coalesce(p_actual, '<null>'), coalesce(p_expected, '<null>');
  end if;
  return true;
end;
$$;

-- Asserts that a statement is refused. Used for privilege and RLS denials, where the absence of an
-- error would be the bug.
create function tests.expect_error(p_label text, p_sql text) returns boolean
language plpgsql
as $$
begin
  begin
    execute p_sql;
  exception
    when others then
      return true;
  end;

  raise exception 'FAILED: % (expected a refusal, the statement succeeded)', p_label;
end;
$$;

grant usage on schema tests to anon, authenticated;
grant execute on all functions in schema tests to anon, authenticated;
