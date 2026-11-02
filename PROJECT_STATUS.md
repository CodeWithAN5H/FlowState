# FlowState — Project Status

**Status date:** 2026-11-02
**Current phase:** Milestones 0, 1A, 1B, and 1C are complete and pushed. Milestone 2 is in progress: 2A (backend SQL) and 2B (local schema v4 with sync scaffolding) are implemented and committed, and the app is still fully offline-first — no Supabase client, no dependency, no account, no network call. Phases 2C–2H are planned in [docs/MILESTONE_2_PLAN.md](docs/MILESTONE_2_PLAN.md).
**Starting baseline:** commit `812f8d3` (`Milestone 1B partial: add offline data and task workflows`), branch `main`, clean tree matching `origin/main`.
**Milestone 1B boundary:** local SQLite with migrations, session persistence/recovery, persistent task CRUD, saved-data Home dashboard, and existing timer integration. Offline only. Accounts, cloud sync, study rooms, Focus Lock, habits/notes/settings, and release artifacts are out of scope.

## 1. Starter files confirmed

The Git working tree was clean at review time on branch `main`; the following existing starter files are tracked:

- `prompt.md` — product and implementation requirements.
- `pubspec.yaml` — Flutter package metadata; Drift/SQLite dependencies were added for Milestone 1B.
- `lib/main.dart` — app shell with the Material 3 dark theme and injectable database.
- `lib/focus_timer.dart` — monotonic stopwatch model.
- `test/focus_timer_test.dart` — deterministic lifecycle tests using a fake clock.
- `README.md` — architecture, milestone plan, constraints, setup, and distribution roadmap.

`PROJECT_STATUS.md` did not exist before this review and is the new status record. Windows and Android runner scaffolding was generated from the installed SDK; there is no Linux runner on this Windows host.

## 2. Environment and Milestone 1A baseline verification

Environment: Windows 11 through MINGW64/Git Bash; Java 21 available. Initially Flutter/Dart were unavailable on PATH and were not found in the checked project and common SDK locations. The official stable Windows archive for Flutter 3.47.8 was downloaded, its 1,937,300,499-byte size and MD5 (`ca208e3066cce928600bb56b4c4c5011`) checked, and it was extracted under the ignored project-local `.tooling/flutter/` directory. System PATH was not modified. SDK provides Dart 3.13.7. The normal Flutter `.bat` command hangs when launched from this host's Git Bash, so successful Flutter tool commands used the SDK bundled Dart executable with `flutter_tools.snapshot` directly; they are the real Flutter tool actions, not static substitutes.

Visual Studio 2022 Community is present; `vswhere` confirms the Native Desktop workload and VC x86/x64 tools; Windows SDK 10.0.26100.0 is present. Windows and Android runners were generated via `flutter create --platforms=windows,android --no-pub --project-name flowstate .`. No Linux runner/device test was attempted on this host.

- **Starter/source files:** verified present before Milestone 1A work. Its Markdown structure and `git diff --check` passed at that time.
- **`flutter pub get`:** passed, initially resolving 24 Flutter SDK/test dependencies; final rerun reports `Got dependencies!`.
- **`flutter analyze`:** initial analysis found one unnecessary `dart:ui` import, which was removed; the generated lint include was also replaced with a valid dependency-free configuration. Final analysis after all source edits reports `No issues found!`.
- **`flutter test`:** passed, all five deterministic focus timer lifecycle tests.
- **`flutter create --platforms=windows,android --no-pub --project-name flowstate .`:** completed and generated platform runners.
- **`flutter run -d windows`:** passed. `flowstate.exe` compiled, Flutter synced to the Windows desktop target, and the native app process was observed running. The final launch log contained no `ListTile` assertion or `RenderFlex` overflow. The first launch had exposed those issues; both were fixed before a fresh build/relaunch.
- **Android/Linux/device tests:** not run. Android runner is scaffolded only; Flutter Doctor reports Android SDK unavailable. No Linux environment was verified.
- **Release builds/artifacts/installers:** none generated or tested; the observed Windows debug executable is a development run output, not a release installer.

