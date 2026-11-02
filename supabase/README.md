# FlowState backend — Milestone 2A

This directory holds the **optional** Supabase backend for FlowState's social features. Nothing here
is required for personal productivity: tasks, habits, notes, the timer, insights, settings, and
backup/restore keep working with no account, no network, and no backend
([plan §1](../docs/MILESTONE_2_PLAN.md)).

**Status:** phase 2A (backend foundation) is implemented and locally verified. Nothing is deployed,
no Supabase project exists, and the Flutter application is not integrated — `pubspec.yaml` is
unchanged. No secret or project credential is stored in this repository.

## What exists

| Area | Files |
|---|---|
| Versioned SQL migrations | `migrations/20261102*.sql` (eight files, applied in filename order) |
| Security and behaviour tests | `tests/*.test.sql`, fixtures in `tests/seed.sql` |
| Test helpers | `tests/00_test_helpers.sql` (test-only; never ship) |
| Local runner | `tests/harness/` (Node + PGlite, no Docker needed) |

### Tables

`profiles`, `friendships`, `friend_requests`, `blocks`, `rooms`, `room_members`, `room_invites`,
`room_messages`, `room_sessions`, `session_reports`, `session_heartbeats`, `invite_attempts`.

Two naming notes:

- **`room_sessions` is the group schedule** (leader, mode, `starts_at`, `ends_at`). The phase brief
  listed `room_schedules` and `room_sessions` separately; the approved data model has a single
  schedule entity, so there is one table. A separate "running instance" table was deliberately not
  invented.
- **`invite_attempts`** is not in the plan's table list, but the plan requires rate limiting on
  redemption, which needs a durable record of failed attempts.

### Functions

| Function | Purpose |
|---|---|
| `public.create_room(name, invite_policy)` | Creates a room and its owner membership atomically. |
| `public.create_room_invite(room, max_uses, expires_in)` | Mints a code server-side; returns the plaintext **once**, stores only its SHA-256 digest. |
| `public.revoke_room_invite(invite)` | Inviter or owner only. |
| `public.redeem_room_invite(code)` | Atomic, single-use-capable, expiring, rate-limited redemption. Returns `(room_id, outcome)`. |
| `public.leave_room(room)` | Refuses while the caller is the owner. |
| `public.transfer_room_ownership(room, new_owner)` | Owner only, target must be a live member. |
| `public.remove_room_member(room, user)` | Owner only; cannot target themselves. |
| `public.send_friend_request(handle)` | 20/day per sender, block-aware, duplicate-aware. |
| `public.respond_friend_request(request, accept)` | Recipient only; creates the friendship. |
| `public.cancel_friend_request(request)` | Sender only. |
| `public.remove_friend(user)` | Only ever removes a friendship the caller is part of. |
| `public.touch_presence()` | The only way a client can move its own `last_seen_at` (at most once per 30 s). |
| `public.room_leaderboard(room, since, until)` | Per-member totals split into self-reported and observed time. RLS applies (invoker rights). |

### Study-time attribution

`session_reports` keeps three independent things apart, as required by
[plan §9](../docs/MILESTONE_2_PLAN.md):

- `client_duration_ms` — what the device claims. Always present, never clamped, never rejected.
- `server_observed_ms` / `observed_start_at` / `observed_end_at` — populated **only** by trusted
  server code. Clients hold no privilege on these columns.
- `is_self_reported` — a generated column, `server_observed_ms is null`. Not writable by anyone.
- Sync state is not a remote column at all; delivery says nothing about observation.

An offline session that syncs later is stored, counted in personal and friend-group statistics, and
labelled self-reported. There is no cap, no anti-cheat, and no reconciliation heuristic. A
`SECURITY INVOKER` leaderboard function exposes the split so a caller can label the numbers instead
of presenting every minute as observed.

## Before you create a project

Two ways to check the SQL without spending anything:

```sh
# 1. Local harness (works without Docker or the Supabase CLI; this is what was run here)
cd supabase/tests/harness
npm install
npm test
```

```sh
# 2. A real Supabase local stack, once the CLI and Docker are installed
supabase start
supabase db reset                 # applies every migration in order
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -1 -v ON_ERROR_STOP=1 \
  -f tests/00_test_helpers.sql -f tests/seed.sql -f tests/01_access.test.sql
# ... repeat for 02, 03, 04, 05
```

Use `-1` (one transaction per file) so the helpers' `SET LOCAL ROLE` takes effect; without a
transaction block `SET LOCAL` is a no-op.

## Creating the project later (free tier)

1. Sign in at <https://supabase.com>, create a **new project** on the Free plan, and note its project
   ref. Free currently means a 500 MB database on a non-autoscaling 2 GB disk, 2 active projects,
   ~200 concurrent realtime connections, no automatic backups, and pausing after roughly a week of
   low activity (data preserved for about a year). Terms change; check them before relying on them.
2. From the repository root, run `supabase init`. It creates `supabase/config.toml` and leaves the
   existing `supabase/migrations/` untouched.
3. `supabase login`, then `supabase link --project-ref <your-ref>`.
4. `supabase db push` to apply the migrations. They are additive and ordered by filename.
5. Take the client key from **Project Settings → API keys**. The app must use the **publishable**
   key (`sb_publishable_…`). The secret / `service_role` key bypasses row level security and must
   never be shipped, logged, or committed. Do not put either key in this repository; the Flutter app
   will read the publishable key from its own build configuration in phase 2C.
6. Verify the result in the SQL editor:

   ```sql
   select tablename, rowsecurity from pg_tables where schemaname = 'public' order by tablename;
   -- every row must show rowsecurity = true
   ```

7. Because the Free plan has no automatic backups, export periodically:
   `supabase db dump -f flowstate-$(date +%F).sql`. Keep the dump private.

## Security model in one paragraph

Every table in `public` has row level security enabled and starts with **no** privilege for `anon`
or `authenticated`; access is then granted explicitly, sometimes per column (for example
`profiles`' public columns only, or `room_messages.deleted_at` alone). Clients never INSERT into
rooms, memberships or invitations — those are `SECURITY DEFINER` functions that re-derive the caller
from `auth.uid()` and re-check ownership, because a definer function bypasses RLS. Every definer
function pins `search_path` to the empty string and uses fully-qualified names. Blocking is
symmetric and enforced in both directions; a member row is the only thing that grants access to a
room. Tests assert all of this as an ordinary `authenticated` role, including the structural checks
that every public table has RLS and that no function is callable by `anon`.

## What is deliberately not implemented yet

- **No deployment, no project, no keys.** Nothing in this directory contacts a network service.
- **No client integration** (that is 2B–2H): no `supabase_flutter` dependency, no auth UI, no sync.
- **Account deletion RPC (2C).** `room_messages.author_id` is nullable with `ON DELETE SET NULL` so a
  deleted account leaves "deleted user" messages, but removing an `auth.users` row needs a secret
  key. That belongs with the identity phase, not here.
- **Realtime channel authorization policies (2F)** and `realtime.broadcast_changes()` triggers.
- **`session_heartbeats` / observed-time population.** The tables and constraints exist; the
  server-side writer arrives with realtime sessions in 2F.
- **Schema-level rate-limit tuning.** The current numbers (10 failed redemptions per 10 minutes, 20
  friend requests per day, 20 messages per minute) are starting points, not measured limits.

## Warning

`tests/` contains helpers that can switch database roles. Apply migrations only to a real project;
never apply `tests/00_test_helpers.sql` or the harness to a hosted database.
