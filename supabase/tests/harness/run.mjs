// Local verification harness for the Milestone 2A backend.
//
// Docker and the Supabase CLI are not available on this machine, so the migrations and security
// tests are executed against PGlite: real PostgreSQL compiled to WebAssembly, running in-process.
//
// What is faithful: the SQL, the roles, RLS, grants, constraints, triggers and SECURITY DEFINER
// semantics are genuine PostgreSQL. What is simulated: Supabase's `auth` schema. The harness
// creates auth.users and auth.uid(), where auth.uid() reads the same `request.jwt.claims` setting
// that Supabase's own implementation reads. That is the only substitution.
//
// Usage:  node run.mjs            (from this directory, or `npm test`)

import { readdir, readFile } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const here = dirname(fileURLToPath(import.meta.url));
const supabaseDir = resolve(here, '..', '..');
const migrationsDir = join(supabaseDir, 'migrations');
const testsDir = join(supabaseDir, 'tests');

// Minimal stand-in for the parts of Supabase a migration may reference.
const BOOTSTRAP = `
  create role anon nologin;
  create role authenticated nologin;

  create schema auth;

  create table auth.users (
    id uuid primary key,
    email text unique,
    created_at timestamptz not null default now()
  );

  -- Same contract as Supabase: the caller's id comes from the verified JWT claims, never from an
  -- argument, so a client cannot name a different user.
  create function auth.uid() returns uuid
    language sql
    stable
    as $$
      select nullif(
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'sub',
        ''
      )::uuid
    $$;

  grant usage on schema auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
  grant usage on schema public to anon, authenticated;
`;

const RED = '\u001b[31m';
const GREEN = '\u001b[32m';
const DIM = '\u001b[2m';
const RESET = '\u001b[0m';

const failures = [];
let passed = 0;

function short(error) {
  const message = String(error?.message ?? error).split('\n')[0].trim();
  return message.length > 400 ? `${message.slice(0, 400)}…` : message;
}

async function main() {
  const db = new PGlite();
  await db.exec(BOOTSTRAP);

  const migrations = (await readdir(migrationsDir))
    .filter((name) => name.endsWith('.sql'))
    .sort();

  for (const name of migrations) {
    const sql = await readFile(join(migrationsDir, name), 'utf8');
    try {
      await db.exec(sql);
      console.log(`${GREEN}applied${RESET} ${name}`);
    } catch (error) {
      console.error(`${RED}MIGRATION FAILED${RESET} ${name}\n  ${short(error)}`);
      process.exit(1);
    }
  }

  for (const name of ['00_test_helpers.sql', 'seed.sql']) {
    try {
      await db.exec(await readFile(join(testsDir, name), 'utf8'));
    } catch (error) {
      console.error(`${RED}FIXTURE FAILED${RESET} ${name}\n  ${short(error)}`);
      process.exit(1);
    }
  }

  const testFiles = (await readdir(testsDir))
    .filter((name) => name.endsWith('.test.sql'))
    .sort();

  for (const file of testFiles) {
    const source = await readFile(join(testsDir, file), 'utf8');
    for (const testCase of parseCases(source)) {
      // Each case starts from the committed fixture and is discarded afterwards, so a case can
      // never depend on the order of the ones before it.
      await db.exec('begin');
      try {
        await db.exec(testCase.sql);
        await db.exec('rollback');
        passed += 1;
        console.log(`${GREEN}PASS${RESET} ${file} ${DIM}›${RESET} ${testCase.name}`);
      } catch (error) {
        try {
          await db.exec('rollback');
        } catch {
          /* the transaction may already be gone */
        }
        failures.push({ file, name: testCase.name, message: short(error) });
        console.log(`${RED}FAIL${RESET} ${file} ${DIM}›${RESET} ${testCase.name}`);
      }
    }
  }

  console.log('');
  if (failures.length === 0) {
    console.log(`${GREEN}${passed} case(s) passed${RESET} across ${testFiles.length} file(s).`);
    return;
  }

  console.log(`${RED}${failures.length} case(s) failed${RESET}, ${passed} passed:`);
  for (const failure of failures) {
    console.log(`  ${failure.file} › ${failure.name}\n    ${failure.message}`);
  }
  process.exitCode = 1;
}

function parseCases(source) {
  const cases = [];
  let current = null;
  for (const line of source.split(/\r?\n/)) {
    const header = /^--\s*case:\s*(.+?)\s*$/.exec(line);
    if (header) {
      current = { name: header[1], sql: '' };
      cases.push(current);
      continue;
    }
    if (current) current.sql += `${line}\n`;
  }
  return cases;
}

await main();