## 3. Current implementation and known limits

- Milestone 1B now uses Drift/SQLite with a version-2 task/session schema and an explicit v1-to-v2 migration. Repositories provide persistent task CRUD, session lifecycle/recovery, and local dashboard queries.
- Home, Tasks, and Focus navigation is functional, responsive, and local. Timer state continues to use the monotonic `FocusTimer` during a run, with persisted wall-clock anchors and accumulated paused duration for restart recovery.
- Milestone 1B has passed native Windows build/runtime verification with Developer Mode enabled. The debug build compiles, the app starts into the Home dashboard with no error state, and an on-device integration test drives task creation/completion and a full focus session, then confirms the data survives a restart.
- Verification found and fixed two real runtime defects: the SQLite file was created in `Documents`, which Windows Controlled Folder Access blocks (startup showed `SqliteException(14)`), and the task editor disposed its text controllers during the dialog's closing animation. The 16-test suite now includes a widget regression test for the editor lifecycle.
- Habits, notes, insights, settings, and JSON backup/restore are implemented in Milestone 1C (§6); notification delivery, accounts, sync, study rooms, CSV export, and Focus Lock remain unimplemented.
- Windows and Android runner scaffolding was generated; the local Flutter SDK is under ignored `.tooling/`. The Flutter `.bat` shim hangs in this Git Bash environment; the successful verification and Windows launch used the direct SDK tool-snapshot invocation documented in README.
- Focus Lock remains a high-risk, separately scoped future feature. A Chromium extension would limit rules to compatible browsers and be user-removable in ordinary configurations. Android Accessibility is only a transparent, opt-in, best-effort focus aid for an ordinary user app, not a reliable OS-enforced app lock; permissions, lifecycle limits, user bypasses, and store policy all need further validation.
- Supabase is documented only as a candidate optional backend; no service has been integrated or configured.
- Windows installer, Linux package, Android APK, release signing, upgrades, and distribution remain unimplemented.

## 4. Milestone 1A close-out

Milestone 1A is complete: Flutter dependency resolution and clean static analysis succeeded, all five deterministic timer tests passed, and the Windows debug app built and was observed running after fixing issues found by the first live run. The final run log was clear of those UI assertions and overflow. Flutter SDK files, build output, and local logs are excluded from Git. No global PATH/system settings were changed.

The Windows debug app process was stopped after its successful launch check. Android device and Linux platform checks remain unverified; Android SDK/device support is unavailable in this environment. No release build or installation artifact was produced.

## 5. Milestone 1B completion

Work resumed from commit `812f8d3` on `main` with a clean tree matching `origin/main`. Developer Mode was enabled by the project owner, which removed the plugin-symlink blocker. `.tooling/flutter/`, `.dart_tool/`, and Flutter `build/` outputs remain ignored; the tracked source contains no environment files, credentials, signing keys, or machine-specific SDK/build output.

Verified on Windows with Flutter 3.47.8 / Dart 3.13.7 and Visual Studio 2022's C++ desktop workload:

- `flutter pub get` — succeeded.
- `dart format lib test integration_test` — no changes needed.
- `flutter analyze` — `No issues found!`.
- `flutter test` — all 16 tests passed (seven timer/restore, seven SQLite repository/session, one v1→v2 migration, one task-editor widget test).
- `flutter build windows --debug` — succeeded (`build/windows/x64/runner/Debug/flowstate.exe`).
- Launch of the built executable — window responsive, Home dashboard rendered with real stat cards and empty-state copy, no `SqliteException` or error screen, and no exceptions in the run log.
- `flutter test integration_test/app_flow_test.dart -d windows` — passed on the Windows desktop target: created a task, completed it, ran a focus session (start → pause → resume → finish), confirmed the recorded duration and Home statistics came from stored records, restarted against the same database file, and confirmed the completed task and statistics persisted.
- Persistence across a full process restart — a stored task and a 20-minute completed session were still displayed after relaunching the debug executable (`%APPDATA%\com.example\flowstate\flowstate.sqlite`).

