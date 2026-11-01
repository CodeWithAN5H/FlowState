# FlowState — Milestone 2 Plan: Accounts, Friends, Rooms and Synchronization

**Status:** planned, not started. No Milestone 2 code, schema, dependency, or backend exists yet.
**Written:** 2026-11-01, after Milestone 1C was merged and pushed as `3c3673d`.
**Scope of this document:** Milestone 2 only. Focus Lock stays in Milestone 3/4, and release artifacts in Milestone 5.

This file is the single source of truth for Milestone 2. `README.md` and `PROJECT_STATUS.md` summarize and link here instead of repeating it.

## 1. Goal and invariants

**Goal:** add *optional* identity, friends, private study rooms, realtime presence, and background synchronization on top of the finished local application.

**Non-goals for Milestone 2:** Focus Lock, notification delivery, public room discovery, voice chat, a social feed, end-to-end encryption, cheat-proof verification claims, and any release artifact.

These invariants must hold after every phase. A phase that breaks one is not finished:

1. **Local-first, always.** With no network and no account, tasks, habits, notes, the timer, insights, settings, and backup/restore work exactly as they do today. No login gate, no startup network call, no feature removal while signed out.
2. **Optional by construction.** All remote features sit behind one `RemoteBackend` abstraction. When no backend is configured, the UI omits shared sections or labels them "not configured" — it never errors or blocks.
3. **Local database stays the source of truth** for personal data. The remote is a synchronization target, never a read path the UI depends on.
4. **The server decides authorization.** Membership, ownership, invitation validity, and duration eligibility are evaluated server-side; client-supplied user ids, roles, and durations are never trusted.
5. **Local time is not verified time.** Nothing locally recorded is presented as server-verified competitive time.
6. **Sync is idempotent and loses nothing.** Every operation is replayable, and a conflict produces a visible resolution rather than a silent overwrite.

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
- `room_members` — `(room_id, user_id)`, role `owner|member`, `joined_at`, `removed_at`; membership intervals drive verification (§9).
- `room_invites` — `code_hash`, `room_id`, `created_by`, `max_uses`, `uses`, `expires_at`, `revoked_at`.
- `room_messages` — `room_id`, `author_id`, `body` (≤500 chars), `created_at`, `deleted_at` (soft delete).
- `room_sessions` — leader-started schedule: `room_id`, `leader_id`, `mode` (`focus|break`), `starts_at`, `ends_at`. Server timestamps are authoritative.
- `session_reports` — `room_id`, `user_id`, `local_session_uuid` (unique per user, for idempotency), `started_at`, `ended_at`, `client_duration_ms`, `verified_ms`, `verification` (`verified|clamped|local_only`), `received_at_start`, `received_at_end`.
- `session_heartbeats` — optional `(session_report_id, at)` rows used to clamp long sessions.

Reactions are **ephemeral broadcasts**, not a table: no history, no retention burden, no unbounded growth.

## 4. Local schema v4 (additive)

A `schemaVersion` 4 migration adds synchronization bookkeeping without touching existing columns or rows:

- `sync_outbox` — pending operations: entity, local id, operation, payload, revision, attempts, `next_attempt_at`, `last_error`.
- `sync_state` — per-entity cursor and last successful sync time.
- `remote_links` — local id ↔ remote id, `remote_revision`, `base_revision`.
- `conflicts` — retained losing values with timestamps, for the conflict UI and for 30-day diagnostics.
- `uuid` text column (unique) on `tasks`, `habits`, `notes`, `focus_sessions`, backfilled for existing rows; integer primary keys stay internal.

Migration tests must prove v3→v4 preserves every existing row, that UUIDs are stable across reopen, and that a v1/v2 database still reaches v4.

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
- **Invites:** 8–10 character codes stored as SHA-256 hashes, single-use by default, expiring, revocable and regenerable. Redemption is a single RPC that atomically validates expiry/uses, records the attempt, and inserts membership; per-user attempt rate limiting prevents enumeration. Codes identify a room but never list rooms.
- **Ownership:** `transfer_ownership` is owner-only and requires the target to be a current member; `leave_room` refuses while the caller is the owner.
- **Removal:** setting `removed_at` immediately invalidates realtime authorization, and the server broadcasts `membership_revoked` so the removed client drops its channel.
- **Friends:** unique pending pairs, blocked pairs rejected in both directions, and per-user request rate limits (for example 20/day).
- **Messages:** length and per-minute rate limits enforced in the database, self-delete plus owner delete, no edits in Milestone 2.
- Every client-supplied identifier is validated against `auth.uid()` and membership before use.

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
  - Scalar state (task completion, archive flag): the newer server revision wins, and the losing value is recorded in `conflicts` for diagnostics.
- **Failure taxonomy** with distinct UI states: no network, 401 (refresh then sign out), 403 (membership revoked), 409 (conflict), 429 (rate limit), 5xx, and project paused (503). Each is retried or surfaced deliberately — never a silent retry loop.
- **Bounded queues:** outbox pruning after successful sync, with a size cap so an offline device cannot grow without limit.

## 9. Competitive integrity: local, synced, and verified time

