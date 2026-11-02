# FlowState — Milestone 2 Plan: Accounts, Friends, Rooms and Synchronization

**Status:** phases 2A (backend foundation) and 2B (local schema v4 with sync scaffolding) are implemented and locally verified; phases 2C–2H are not started. The app still has no Supabase client, dependency, account, or network call, and nothing is deployed.
**Written:** 2026-11-01, after Milestone 1C was merged and pushed as `3c3673d`.
**Revised:** 2026-11-02 — phase 2B implemented as local schema v4 and provider-neutral sync scaffolding; see §16.
**Revised:** 2026-11-02 — 2A and 2B records corrected, dependency notes updated, and the independent 2B review recorded in §17.
**Revised:** 2026-11-02 — phase 2A implemented as SQL migrations, RPCs and a security test suite; see §14.
**Revised:** 2026-11-01 — study-time policy settled for the friends-and-personal stage: sessions recorded offline count as personal study time and towards private friend-group statistics as *self-reported* time, while server observation is recorded as a separate attribute rather than an entry requirement.
**Scope of this document:** Milestone 2 only. Focus Lock stays in Milestone 3/4, and release artifacts in Milestone 5.

This file is the single source of truth for Milestone 2. `README.md` and `PROJECT_STATUS.md` summarize and link here instead of repeating it.

## 1. Goal and invariants

**Goal:** add *optional* identity, friends, private study rooms, realtime presence, and background synchronization on top of the finished local application.

**Non-goals for Milestone 2:** Focus Lock, notification delivery, public room discovery, voice chat, a social feed, end-to-end encryption, cheat-proof verification claims, and any release artifact.

These invariants must hold after every phase. A phase that breaks one is not finished:

1. **Local-first, always.** With no network and no account, tasks, habits, notes, the timer, insights, settings, and backup/restore work exactly as they do today. No login gate, no startup network call, no feature removal while signed out.
2. **Optional by construction.** All remote features sit behind one `RemoteBackend` abstraction. When no backend is configured, the UI omits shared sections or labels them "not configured" — it never errors or blocks.
3. **Local database stays the source of truth** for personal data. The remote is a synchronization target, never a read path the UI depends on.
4. **The server decides authorization.** Membership, ownership, and invitation validity are evaluated server-side; client-supplied user ids and roles are never trusted. Study durations are different: they are accepted as self-reported at this stage (§9).
5. **Recorded time is not observed time.** A session the device recorded is never presented as time the server watched — even after it syncs. Self-reported time may appear in personal and friend-group statistics, and it must be labelled as self-reported wherever it competes with observed time.
6. **Sync is idempotent and loses nothing.** Every operation is replayable, and a conflict produces a visible resolution rather than a silent overwrite.

### Three capabilities that stay separate

These are distinct products with distinct requirements. None of them may become a precondition for another:

1. **Local-first productivity — available to everyone, always.** Tasks, habits, notes, the timer, insights, settings, and backup/restore require no account, no network, and no backend. This is the product, not a degraded mode; it must keep working even if every remote service is unavailable permanently.
2. **Social rooms — require an account and a connection.** Friends, private rooms, invitations, presence, and shared sessions cannot exist without identity and a live backend. Their absence removes those screens only; it never disables the timer, hides local data, or blocks the app behind a login.
3. **Personal cloud sync — optional, deferred until separately approved.** Uploading a user's own tasks, habits, notes, and sessions for cross-device restore is a convenience, not a requirement. It stays off by default (phase 2G), it is not implied by creating an account, and it is not a prerequisite for rooms. If it is never approved, FlowState remains complete for a local-only user and for a signed-in room user.

The practical rule for every phase: a signed-out, offline user must see today's application. A signed-in user may see more; they must never need it.

## 2. Backend evaluation: Supabase

**Verdict:** Supabase is a reasonable *optional* backend under the ₹0 constraint, with real caveats. It is a documented candidate only — nothing is integrated, and no account or project is created by this plan.

### Free-plan facts (as of 2026-11-01; pricing changes often)

| Area | Free-plan limit / behavior |
|---|---|
| Database | 500 MB per project on a 2 GB disk that does **not** autoscale; at 95% disk the database becomes read-only, and a full disk stops Postgres until upgrade. |
| Auth | 50,000 monthly active users included, unlimited total users; anonymous sign-in available. |
| Egress | 5 GB uncached plus 5 GB cached under a shared quota; no overage purchase on Free. |
| Storage | 1 GB, 50 MB max file upload (FlowState needs none for Milestone 2). |
| Realtime | 200 concurrent peak connections, 2M messages/month, 256 KB broadcast payload, ~100 messages/s per project. |
| Projects | 2 active projects maximum. |
| Pausing | Free projects pause after roughly a week of low activity (usage-based, not a strict timer); data is preserved and restorable for about a year, with dashboard notifications before and after. |
| Backups | No automatic backups and no point-in-time recovery on Free — a manual `supabase db dump` is the only export path. |