Defects found and fixed during verification:

1. The default Drift database path resolved to `Documents`, which Windows Controlled Folder Access protects; the app started into `SqliteException(14): unable to open database file`. The database now uses the app support directory (`%APPDATA%\com.example\flowstate`).
2. The task editor disposed its `TextEditingController`s while the dialog was still closing, throwing `A TextEditingController was used after being disposed`. Controllers and dialog state now live in a dedicated dialog widget; a widget regression test covers it.
3. A date-dependent test compared a `DateTime.now()` completion stamp against a hardcoded 2026-10-29, so it began failing on the next day. `setCompleted` now takes an optional `now`, and the test also asserts a completion outside the queried day is not counted.
4. Dead starter UI (`FocusScreen` and its helpers in `lib/main.dart`) that still claimed sessions were not saved was removed.

Milestone 1B is complete. Android device testing, Linux builds, release builds, installers, and the APK remain unverified; the Android SDK is absent from this machine.

## 6. Milestone 1C completion

Work started from commit `2a51609` (`Milestone 1B: verify Windows runtime and fix data path and dialog lifecycle`). The project owner reset the local `main` branch to that commit and asked for no pull, merge, rebase, or any other synchronization with `origin/main`, so the two newer remote commits were deliberately left unintegrated and Milestone 1C was implemented on top of the local 1B code. Those two lines were later reconciled with a real merge commit; see §7.

### Schema (v3)

`lib/data/flowstate_database.dart` raises `schemaVersion` to 3 and adds `habits`, `habit_completions`, `notes`, and `preferences`. The upgrade is additive — `if (from < 3) createTable(...)` — so existing tasks and sessions are untouched. `PRAGMA foreign_keys = ON` in `beforeOpen` makes habit history cascade with its habit, and `habit_completions` is unique on `(habit_id, completed_on)` so a day cannot be completed twice. `test/database_migration_test.dart` covers v1 → v3 (legacy rows preserved, new tables present, `user_version` 3) and v2 → v3 (rows preserved, new tables usable, cascade works).

### Features

- **Habits** (`lib/data/habits_repository.dart`, `lib/habits_page.dart`): create/edit, archive/restore, delete with confirmation, per-day check-in and undo, current streaks, weekly consistency across elapsed days only, local completion history, and empty states. Days use a timezone-independent day index, so a late-evening check-in still belongs to that calendar day, and a day that is not yet checked in keeps yesterday's streak alive.
- **Notes** (`lib/data/notes_repository.dart`, `lib/notes_page.dart`): create/edit/delete, case-insensitive search over title and content, created and edited timestamps, an explicit Save dialog, plain-text storage where Markdown is kept exactly as typed, and distinct empty and no-match states.
- **Insights** (`lib/data/insights_repository.dart`, `lib/insights_page.dart`): today/week/month focus time and completed-session counts, task completion and open-task counts, active habits with today's check-ins and week consistency, a daily-goal bar, a seven-day focus chart, and a `Nothing measured yet` empty state. Only `completed` sessions count, and every number is computed from stored rows — no sample activity is ever shown.
- **Settings** (`lib/data/settings_repository.dart`, `lib/settings_page.dart`): week start (Monday/Sunday) and a daily focus goal persisted in the `preferences` table and used by habits and insights; a dark-theme statement; app, storage-path, privacy, and Focus Lock information; JSON backup export and restore; and data reset behind a typed `RESET` confirmation.
- **Backup/restore** (`lib/data/backup_service.dart`): a versioned `flowstate-backup` JSON document (format 1, schema 3) containing tasks, focus sessions, habits, habit history, notes, and preferences. Import validates format, version, schema, dates, numbers, and habit-history references before changing anything, writes an automatic safety backup, then replaces all rows in one transaction. Restore is replace-only with no merge mode, and the UI says so explicitly.

### Verification on Windows