- **Class A — local personal time.** Computed on-device, shown on Home and Insights, never uploaded unless sync is enabled, never labelled verified.
- **Class B — synced personal time.** Reported with client duration; the server clamps it to the interval it actually observed and flags `clamped` when the client claims more. Shown in the user's own synced totals.
- **Class C — room/competitive time.** Only sessions the server saw start and end (or heartbeats at ≤60 s), while the user held membership for the whole window. `verified_ms` is the server-observed span capped at the client duration. **Leaderboards aggregate Class C only.**
- Offline room sessions are recorded with `pending_verification`; on sync they qualify only if membership covered the entire claimed window and the duration is plausible (≤4 h), otherwise they stay `local_only`.
- Leaderboard buckets are UTC daily/weekly, displayed in local time with an explicit note; ties break by fewer interruptions. In-app copy states plainly that room rankings count only sessions the server could see and prove nothing about how someone studied.

## 10. Testing strategy and failure scenarios

- **Pure unit tests:** outbox state machine, backoff schedule, revision/conflict decision table, presence expiry, duration clamping, UTC bucket boundaries, invite-code format and hashing.
- **Local database tests:** v3→v4 migration and UUID backfill, tombstone round-trip, stable ids across reopen.
- **Repository contract tests** against a fake backend implementing the same interface: duplicate delivery, out-of-order acknowledgements, 409 conflicts, 429 rate limits, 401 expiry, and simulated project pausing.
- **Backend authorization matrix** (needs the local Supabase stack): for every table, prove a user cannot read or write another user's rows, a non-member cannot read room data, a removed member loses message access, owner-only operations fail for members, expired/reused invites are rejected, and no secret key exists in client configuration.
- **Realtime tests:** two clients see presence, messages, and schedule changes; a third non-member is refused; disconnect produces a leave event; removal drops the channel; a network cut followed by reconnect converges to the REST snapshot.
- **Explicit failure scenarios:** offline cold start, airplane mode mid-session, app kill during sync, duplicate events, backwards clock change, paused project, revoked membership during a focus session, invite brute force, oversized message, rate limiting.
- **On-device:** extend the Windows integration tests with a sign-in, room creation, and two-client presence check against the local stack. Android and Linux remain unverified until hardware is available.
- **Prerequisite:** a Supabase CLI + Docker local stack on this Windows host is unverified. Milestone 2 cannot be honestly verified without either a local stack or a disposable project, so confirm that before starting 2A.

## 11. Dependencies (planned, none added)

- `supabase_flutter` — the one substantive runtime addition (Auth, Realtime, REST).
- `uuid` — small, correct v4 identifiers for sync entities.
- Secure token storage — only if the SDK default store is not app-private on Windows/Android.
- Development-only: Supabase CLI + Docker for the local backend and RLS tests.
- Deliberately **not** added: Riverpod or go_router (current state management and navigation remain adequate), `connectivity_plus` (detect by request failure instead), a charting package (existing charts suffice), and any analytics SDK.

## 12. Implementation order

Each phase is independently shippable, leaves the local app working, and ends with its own tests and documentation.

| Phase | Work | Exit criteria |
|---|---|---|
| **2A** Backend foundation (no client change) | Supabase project schema, RLS, revokes, RPCs for invites/ownership/account deletion; local stack running. | Authorization matrix green; app untouched. |
| **2B** Local schema v4 + sync scaffolding | UUID columns with backfill, outbox/state/conflict tables, sync interfaces plus a fake backend; migration tests. | All existing tests still pass; no user-visible change. |
| **2C** Optional identity | Settings → Account, sign-up/in/out, handle claim, account deletion, lazy token handling, offline-safe states. | Signed-out app identical to today; sign-in flow verified on Windows against the local stack. |
| **2D** Friends | Handle search, requests, accept/decline/cancel, blocks, friend list, rate limits. | Two-account isolation tests pass. |
| **2E** Private rooms and invitations | Create/rename/archive, hashed single-use invites with expiry and regeneration, join/leave, owner controls, transfer, removal. | Full authorization matrix including non-member, removed member, expired code. |
| **2F** Realtime room sessions | Presence, member status, independent sessions, server-anchored group schedules, quick reactions, short messages. | Two-client realtime test on Windows; stale presence and reconnect handled. |
| **2G** Personal sync and conflicts | Opt-in sync, outbox drain, conflict copies, sync status UI, tombstones. | Duplicate/out-of-order/offline tests pass; no silent overwrite demonstrated. |
| **2H** Competitive statistics | Class C verification, heartbeat clamping, UTC buckets, documented eligibility, in-app disclosure. | Leaderboards show verified rows only; local-only sessions never counted. |

**Rationale:** authorization before any client UI (so there is no insecure intermediate state), local schema before sync (so conflicts have somewhere to live), identity before friends, friends before rooms (invites need identity and membership), realtime only after membership authorization is proven, personal sync after the room flow exercises the transport, and competitive statistics last because they depend on verified session data.

## 13. Risks and open questions

- Free-tier terms and limits can change; a paused project interrupts rooms but never local use.
- The key migration from `anon`/`service_role` to publishable/secret keys must be adopted from the first commit.
- Competitive integrity is inherently approximate; the plan avoids any cheat-proof claim.
- Verification remains Windows-only until Linux and Android hardware exist.
- Open decisions for the project owner: whether personal-data sync belongs in Milestone 2 at all or should stay local-forever, which OAuth provider (if any), whether a disposable Supabase project may be created for testing, and the room-chat retention period.