### Capabilities that matter here

- **PostgreSQL** with a dedicated instance per project, so the schema is ordinary SQL and portable.
- **Row Level Security** is the documented authorization mechanism; requests run as `anon`, `authenticated`, or `service_role`, and `auth.uid()` / `auth.jwt()` are available inside policies.
- **Realtime**: Broadcast (low-latency client-to-client), Presence (shared ephemeral state), and Postgres Changes. Supabase's own docs recommend Broadcast over Postgres Changes for scalability, including trigger-driven `realtime.broadcast_changes()` onto private channels.
- **Auth**: email/password, magic link, OTP, OAuth providers, and anonymous users (which assume the `authenticated` role and carry an `is_anonymous` claim).

### Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Project pausing | Rooms and friends are unavailable until the owner resumes the project; local productivity is unaffected. | Document the one-line resume step; treat "paused" as a distinct offline state in the UI; never claim a keep-alive guarantee (the pause trigger is usage-based and fuzzy). |
| Only 2 active projects | Little room for separate dev/staging/production. | One project per environment, local stack (`supabase start`) for testing, no extra environments. |
| Grants vs policies footgun | New `public` tables may grant all privileges to `anon`/`authenticated`, and adding policies does not revoke grants. | Explicit `revoke all ... from anon, authenticated` plus minimal grants, verified by tests (§10). |
| API key churn | `anon`/`service_role` keys are being retired in favour of publishable/secret keys. | Use the publishable key in the client from day one; the secret key never appears in the app or repo. |
| No backups on Free | Friend/room metadata could be lost. | Owner-run periodic `supabase db dump`, documented in the setup guide; treat room history as reconstructible. |
| Realtime limits | 200 concurrent connections is fine at friends scale but not a public launch. | Do not build for public discovery or large rooms; document the ceiling. |
| Presence has no documented expiry interval | Stale "online" members. | Treat presence as ephemeral, fall back to `profiles.last_seen_at`, expire locally after a short timeout (§7). |
| Free tier can change | A future price or limit change could break rooms. | Portable SQL, repository interfaces, documented dump/restore, and no provider-specific extensions beyond `pgcrypto`. |

**Exit strategy:** all remote access goes through interfaces, the schema lives in plain SQL migrations, and export is a documented `pg_dump`/`supabase db dump` path — so moving to self-hosted Postgres or another provider is a data migration, not a rewrite.

**Alternatives considered:** self-hosted Supabase (₹0 only with existing hardware and an admin burden), Appwrite (smaller SQL/RLS story), Firebase (vendor lock-in, no SQL/RLS). Supabase remains the recommendation specifically because it is plain Postgres with RLS.

## 3. Remote data model (PostgreSQL)

All tables live in `public`, have RLS enabled with minimal grants, use `timestamptz`, and are keyed by UUIDs.