- `dart format --output=none --set-exit-if-changed lib test integration_test` — no changes.
- `flutter analyze` — `No issues found!`.
- `flutter test` — all **45** tests passed: habits, notes, settings, insights, backup/restore/validation/reset, v1→v3 and v2→v3 migrations, plus the existing timer, task, session, and editor tests.
- `flutter build windows --debug` — succeeded (`build/windows/x64/runner/Debug/flowstate.exe`).
- Launch of the built executable — the process started and stayed running, and its log contained only the Impeller backend and VM-service lines, with no exception or error screen.
- The real app database (`%APPDATA%\com.example\flowstate\flowstate.sqlite`) was migrated by that launch: `PRAGMA user_version` is 3 and `habits`, `habit_completions`, `notes`, and `preferences` exist alongside `tasks` and `focus_sessions`.
- `flutter test integration_test/app_flow_test.dart -d windows` — both on-device tests passed: the existing task/focus/restart flow, plus a new flow that creates and checks in a habit, saves and searches a note, confirms Insights starts empty and then fills from a real completed session, changes the week start, and reopens the same database file with the habit, note, and preference intact.

### Known limitations

- The app is dark-theme only. A light theme requires a design-token pass over the existing 1B surfaces, so Settings states that plainly rather than offering a switch that would render poorly.
- The focus timer is a stopwatch, so Pomodoro and custom countdown modes — and therefore duration presets — do not exist yet; the daily focus goal is the only focus preference.
- Restore replaces all local data; merging is not offered, and no CSV export is implemented.
- Home still shows focus and task statistics only; habit progress and recent notes are not on the dashboard.
- Notes are stored as plain text with Markdown untouched; nothing is rendered.
- Android device testing, Linux builds, release builds, installers, and the APK remain unverified; the Android SDK is absent from this machine.
- Git: the earlier local/remote divergence is resolved. Both Milestone 1C histories are merged in `3c3673d`, pushed, and `main` equals `origin/main`; see §7.

Milestone 1C is complete: habits, notes, insights, settings, and backup/restore are implemented, tested, built, launched, and exercised through on-device Windows integration tests. Both its local and remote histories are merged in `3c3673d`, which is pushed, so `main` and `origin/main` are identical.

## 7. Milestone 1C merge and repository synchronization

On 2026-11-01 the two independently developed Milestone 1C lines were reconciled with an explicit merge commit, `3c3673da1378a6f95dc1e1fd90391659a543f4fa` (`Merge origin/main into main`), whose parents are the local tip `39e4a0e` and the remote tip `3929e00`. No commit was rebased, squashed, reset, cherry-picked, or force-pushed, both histories are ancestors of the merge, and the result was pushed with a normal fast-forward update (`3929e00..3c3673d`). `git rev-parse HEAD` and `git rev-parse origin/main` both resolve to `3c3673d`, and the working tree is clean.

Thirteen files conflicted because each branch implemented Milestone 1C independently. They were resolved file by file rather than with a blanket ours/theirs rule:

- **Kept local:** `lib/data/backup_service.dart` (validated replace-only restore with an automatic safety backup and an `inspect()` preview), the habit, insight, note, and settings repositories, `lib/data/flowstate_database.dart`, and the five conflicting test files that exercise that API. This is the implementation the UI pages, widget tests, and integration tests call.
- **Regenerated:** `lib/data/flowstate_database.g.dart` was rebuilt with `build_runner` from the retained schema instead of being hand-merged.
- **Kept from remote:** the optional `now` parameter on `TasksRepository.create`, and the Windows plugin registrations for `file_selector`, which both branches needed.
- **Dropped:** the remote-only `async` dependency, which the retained code does not use.

Verification was re-run with the merge applied and before the merge commit existed: `dart format` reported no changes, `flutter analyze` reported no issues, `flutter test` passed all 45 tests, `flutter build windows --debug` succeeded, and both Windows integration tests passed.

### Schema reconciliation caveat

