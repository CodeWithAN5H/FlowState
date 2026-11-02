-- 20261102090800_hardening.sql
--
-- Defensive defaults.
--
-- Supabase grants broad privileges on new public tables to anon/authenticated by default, and
-- adding a policy does not revoke them (plan §2, "Grants vs policies footgun"). Migrations in
-- this directory already revoke explicitly per table; this removes the trap for tables added
-- later, so a forgotten revoke results in an unreadable table rather than an exposed one.

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'postgres') then
    execute $sql$
      alter default privileges for role postgres in schema public
        revoke all on tables from anon, authenticated
    $sql$;
  end if;
end;
$$;