- `profiles` — `id` (= `auth.users.id`), unique lowercase `handle`, `display_name`, `created_at`, `last_seen_at`. No email exposure to other users.
- `friendships` — ordered unique pair (`user_low`, `user_high`), `created_at`. Mutual by definition.
- `friend_requests` — `from_user`, `to_user`, `status` (`pending|accepted|declined|cancelled`), timestamps; unique pending pair.
- `blocks` — `blocker`, `blocked`, `created_at`; enforced symmetrically in policies.
- `rooms` — `id`, `name`, `owner_id`, `invite_policy` (`owner_only|all_members`), `archived_at`.
- `room_members` — `(room_id, user_id)`, role `owner|member`, `joined_at`, `removed_at`; membership intervals are kept so a reported session can be attributed to a room (§9).
- `room_invites` — `code_hash`, `room_id`, `created_by`, `max_uses`, `uses`, `expires_at`, `revoked_at`.
- `room_messages` — `room_id`, `author_id`, `body` (≤500 chars), `created_at`, `deleted_at` (soft delete).
- `room_sessions` — leader-started schedule: `room_id`, `leader_id`, `mode` (`focus|break`), `starts_at`, `ends_at`. Server timestamps are authoritative.
- `session_reports` — `room_id`, `user_id`, `local_session_uuid` (unique per user, for idempotency), `started_at`, `ended_at`, `client_duration_ms` (the device's claim, always present), `server_observed_ms` (nullable — only set when the backend itself saw the session), `observed_start_at` / `observed_end_at` (nullable), `received_at`. Every row is self-reported unless the observed columns are populated; nothing here is inferred or reconstructed.
- `session_heartbeats` — optional `(session_report_id, at)` rows recorded while a session runs online. They populate the observed columns for that session and are not used to cap, reject, or repair anything.

Reactions are **ephemeral broadcasts**, not a table: no history, no retention burden, no unbounded growth.

Sync state is **local bookkeeping, not a remote column**: a row arriving at the backend is simply a delivered report, and delivery says nothing about whether the server observed the session.

## 4. Local schema v4 (additive)

**Implemented in 2B; the record is in §16.** A `schemaVersion` 4 migration adds synchronization bookkeeping without touching existing columns or rows:

- `sync_outbox` — pending operations: unique `operation_id`, entity, entity UUID, operation (`create|update|delete`), JSON payload snapshot, local revision, `created_at`, `attempt_count`, `next_attempt_at`, `last_error_kind`/`last_error_message`, and `status` (`pending|inFlight|failed|acknowledged`). Claim order is the auto-incrementing id, so replay is deterministic.
- `sync_state` — one row per entity: status, cursor, last successful sync time, last error, consecutive failures, and retry deadline.
- `remote_links` — unique on `(entity, local_uuid)`, mapping to a remote id with `remote_revision` and `base_revision`. Bookkeeping only: no local record depends on a remote one.
- `sync_conflicts` — retained local and remote payloads, revisions, an optional field, status and timestamps. Nothing resolves automatically in 2B.
- `sync_tombstones` — durable deletion records, unique on `(entity, entity_uuid)`, written in the same transaction as a delete so the deletion stays communicable after the row is gone.
- `uuid` text column on `tasks`, `habits`, `notes`, `focus_sessions`, unique-indexed and backfilled for existing rows; integer primary keys stay internal.

Migration tests prove v3→v4 preserves every existing row and relation, that UUIDs are stable across reopen, and that a v1/v2 database still reaches v4.

## 5. Identity and authentication

- **Modes:** `LocalOnly` (default, today's behavior) and `SignedIn`. Sign-in is reachable only from Settings → Account and from a shared-feature prompt.
- **Methods:** email + password with verification, plus at most one OAuth provider. **No anonymous accounts** in Milestone 2 — they add cleanup and rate-limit burden, and rooms need durable identity anyway. This is a recorded decision, not an oversight.
- **Tokens:** session handling via the SDK; confirm the platform default store is app-private before shipping, and add a secure-storage dependency only if it is not. Token values never enter logs or the repo.
- **Lazy auth:** no token refresh or profile fetch at startup. A signed-in user starting offline sees the local app and a quiet "offline" indicator; an expired refresh token signs out with an explanation and keeps all local data.
- **Account deletion:** a server RPC removes the profile and memberships and anonymizes authored messages ("deleted user"), plus local sign-out. Required for privacy.
- **Handles:** unique, lowercase, 3–20 characters, changeable with a cooldown; display name separate from handle.

## 6. Authorization, RLS and abuse controls

- RLS enabled on every table, preceded by `revoke all` on `anon`/`authenticated`, followed by explicit grants. A table without a policy is unreadable rather than accidentally public.
- Membership helpers (`is_room_member`, `is_room_owner`) as `security definer` functions with a pinned `search_path`, used consistently by policies.
- The client holds only the publishable key. Hashing invite codes, aggregating leaderboards, and destroying accounts happen in SQL functions or triggers, never in client code.
- **Invites:** 128-bit codes (16 CSPRNG bytes rendered as 32 lowercase hex characters) stored only as SHA-256 hashes, single-use by default, expiring, revocable and regenerable, with a cap on active codes per room. Redemption is a single RPC that atomically validates expiry/uses, records the attempt, and inserts membership; per-user attempt rate limiting prevents enumeration. Codes identify a room but never list rooms.
- **Ownership:** `transfer_ownership` is owner-only and requires the target to be a current member; `leave_room` refuses while the caller is the owner.
- **Removal:** setting `removed_at` immediately invalidates realtime authorization, and the server broadcasts `membership_revoked` so the removed client drops its channel.
- **Friends:** unique pending pairs, blocked pairs rejected in both directions, and per-user request rate limits (for example 20/day).
- **Messages:** length and per-minute rate limits enforced in the database, self-delete plus owner delete, no edits in Milestone 2.
- Every client-supplied identifier is validated against `auth.uid()` and membership before use. Reported durations are the one deliberately trusted input, and are stored as claims rather than facts (§9).

## 7. Realtime design

- **Channels:** one private channel per room, authorized by a Realtime Authorization policy that checks membership at join time.
- **Presence:** keyed by user id, carrying `{status, mode, session_started_at}`. Countdowns are computed from server-anchored timestamps plus a measured clock offset, never from local clocks alone.
- **State changes** (membership, room rename, new message) are pushed by database triggers via `realtime.broadcast_changes()` onto the room channel — Broadcast rather than Postgres Changes, per Supabase's current guidance.
- **Presence is ephemeral.** "Online" is never a database truth; `profiles.last_seen_at` is updated on connect/disconnect at most once per minute and is the durable fallback. A member with no leave event is shown offline after a short local timeout (~45–60 s).
- **Reconnect:** exponential backoff with jitter (1 s → 30 s cap), resubscribe, then refetch a REST snapshot. Every event carries an `event_id`; recent ids are de-duplicated and all state updates are idempotent set-by-id operations rather than increments.
- **No modal interruptions:** connection state is a quiet inline indicator; the local timer never pauses because the socket dropped.

## 8. Synchronization and conflict handling

- **Opt-in personal sync** (default off) plus automatic sync of room membership and messages while signed in.
- **Outbox pattern:** each local write enqueues an operation; a single worker drains it in order, marks entries done only after server acknowledgement, and backs off on failure. Crash-safe because nothing is deleted before acknowledgement.
- **Idempotency:** server upserts keyed on `(user_id, entity_uuid)`; deletes are tombstones so a replayed delete cannot resurrect data.
- **Revisions, not clocks:** the server keeps a monotonically increasing `revision` per row. Updates must carry the matching `base_revision`; a mismatch returns the current server row as a conflict, so clock skew cannot decide who wins.
- **Conflict policy:**
  - Long-form text (note body, habit details, room name): keep the local edit and create a visible "Conflicted copy" duplicate containing the remote version. The user resolves by deleting one; nothing is overwritten silently.
  - Scalar state (task completion, archive flag): the newer server revision wins, and the losing value is recorded in `sync_conflicts` for diagnostics.
- **Failure taxonomy** with distinct UI states: no network, 401 (refresh then sign out), 403 (membership revoked), 409 (conflict), 429 (rate limit), 5xx, and project paused (503). Each is retried or surfaced deliberately — never a silent retry loop.
- **Bounded queues:** outbox pruning after successful sync, with a size cap so an offline device cannot grow without limit.

## 9. Study time: recorded, observed, and synced

FlowState is being built for personal use and a private group of friends. At this stage the goal is a trustworthy personal record and an honest shared view among people who already trust each other — not tamper-proof competition. The policy is deliberately simple, and the data model keeps enough structure for stricter rules later.

### 9.1 Personal study time

- Sessions recorded on the device count towards personal study statistics and goals, whether they happened online or completely offline.
- An offline session is saved locally exactly like an online one and reaches the backend when connectivity returns.
- Personal totals mix both sources freely. The interface may show a quiet breakdown, but nothing is withheld, capped, or queued pending confirmation.

### 9.2 Private friend-group rooms

- A session recorded offline may count towards room statistics and friend-group leaderboards.
- That time is **self-reported**: it is the device's account of what happened, delivered later. It is counted and displayed, and it is labelled as self-reported wherever it sits alongside server-observed time.
- No anti-cheat, no plausibility caps, no reconciliation heuristics, and no hold-back queue at this stage. Membership validity and room scoping are still enforced server-side; the duration itself is taken at face value.
- Server-observed sessions are still recorded as such, because the distinction is cheap to keep now and expensive to reconstruct later.

### 9.3 Future commercial verification (deferred)

If FlowState becomes a commercial product with verified competitive rankings, that is a separate feature with its own policy. Nothing in Milestone 2 promises it, and no Milestone 2 code anticipates it beyond the attribution fields below. The model keeps the distinction because every session already records whether the server observed it, so introducing a stricter mode later is a policy and query change rather than a schema rebuild. The exact commercial policy stays deferred (§9.5).

### 9.4 Three independent attributes

These are unrelated properties, and conflating any two of them is exactly how "synced" gets mistaken for "verified":

| Attribute | Meaning | Where it lives |
|---|---|---|
| `local_recorded` | The device recorded the session. True for every session this app produces. | Local `focus_sessions`. |
| `server_observed` | The backend itself saw the session start/end or received heartbeats during it. | Remote `session_reports.server_observed_ms` and `observed_*` columns; absent for offline sessions. |
| `sync_status` | Whether the local row has been delivered to the backend (`pending`, `synced`, `failed`). | Local `sync_outbox` / `sync_state` — bookkeeping, never a claim about truth. |

Consequences to state plainly:

- A session can be fully synced and **not** server-observed. That is the ordinary offline case, and it is acceptable for personal and friend-group use.
- Syncing uploads a claim. It does not prove the person studied during that period.
- The two attributes are read independently: a synced offline session is `local_recorded = true`, `server_observed = false`, `sync_status = synced`.
- Display rules: personal totals may combine both with a breakdown; friend-group leaderboards mark self-reported entries; nothing anywhere renders self-reported time as "verified".

### 9.5 Deferred: future commercial verification options (discussion only, none approved)

**Status: DEFERRED.** Recorded so the option space is not lost, not to make a choice. Nothing here is approved, scheduled, prototyped, or partially implemented, and no Milestone 2 code may depend on it.

- **Verified-only rankings.** Rank exclusively on server-observed sessions and exclude self-reported time from the commercial leaderboard, while personal and friend-group views keep counting it.
- **Two-tier boards.** Show a verified board beside a self-reported board, clearly separated, so nobody has to guess which one they are looking at.
- **Weighted or gradual promotion.** Give self-reported time partial standing, or promote it once a session has some server-observed overlap — only if a future policy can explain and defend the rule.
- **Peer or room-leader attestation.** Considered and set aside for now: it reads as evidence but is collusion-prone between friends, so it produces a weaker signal than server observation for more complexity.
- **Not proposed at any stage:** silently treating self-reported time as verified. The labelling rule in §9.4 exists to prevent exactly that.

The choice among these depends on a commercial decision that has not been made, and any option would need its own tests and disclosure before shipping.

## 10. Testing strategy and failure scenarios

- **Pure unit tests:** outbox state machine, backoff schedule, revision/conflict decision table, presence expiry, attribution mapping across all `local_recorded` / `server_observed` / `sync_status` combinations, UTC bucket boundaries, invite-code format and hashing.
- **Local database tests:** v3→v4 migration and UUID backfill, tombstone round-trip, stable ids across reopen.
- **Repository contract tests** against a fake backend implementing the same interface: duplicate delivery, out-of-order acknowledgements, 409 conflicts, 429 rate limits, 401 expiry, and simulated project pausing.
- **Backend authorization matrix:** for every table, prove a user cannot read or write another user's rows, a non-member cannot read room data, a removed member loses message access, owner-only operations fail for members, expired/reused invites are rejected, and no secret key exists in client configuration. It runs today against the PGlite harness (§14) and must be re-run against a real Supabase stack once one exists.
- **Realtime tests:** two clients see presence, messages, and schedule changes; a third non-member is refused; disconnect produces a leave event; removal drops the channel; a network cut followed by reconnect converges to the REST snapshot.
- **Attribution tests:** an offline session that later syncs stays `server_observed = false` and still appears in friend-group totals, labelled self-reported; `sync_status = synced` never sets or implies observation; a session with heartbeats reports an observed duration independent of the client's claim; no code path caps, rejects, or upgrades a duration.
- **Explicit failure scenarios:** offline cold start, airplane mode mid-session, app kill during sync, duplicate events, backwards clock change, paused project, revoked membership during a focus session, invite brute force, oversized message, rate limiting.
- **On-device:** extend the Windows integration tests with a sign-in, room creation, and two-client presence check against the local stack. Android and Linux remain unverified until hardware is available.
- **Platform integration prerequisite (not yet met):** phase 2A has been executed against the PGlite PostgreSQL harness (§14). That is real PostgreSQL — roles, RLS, grants, constraints and `SECURITY DEFINER` semantics are genuinely exercised — but it substitutes a stub `auth` schema, so GoTrue sign-in, PostgREST, Realtime authorization, the publishable-key client path and project pausing are **not** verified. A real Supabase stack on this host remains unverified; Docker and the Supabase CLI are not installed, and neither was tested here. Confirm a local stack or a disposable project, and exercise those surfaces against it, before claiming any auth, API or realtime capability as verified — starting with identity in 2C and continuing through 2F.

## 11. Dependencies (planned, none added)

- `supabase_flutter` — the one substantive runtime addition (Auth, Realtime, REST).
- `uuid` — **deliberately not added.** Phase 2B generates RFC 4122 version 4 identifiers in `lib/data/ids.dart` from `Random.secure()`, with a format check, and the v4 migration backfill uses the same shape in SQL. No package was added. Revisit only if a later phase needs a generator feature the local helper does not provide.
- Secure token storage — only if the SDK default store is not app-private on Windows/Android.
- Development-only: Supabase CLI + Docker for the local backend and RLS tests.
- Deliberately **not** added: Riverpod or go_router (current state management and navigation remain adequate), `connectivity_plus` (detect by request failure instead), a charting package (existing charts suffice), and any analytics SDK.

## 12. Implementation order

Each phase is independently shippable, leaves the local app working, and ends with its own tests and documentation.

| Phase | Work | Exit criteria |
|---|---|---|
| **2A** Backend foundation (no client change) — **implemented 2026-11-02** | Supabase schema, RLS, revokes, and RPCs for invites and ownership in `supabase/migrations`. Deleting a profile works and anonymises authored messages; the privileged client entry point stays with identity in 2C. | Authorization matrix green in the local Postgres harness (§14); app untouched. A real Supabase stack remains unverified on this host. |
| **2B** Local schema v4 + sync scaffolding — **implemented 2026-11-02** | UUID columns with backfill, outbox/state/conflict/tombstone tables, sync interfaces plus a fake backend; migration and scaffolding tests. | All existing tests still pass (69 in total); no user-visible change. |
| **2C** Optional identity | Settings → Account, sign-up/in/out, handle claim, the account-deletion entry point behind the existing database capability, lazy token handling, offline-safe states. | Signed-out app identical to today; sign-in flow verified on Windows against the local stack. |
| **2D** Friends | Handle search, requests, accept/decline/cancel, blocks, friend list, rate limits. | Two-account isolation tests pass. |
| **2E** Private rooms and invitations | Create/rename/archive, hashed single-use invites with expiry and regeneration, join/leave, owner controls, transfer, removal. | Full authorization matrix including non-member, removed member, expired code. |
| **2F** Realtime room sessions | Presence, member status, independent sessions, server-anchored group schedules, quick reactions, short messages. | Two-client realtime test on Windows; stale presence and reconnect handled. |
| **2G** Personal sync and conflicts | Opt-in sync, outbox drain, conflict copies, sync status UI, tombstones. | Duplicate/out-of-order/offline tests pass; no silent overwrite demonstrated; a synced offline session still reports as not server-observed. |
| **2H** Study-time attribution and friend-group statistics | Attribution fields populated honestly, labelled self-reported vs observed totals, UTC buckets, disclosure copy in the interface. | Offline and self-reported sessions appear in friend-group statistics and are labelled; no anti-cheat, cap, or reconciliation logic exists. |

**Rationale:** authorization before any client UI (so there is no insecure intermediate state), local schema before sync (so conflicts have somewhere to live), identity before friends, friends before rooms (invites need identity and membership), realtime only after membership authorization is proven, personal sync after the room flow exercises the transport, and attribution-based statistics last because they read fields the earlier phases populate.

## 13. Risks and open questions

- Free-tier terms and limits can change; a paused project interrupts rooms but never local use.
- The key migration from `anon`/`service_role` to publishable/secret keys must be adopted from the first commit.
- Friend-group statistics are self-reported by design at this stage. Nothing in the app should imply otherwise, and no anti-cheat claim is made.
- The distinction between self-reported and server-observed time must survive future refactors; if it is collapsed, commercial verification becomes much harder to add later.
- Verification remains Windows-only until Linux and Android hardware exist.
- **Deferred:** the commercial verification policy for competitive rankings, and whether self-reported time keeps any standing in it (§9.5).
- Personal cloud sync is optional and deferred until separately approved: off by default, never implied by creating an account, and never a requirement for local use or for rooms.
- Open decisions for the project owner: whether personal cloud sync is approved at all (or stays local-only forever), which OAuth provider (if any), whether a disposable Supabase project may be created for testing, and the room-chat retention period.

## 14. Milestone 2A implementation record (2026-11-02)

Phase 2A is complete as backend SQL only. `pubspec.yaml`, `lib/`, `test/`, and the local SQLite schema
are untouched, and nothing is deployed.

**Delivered.** Nine additive migrations in `supabase/migrations/` create `profiles`, `friendships`,
`friend_requests`, `blocks`, `rooms`, `room_members`, `room_invites`, `room_messages`,
`room_sessions`, `session_reports`, `session_heartbeats`, and `invite_attempts`. Every table has RLS
enabled and is closed by default; access is granted per table and often per column. Membership,
ownership, invitation, friendship, and message rules are enforced by `SECURITY DEFINER` functions
with a pinned empty `search_path`, each deriving the caller from `auth.uid()`. The ninth migration
adds a defensive default-privilege rule, so a table created in `public` later starts unreadable by
`anon` and `authenticated` instead of exposed.

**Decisions taken during implementation.**

- `room_sessions` (the leader-started group schedule) is the only schedule entity. The phase brief's
  `room_schedules` and `room_sessions` are the same thing; a separate running-instance table was not
  invented.
- Reporting a session requires a **live** membership at upload time. This is an authorization rule,
  not a duration check: a session recorded offline for a room the user still belongs to uploads
  normally, and one for a room they have left is refused while the local record is untouched.
- `invite_attempts` exists because rate limiting needs a durable record of failures, and failures are
  returned as outcomes rather than exceptions so the attempt survives the rejection.
- Account deletion works at the database level and was hardened here rather than deferred:
  `room_messages.author_id` is nullable with `on delete set null`, and the message-immutability
  trigger now permits exactly that anonymising change (author cleared, body and room unchanged)
  while still refusing reassignment, so deleting a profile no longer fails. A structural test
  deletes an author and asserts the message survives with no author. Phase 2C still owns the
  client-facing path — an RPC acting on the caller's own identity plus sign-out — because removing
  an `auth.users` row needs a privileged key that must never ship in the application.
- Invite codes are 128 bits: 16 bytes from `extensions.gen_random_bytes(16)` rendered as 32 hex
  characters, stored only as a SHA-256 digest, and returned in plaintext exactly once. `pgcrypto` is
  the one extension the schema depends on, which §2 already allows, and a migration-time check fails
  fast when it is missing.

**Platform independence.** FlowState targets Windows, Android, and Linux from a single Flutter/Dart
codebase. This backend sits behind an HTTP boundary and is platform-independent: all three
clients reach it identically, and none of them needs it. Tasks, habits, notes, the timer,
insights, settings, and backup/restore stay local on every platform, signed in or out, online
or offline.

**Verification and its limits.** Docker and the Supabase CLI are unavailable on this host, so the
migrations and 46 security cases were executed against PGlite (PostgreSQL 18 compiled to WebAssembly)
through `supabase/tests/harness`, with a stub `auth` schema whose `auth.uid()` reads the same
`request.jwt.claims` setting Supabase uses. The SQL, roles, RLS, grants, constraints, triggers, and
definer semantics are genuine PostgreSQL; the substitution is the auth layer. This does **not**
verify PostgREST, GoTrue sign-in, realtime authorization, or project pausing, which still require a
real local stack or a disposable project.

## 15. Platform independence and the Focus Lock contract

**Targets.** Windows, Android, and Linux, from one Flutter/Dart codebase. The backend is
platform-independent SQL behind an HTTP boundary, so each client reaches it the same way, and no
client depends on it: tasks, habits, notes, the timer, insights, settings, and personal statistics
work signed out and offline on all three platforms, with the backend absent permanently if need be
(§1). Supabase is an optional remote service, never the foundation of personal productivity.

**Focus Lock (future work; not part of Milestone 2).** These requirements bind whichever phase
implements it. Nothing below is implemented, and no enforcement code, permission, schema, or
interface exists in the repository today.

- The user explicitly selects which applications to block. Nothing is blocked without that choice.
- Only the selected applications are targeted.
- Other applications remain usable; the whole device or computer is never locked.
- Windows, Linux, and Android may each need a different enforcement mechanism, and one platform's
  mechanism never implies another's.
- The application must never claim blocking is active when enforcement is unavailable — permission
  revoked, extension removed, service stopped, or platform unsupported. Enforcement state is
  reported separately from timer state, and the interface says "unavailable" or "degraded" rather
  than implying protection.

Phase 2A adds no Focus Lock table, function, column, or UI.

## 16. Milestone 2B implementation record (2026-11-02)

Phase 2B is complete as local schema plus local scaffolding. There is no Supabase client, no HTTP call,
no account, and no login UI; `pubspec.yaml` is unchanged and the application behaves exactly as it did
in Milestone 1C.

**Delivered.** Schema v4 with stable UUIDs on tasks, habits, notes, and focus sessions (backfilled in
SQL during the upgrade, unique-indexed, and minted automatically for new rows); `sync_outbox`,
`sync_state`, `remote_links`, `sync_conflicts`, and `sync_tombstones`; durable tombstones written
transactionally by the task, habit, and note delete paths; and — in `lib/data/sync/` — the
provider-neutral `RemoteBackend` seam, the failure taxonomy, retry backoff, an ordered queue with
transactional acknowledgement, a single-pass `SyncEngine`, and an in-memory fake backend used only by
tests.

**Publication.** Committed as `d595440f9b17fa33071090d0a55fcc5633e68a00` — `Milestone 2B: add local
sync scaffolding`, parent `1a648ca` — and published to GitHub on 2026-11-02 with a normal, non-force
push (`1a648ca..d595440`). Local `main` and `origin/main` were verified identical at that hash after
the push, and the working tree had no tracked modifications. The commit was reviewed independently,
read-only; that review is recorded in §17.

**Decisions taken during implementation.**

- UUIDs are generated in `lib/data/ids.dart` (RFC 4122 v4 over `Random.secure()`, with a format check)
  instead of adding the planned `uuid` dependency. The repository gains no new package.
- Deletions use a tombstone table rather than `deleted_at` columns, so every existing query, backup,
  and widget test is unchanged while the deletion itself stays communicable. Session records have no
  delete path in the application, so no session tombstone is produced yet.
- The `uuid` columns are nullable in SQL — backfilled, uniquely indexed, and always populated by a
  client default — because adding a `NOT NULL` column without a server default would force a rebuild
  of four tables inside an upgrade that is meant to be purely additive.
- Repositories record tombstones but do not enqueue operations. Queue entries are created by the sync
  layer, and wiring every local write into the outbox belongs to 2G, when sync becomes opt-in and can
  be switched off without touching the write path.
- Backup format 1 is preserved: `supportedSchemaVersion` becomes 4, each record now carries its uuid
  (older files mint new ones on restore), and restore/reset clear the sync tables because they replace
  the whole local dataset.

**Failure taxonomy.** `SyncFailureKind` distinguishes `offline`, `authenticationRequired` (401),
`permissionDenied` (403), `conflict` (409), `rateLimited` (429), `serverError` (5xx), `backendPaused`
(503), and `invalidRequest`. Retryability is a property of the kind, and the queue expresses it through
`next_attempt_at`: a non-retryable failure gets no deadline and waits for an explicit re-queue instead
of spinning.

**Verification and its limits.** `dart format` clean, `flutter analyze` clean, `flutter test` 69
passing (45 existing, 24 new), `flutter build windows --debug` succeeded, and both Windows integration
tests passed. Android and Linux remain unverified. Nothing is scheduled or networked: `SyncEngine` is
invoked only by tests, and `RemoteBackend.pull` and conflict resolution remain foundations rather than
features.

## 17. Independent Milestone 2B review record (2026-11-02)

Commit `d595440f9b17fa33071090d0a55fcc5633e68a00` was reviewed independently and **read-only**: no file
was modified, no test was re-run, and nothing was committed. **No CRITICAL finding was reported, no
current data-loss or corruption path was found inside the implemented 2B scope, and no finding has been
fixed.** Everything below is recorded as a future synchronization requirement, not as a resolved issue:
2B remains complete and published (§16), and these items bind the phase that activates sync.

### HIGH — prerequisites before real sync activation in 2G

- **H1 — stale in-flight operations are never reclaimed** (`SyncQueue.pending`, `markInFlight`,
  `SyncEngine.drainOnce`). An operation marked `inFlight` is excluded from every later claim and there is
  no timestamp to detect staleness, so an interruption between the claim and the acknowledgement strands
  it permanently — while later operations for the same record stay claimable and can overtake it.
- **H2 — ordering is not preserved after a non-retryable failure** (`SyncQueue.pending`). A 401, 403, 409
  or malformed operation receives no `next_attempt_at`, which stops that row from being claimed but
  leaves following operations for the same record claimable, so an update can be sent for a create that
  was never delivered.
- **H3 — deletions are not enqueued** (`recordLocalDeletion`). A tombstone records that a record was
  deleted, but no outbox operation is created, so the deletion can never be communicated. The tombstone
  and the delete operation must be written atomically when sync writes are implemented.
- **H4 — restore and reset discard tombstones and remote links** (`BackupService.restore`,
  `resetAllData`, `_clearLocalData`). Replacing the dataset while remote state exists loses pending
  deletions and remote identity, so a restored row can reappear from the backend or be pushed as a new
  create for an identifier the server already knows. An explicit policy is required once synchronization
  exists.

### MEDIUM

- **M1** The v4 upgrade may not be safely repeatable if it is interrupted between a schema change and the
  version update: `addColumn` is unconditional, so a partial run can fail on the next launch with a
  duplicate column.
- **M2** `SyncQueue.acknowledge()` returns before writing a remote link when the operation kind or entity
  cannot be parsed, leaving the outbox row acknowledged with no recorded remote identity.
- **M3** `markInFlight` is not a conditional claim, so two overlapping drains can deliver the same
  operation twice.
- **M4** `SyncEngine.drainOnce` catches `SyncFailure` only; an unexpected exception escapes after the
  claim and strands the operation, compounding H1.
- **M5** Restoring a pre-v4 backup with several rows per table, where a UUID has to be minted per row,
  has no dedicated test.
- **M6** `NotesRepository.deleteAll` and `HabitsRepository.deleteAll` delete rows without tombstones.
  Neither is called by the interface today.
- **M7** Unchecking a habit day deletes a completion without a completion-level tombstone, so that undo
  cannot be synchronized; habit completions carry no identifier of their own.

### LOW

- Retry-backoff prose says the delay is capped at five minutes, but the exponent clamp makes 256 seconds
  the actual maximum.
- A drain with no configured backend reports offline without recording that state, so `sync_state` can
  still read `idle`.
- `pendingCount` and `drainOnce` apply limits without indicating that more work remains.
- A remote link is left behind after a deletion is acknowledged.
- The duplicate-UUID test asserts `throwsA(anything)`, which would also pass on an unrelated error
  instead of specifically a unique-constraint failure.
- Test coverage gaps: the unique index on a migrated database, UUID survival through export and restore,
  in-flight recovery, ordering after a non-retryable failure, and multi-row legacy restore.
- `test/database_migration_test.dart` still describes the upgrade as creating "v3 tables".
- `sync_state.status` is free-form text rather than a typed status, and several scaffolding members
  (`SyncFailureKind.fromName`, `httpStatus`, `SyncQueue.byId`, `SyncEngine.database`) are unused.
- `sync_tombstones` and `sync_conflicts` have no secondary indexes; irrelevant at current scale.
- The conflict table is named `sync_conflicts` rather than the earlier `conflicts` terminology; §8 now
  refers to the implemented name.

### 2B limitations versus 2G requirements

The present limits of 2B are intentional and unchanged: nothing runs the queue, no HTTP or Supabase
client exists, `RemoteBackend.pull` is a declaration rather than a feature, conflict payloads are kept
but never merged, and no interface reads sync state. The findings above are **requirements for 2G**,
where sync is activated: H1–H4 must be addressed, and M1–M7 either addressed or consciously accepted,
before personal sync is enabled. None of them is a reason to reopen or block the published 2B commit,
and none is claimed as fixed.