The two branches described habits and notes slightly differently. The local definitions were retained: `habits.details` (the remote branch used `description`) and `notes.title` without a length cap. The remote-only column definitions were **not** migrated, because nothing in the repository, the on-disk database, or the backup format depends on them: the only real database here has been migrated by the retained schema, and the versioned JSON format maps to the retained columns. A speculative migration was therefore deliberately not written.

This is a real compatibility limit rather than a cosmetic detail. A database created by the discarded remote build also reports `user_version = 3`, but its `habits` table has `description` and no `details`, so the retained code would fail on the missing column instead of opening it. Should such a database ever appear, a targeted v3 compatibility migration would be required first. No such database is known to exist today.

## 8. Milestone 2A backend foundation (2026-11-02)

Milestone 2A is implemented as backend SQL only, under `supabase/`. The Flutter application, its
`pubspec.yaml`, `lib/`, `test/`, and the local SQLite schema are unchanged; the app still requires no
account and no network, and nothing is deployed or integrated.

**Schema.** Eight additive migrations create `profiles`, `friendships`, `friend_requests`, `blocks`,
`rooms`, `room_members`, `room_invites`, `room_messages`, `room_sessions`, `session_reports`,
`session_heartbeats`, and `invite_attempts`. Row level security is enabled on every table and each
one is closed to `anon` and `authenticated` before explicit grants are added — several of them
per-column, so clients cannot read `profiles.last_seen_at`, `room_invites.code_hash`, or any
`session_reports.server_observed_*` column. A defensive default-privilege migration means a future
table starts unreadable rather than exposed.

**Authorization.** No client holds INSERT/UPDATE/DELETE on rooms, memberships, invitations,
friendships, or blocks. Those changes go through `SECURITY DEFINER` functions that derive the caller
from `auth.uid()` and re-check ownership or membership, because a definer function bypasses RLS. All
of them pin `search_path` to the empty string with fully-qualified names. Blocks are symmetric and end
any friendship or pending request; invitation codes are hashed with SHA-256, single-use by default,
expiring, revocable, capped per room, atomically redeemed under a row lock, and rate limited
against guessing. Codes carry 128 bits of entropy and only their SHA-256 digest is stored. Room
messages are member-only, length- and rate-limited, soft-deletable, and not editable. Removing a
member closes their membership interval immediately and revokes message access.

**Study time.** `session_reports` keeps the plan §9 attributes apart: the device's
`client_duration_ms` is accepted as-is with no cap or heuristic, the `server_observed_*` columns and
the generated `is_self_reported` label cannot be written by clients, and sync state is not a remote
column. An offline session that syncs later is stored, counted in `room_leaderboard()`'s totals, and
reported as self-reported time with the observed share split out.

**Verification.** Docker and the Supabase CLI are not installed on this machine, so the suite runs
against PGlite (PostgreSQL 18 in WebAssembly) through `supabase/tests/harness`: all **46 security
cases pass** across five files — anonymous and cross-user isolation, room and message access,
membership and ownership controls, invitation reuse/expiry/revocation/rate limiting, friendship and
block rules, attribution behaviour, and structural checks for RLS, grants, and `search_path` pinning.
This is real PostgreSQL running the real migrations, but the `auth` schema is a stub, so PostgREST,
GoTrue sign-in, realtime authorization, and project pausing remain **unverified** until a local
Supabase stack or disposable project exists. No Supabase account or project was created, nothing was
deployed, and no credential is stored in the repository.

## 9. Milestone 2A security review (2026-11-02)

A review pass over every migration and function produced two fixes and one hardening change:

1. **Account deletion was impossible.** `room_messages` uses `ON DELETE SET NULL` for `author_id`,
   and that internal update fires the "messages cannot be edited" trigger, so deleting a profile
   failed. The guard now permits only the anonymising change (author cleared, body and room
   unchanged) and still refuses reassignment. A structural test deletes an author and asserts the
   message survives with a null author.
