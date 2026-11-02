-- Structural hardening checks. These run as the migration owner and inspect the catalog, so they
-- catch a table that was added without RLS, a grant that leaked to anon, or a SECURITY DEFINER
-- function whose search_path is hijackable.

-- case: every public table is protected by row level security
select tests.eq('every public table has RLS enabled',
  (select coalesce(string_agg(c.relname, ', ' order by c.relname), 'none')
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and not c.relrowsecurity),
  'none');

-- case: anon holds no privilege at all
select tests.eq('anon holds no table privilege',
  (select coalesce(string_agg(distinct g.table_name, ', '), 'none')
     from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.grantee = 'anon'),
  'none');

select tests.eq('anon holds no column privilege',
  (select coalesce(string_agg(distinct c.table_name || '.' || c.column_name, ', '), 'none')
     from information_schema.column_privileges c
    where c.table_schema = 'public' and c.grantee = 'anon'),
  'none');

select tests.eq('no backend function is callable by anon',
  (select coalesce(string_agg(distinct p.proname, ', '), 'none')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app')
      and has_function_privilege('anon', p.oid, 'execute')),
  'none');

-- case: server-only tables are closed to signed-in clients
select tests.eq('authenticated holds no privilege on heartbeats',
  (select coalesce(string_agg(distinct g.privilege_type, ', '), 'none')
     from information_schema.role_table_grants g
    where g.table_schema = 'public'
      and g.table_name = 'session_heartbeats'
      and g.grantee = 'authenticated'),
  'none');

select tests.eq('authenticated holds no privilege on invite attempts',
  (select coalesce(string_agg(distinct g.privilege_type, ', '), 'none')
     from information_schema.role_table_grants g
    where g.table_schema = 'public'
      and g.table_name = 'invite_attempts'
      and g.grantee = 'authenticated'),
  'none');

select tests.eq('authenticated cannot read invitation hashes',
  (select coalesce(string_agg(distinct c.column_name, ', '), 'none')
     from information_schema.column_privileges c
    where c.table_schema = 'public'
      and c.table_name = 'room_invites'
      and c.grantee = 'authenticated'
      and c.column_name = 'code_hash'),
  'none');

select tests.eq('authenticated cannot write the observation columns',
  (select coalesce(string_agg(distinct c.column_name, ', '), 'none')
     from information_schema.column_privileges c
    where c.table_schema = 'public'
      and c.table_name = 'session_reports'
      and c.grantee = 'authenticated'
      and c.privilege_type in ('INSERT', 'UPDATE')
      and c.column_name in ('server_observed_ms', 'observed_start_at', 'observed_end_at', 'is_self_reported')),
  'none');

-- case: invitation codes are stored only as digests
select tests.eq('a code is stored as its SHA-256 digest',
  (select code_hash from public.room_invites where id = 'f3000000-0000-4000-8000-000000000001'),
  encode(sha256(convert_to('aaaaaaaaaa', 'UTF8')), 'hex'));

select tests.eq('the plaintext code appears in no stored column',
  (select count(*) from public.room_invites where code_hash like '%aaaaaaaaaa%')::text,
  '0');

-- case: SECURITY DEFINER functions cannot be hijacked through search_path
select tests.eq('every SECURITY DEFINER function pins search_path',
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), 'none')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef
      and n.nspname in ('public', 'app')
      and not exists (
        select 1
          from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg
         where cfg like 'search_path=%'
      )),
  'none');

select tests.eq('no SECURITY DEFINER function searches public',
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), 'none')
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef
      and n.nspname in ('public', 'app')
      and exists (
        select 1
          from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg
         where cfg like 'search_path=%' and cfg like '%public%'
      )),
  'none');

-- case: internal helpers are unreachable by clients
select tests.as_user(tests.carol());
select tests.expect_error('the internal membership probe is not callable', $$select app.is_active_member('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002')$$);
select tests.expect_error('the internal block probe is not callable', $$select app.block_exists_between('a1000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000004')$$);
select tests.expect_error('a trigger function is not callable as a query', $$select app.room_messages_before_insert()$$);
select tests.expect_error('the user provisioner is not callable', $$select app.handle_new_user()$$);