2. **Invitation codes carried 40 bits.** They are now 128 bits: 16 bytes from
   `extensions.gen_random_bytes(16)` rendered as 32 lowercase hex characters, still stored only as a
   SHA-256 digest and returned in plaintext once. `pgcrypto` is the schema's only extension
   dependency; a migration-time check fails fast if it is absent, and the fixture codes, tests and
   documentation were updated with it.
3. **Invitation minting was unbounded.** Each active code is a credential, so a room is now capped at
   25 active codes; minting past that returns a rate-limit error. A test mints in a loop and asserts
   both the refusal and that the rejected burst stored nothing.

The review also re-confirmed: RLS on every public table; no `anon` privilege on any table, column, or
function; column-level protection of `profiles.last_seen_at`, `room_invites.code_hash`, and every
`session_reports.server_observed_*` column; every `SECURITY DEFINER` function pinned to an empty
`search_path`; internal helpers unreachable by clients; and the approved offline-time policy intact —
self-reported time counts, sync never implies observation.

Known gaps, reported rather than silently accepted: a user can still create unlimited rooms (row
growth only, no access granted, bounded by friends-scale use); handles can be changed without the
planned cooldown; and redemption is serialised with `FOR UPDATE` but was not exercised under real
concurrency, because the harness is single-connection.

## 10. Milestone 2B local schema v4 and sync scaffolding (2026-11-02)

Milestone 2B prepares the local database for a future *optional* sync engine. It adds no network code,
no Supabase client, no account, and no login UI: the application behaves exactly as it did in Milestone
1C, and SQLite remains the only source of truth.

### Schema v4

`lib/data/flowstate_database.dart` raises `schemaVersion` to 4. The upgrade is additive — `if (from < 4)`
adds columns and tables — and no committed migration was rewritten.

- **Stable identifiers.** `tasks`, `habits`, `notes`, and `focus_sessions` gain a `uuid` text column with
  a Dart-side `clientDefault`, so every new row is minted one automatically. Existing rows are backfilled
  in SQL during the upgrade, and each table gets an explicitly named unique index
  (`tasks_uuid_unique`, …) so a migrated database and a freshly created one agree. Integer primary keys
  are untouched and remain the local keys every query and relation already uses.
- **`sync_outbox`** — pending operations with a unique `operation_id`, entity, entity UUID, operation
  (`create|update|delete`), a JSON payload snapshot, local revision, creation time, attempt count,
  `next_attempt_at`, last error kind/message, and status (`pending|inFlight|failed|acknowledged`). The
  auto-incrementing `id` is the deterministic order: claims are `ORDER BY id ASC`.
- **`sync_state`** — one row per entity: status, cursor, last successful sync time, last error,
  consecutive failures, and retry deadline.
- **`remote_links`** — unique on `(entity, local_uuid)`, mapping to a remote id with `remote_revision`
  and `base_revision`. The local record never depends on a remote row; a link is bookkeeping that no
  local query reads.
- **`sync_conflicts`** — entity, entity UUID, optional field, local and remote revisions, both payloads
  verbatim, status, and detection/resolution timestamps. Nothing decides a winner in this milestone.
- **`sync_tombstones`** — durable deletion records, unique on `(entity, entity_uuid)`.

**Deletion handling.** Deleting a task, habit, or note is still a physical delete, so no existing query
had to change and no read path can show a deleted row. The same transaction writes a `sync_tombstones`
row first, so what a backend must be told survives the row itself. Session records have no delete path
in the application, so no session tombstone is produced yet.

### Sync architecture

`lib/data/sync/` holds the local foundations:

- `remote_backend.dart` — the `RemoteBackend` seam (`push`, `pull`, `isConfigured`) with request/result
  models. Nothing in `lib/` implements it against a network.
- `sync_models.dart` — `SyncEntity`, `SyncOperationKind`, `SyncOperationStatus`, and `SyncFailureKind`
  (`offline`, `authenticationRequired`, `permissionDenied`, `conflict`, `rateLimited`, `serverError`,
  `backendPaused`, `invalidRequest`), with `SyncFailure.fromHttpStatus` mapping 401/403/409/429/5xx,
  503 separated as *paused*, and a pure exponential `retryDelayFor` helper (1 s doubling to a 5-minute
  cap).
- `sync_store.dart` — `SyncQueue` (enqueue, ordered claim, in-flight marking, transactional
  acknowledgement, failure recording, explicit re-queue), `SyncMetadataStore` (state, links, conflicts,
  tombstones), and `recordLocalDeletion`.
- `sync_engine.dart` — a single-pass `drainOnce()` that pushes queued operations oldest first and stops
  at the first failure, so a later update for a record is never sent while an earlier operation for it
  is unacknowledged.
- `fake_backend.dart` — an in-memory backend with scripted failures, used only by tests.

**Acknowledgement is transactional.** The outbox row is updated and the remote link written inside one
`database.transaction`; if either statement fails, both roll back and the operation stays queued.
Acknowledged rows are marked, never deleted, so delivery evidence cannot be lost to a crash between the
remote call and the local write.

### Decisions and deviations from `docs/MILESTONE_2_PLAN.md`

- **No new dependency.** The plan listed `uuid`; an RFC 4122 v4 generator over `Random.secure()` lives in
  `lib/data/ids.dart` instead, with a format check covered by tests. `pubspec.yaml` is unchanged.
- **Tombstones are a table, not a `deleted_at` column.** The plan sketched soft-delete columns; a
  tombstone table keeps every existing query, backup, and widget test unchanged while still preserving
  what a backend must be told.
- **`uuid` is nullable in SQL** — backfilled, uniquely indexed, and always populated by the client
  default — because adding a `NOT NULL` column without a server default would require rebuilding four
  tables inside an upgrade that is meant to be purely additive.
- **Repositories write tombstones but do not enqueue.** Queue entries are created by the sync layer and
  its tests; wiring every local write into the outbox belongs to 2G, when sync becomes opt-in and can be
  switched off without touching the write path.
- **Backups keep format 1.** `supportedSchemaVersion` moves to 4, each record now carries its `uuid`
  (absent in older files, which mint fresh ones on restore), and restore/reset also clear the sync
  tables, because replacing all local data would otherwise leave queue entries and links pointing at
  rows that no longer exist.

### Verification on Windows

- `dart format lib test integration_test` — no changes.
- `flutter analyze` — `No issues found!`.
- `flutter test` — all **69** tests passed (45 existing plus 24 new).
- `flutter build windows --debug` — succeeded (`build/windows/x64/runner/Debug/flowstate.exe`).
- `flutter test integration_test/app_flow_test.dart -d windows` — both on-device tests passed, so the
  task/focus/restart flow and the habits/notes/insights/settings flow still work against a v4 database.
- New coverage: `test/schema_v4_migration_test.dart` (v3→v4 with every row, relation and preference
  preserved; UUID validity, uniqueness, and stability across reopen; automatic UUIDs on new rows;
  database-level rejection of a duplicate; the v2→v4 chain) and `test/sync_scaffolding_test.dart`
  (outbox ordering, acknowledgement and retention, backoff, tombstones for all three delete paths,
  remote links and revisions, sync state persistence, conflict payload retention, engine ordering,
  stop-on-failure and recovery, and the failure taxonomy).

### Known limitations

- No sync engine runs: no HTTP, no Supabase client, no account, no scheduling, no background work.
  `SyncEngine` is invoked only by tests.
- `RemoteBackend.pull` is declared but unused, and conflicts are a foundation only — payloads are
  retained, with no merge logic and no resolution UI.
- Habit completions and preferences have no UUIDs yet, so their sync identity is deferred.
- Bulk operations (`deleteAll`, backup restore, reset) clear sync bookkeeping instead of producing
  per-row tombstones. That is correct for a replace-everything path, but it means bulk deletion is not
  individually communicable.
- Android, Linux, release builds, installers, and distribution remain unverified; the Android SDK is
  absent from this machine.
