# FlowState

FlowState is an offline-first productivity and collaborative study app for Windows, Linux, and Android. Development is intentionally incremental. The current Milestone 1B checkpoint has a dark, responsive Home/Tasks/Focus app with local SQLite storage and recoverable focus sessions; native Windows build verification remains blocked by local symlink configuration.

## Current milestone

**Milestone 0 and Milestone 1A are complete. Milestone 1B is in progress; its local-data, recoverable-session, task, and Home implementations have passed source analysis and automated tests, but Windows runtime verification is blocked by missing Developer Mode symlink support.**

Milestone 1A includes:

- A Flutter Material 3 dark UI with a persistent desktop sidebar, timer/status cards, and a vertically scrollable compact layout for narrow/mobile screens.
- A usable stopwatch with start, pause, resume, completed finish, and interrupted/cancel states.
- A separate pure-Dart timer model based on a monotonic `Stopwatch` rather than decrementing ticks.
- Deterministic unit tests for running, pausing, resuming, finishing, cancelling, and idle calls.
- Explicit UI copy that session history is not saved and Focus Lock is not enabled.

Milestone 1A was verified in commit `7405c2a`; its Windows debug app was built and observed running. Milestone 1B now adds local SQLite persistence, schema v2 migrations, session recovery and lifecycle handling, persistent task CRUD, responsive Home/Tasks/Focus navigation, and dashboard statistics derived from stored sessions/tasks. The app remains offline-first and requires no account or backend.

Milestone 1B is **not yet marked complete**: repository/migration/session tests, formatting, and static analysis pass, but native Windows build and runtime verification cannot run until Windows Developer Mode permits Flutter’s plugin symlinks. Habits, notes, insights, settings, notifications, export, authentication, synchronization, rooms, Focus Lock, and release artifacts remain out of scope or later milestones.

## Architecture proposal

Keep a single Flutter/Dart codebase for the three target platforms. Split the app into presentation, domain, local-data, and optional remote-data layers. Personal productivity should not depend on an account or a network.

For local persistence, FlowState uses SQLite through Drift, with a feature-level data layer and versioned migrations. A session stores a wall-clock run anchor plus accumulated paused duration for restart recovery, while the UI timer uses monotonic elapsed measurements during each run. Task and session repositories isolate the UI from persistence. Section navigation is currently simple local state; broader routing/state packages are deferred until needed. No remote backend is required for personal productivity.

### Milestones

- [x] Milestone 0 — inspect workspace/toolchain; assess Focus Lock and zero-cost backend options; record risks and architecture.
- [x] Milestone 1A — responsive shell and tested stopwatch model (Flutter dependencies, analysis, tests, and Windows debug launch verified).
- [ ] Milestone 1B — implementation and automated tests are in place; pending native Windows build/runtime verification after Developer Mode enables symlinks.
- [ ] Milestone 1C — local habits, notes, insights, settings, data export, and offline tests.
- [ ] Milestone 2 — optional identities, friends, private rooms, authorization, realtime sessions and background sync.
- [ ] Milestone 3 — opt-in Chromium website-blocking extension; assess platform-specific native integrations only where users can configure them safely.
- [ ] Milestone 4 — research and, if policy and device testing support it, an opt-in Android Accessibility focus-friction prototype.
- [ ] Milestone 5 — migration, security, accessibility, cross-platform QA, documentation, reproducible release builds and installer/package generation.

No release milestone is complete until Windows installer, Linux package, and Android APK artifacts have actually built; platform-specific install/upgrade behavior must also be tested on the target operating systems/devices. This Windows workspace does not itself prove those tests.

## Verified environment and architecture decisions

### Toolchain used for Milestone 1A

The initial PATH and common-location checks found no Flutter SDK, so I downloaded the official Flutter 3.47.8 stable Windows SDK archive (1,937,300,499 bytes), verified its published MD5 `ca208e3066cce928600bb56b4c4c5011`, and extracted it under the Git-ignored project-local `.tooling/flutter/` directory. No system PATH or global settings were changed. This SDK includes Dart 3.13.7. The Flutter `.bat` launcher hangs from this host's Git Bash, so I invoked the SDK's real Flutter tool snapshot using its bundled Dart executable for checks and Windows launch.

Visual Studio 2022 Community's Native Desktop workload, x64/x86 VC tools, and Windows SDK 10.0.26100.0 are installed. Flutter generated Windows and Android runner scaffolding. Android is scaffolded only: Flutter Doctor reports no Android SDK. No Linux runner was generated on this Windows host.

### Focus Lock risk

Focus Lock is deliberately not coupled to the timer or advertised as enabled. A normal app cannot provide unbreakable cross-platform blocking.

- A Chromium extension can apply user-configured request-blocking rules in compatible Chromium browsers, but cannot block other browsers or desktop applications; users can disable/remove it. Enterprise force-install policy is for administrator-managed devices, not ordinary personal setup.
- On ordinary Android devices, Accessibility is an opt-in, best-effort focus-friction mechanism, not an OS-enforced app lock. Users can revoke permission or stop/uninstall the app; background execution and restart behavior are not guaranteed. Google Play requires an accurate accessibility declaration and prominent disclosure/consent for non-accessibility apps, and review remains a material risk for interference with other apps. If attempted, keep it deterministic, narrowly scoped, transparent, and easy to exit. Device-owner lock-task mode is not appropriate as a consumer-app requirement.
- Report enforcement state separately from timer state; if permission or the extension disappears, record protection as unavailable/degraded rather than implying the timer is protected.

Research references: [Android Accessibility service](https://developer.android.com/guide/topics/ui/accessibility/service), [Google Play Accessibility policy](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en), [Google Play disclosure and consent](https://support.google.com/googleplay/android-developer/answer/11150561?hl=en), [Android background execution limits](https://developer.android.com/about/versions/oreo/background), [Android lock task mode](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode), [Chrome declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest), and [Chrome extension installation](https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions).

### Optional backend assessment

Personal productivity stays local and useful with no backend configured. Gravity Index did not identify an appropriate zero-cost service from its catalog; that is not evidence no such service exists. Supabase is worth evaluating for an *optional* room backend: its current official pricing page lists a $0 Free plan with 500 MB database, 50,000 monthly active users, 5 GB egress, 1 GB file storage, 2 million realtime messages/month, 200 concurrent peak realtime connections, and 500,000 Edge Function invocations. Free projects pause after one week of inactivity and are limited to two active projects. Those terms fit a small initial friends-only trial, subject to change; a paused project would delay rooms, never local tasks/timers. Avoid relying on it until current terms, authentication, row-level security, invite authorization, and Flutter client support have been validated. Never ship service-role secrets in an app.

Source: [Supabase official pricing](https://supabase.com/pricing), [official billing and free-tier quotas](https://supabase.com/docs/guides/platform/billing-on-supabase). This is a documented candidate, not an integrated backend or a promise that the free tier will always suit the project.

## Run and test

The local Flutter SDK is kept in ignored `.tooling/flutter/`. On Windows, enable Developer Mode to permit Flutter to create the native plugin symlinks required by Drift/SQLite, then run from a terminal with `flutter` on PATH:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

In the checked Git Bash host, the Flutter `.bat` shim does not return; the equivalent SDK tool entry point used for the verified commands was:

```sh
.tooling/flutter/bin/cache/dart-sdk/bin/dart.exe \
  --packages=.tooling/flutter/packages/flutter_tools/.dart_tool/package_config.json \
  .tooling/flutter/bin/cache/flutter_tools.snapshot <command>
```

## Milestone 1B verification (current working checkpoint)

Using Flutter 3.47.8/Dart 3.13.7 from ignored `.tooling/flutter/`: `dart format` completed; `flutter analyze` reported no issues; `flutter test` passed all 15 tests (seven stopwatch model/restore tests, seven SQLite repository/session tests, and one schema migration test). Tests verify task CRUD, date/dashboard queries, a real SQLite file close/reopen, session pause/resume, finish/interruption distinction, clock rollback clamping, active-session recovery after closing/reopening the database, and a v1→v2 data-preserving schema migration.

`flutter pub get` succeeded on its latest run. It initially exited 1 after resolving packages because Windows plugin symlink setup requires Developer Mode; a subsequent run succeeded. `flutter build windows --debug` is currently blocked before compilation by `Building with plugins requires symlink support. Please enable Developer Mode`. The settings page was opened but Developer Mode was not changed by the agent. Windows UI/build/runtime, Android, Linux, and release artifacts are **not verified** for this milestone. A first draft of widget smoke tests hung without completing; that test file was removed and is not counted among the passing checks. Use a Windows run after enabling Developer Mode as the last required check before marking 1B complete.

## Build and distribution roadmap

Release artifacts are **not yet generated**. Once the product and its data behavior are implemented and Flutter toolchains exist:

- Windows: `flutter build windows --release`, then produce and test the requested `FlowState-Setup.exe` installer, shortcuts, runtime dependencies, upgrade and uninstall.
- Linux: `flutter build linux --release`, package at least a `.deb` (consider AppImage), and test on a stated supported distribution.
- Android: configure a private release signing key and use `flutter build apk --release --build-name 0.1.0 --build-number 1`; deliver the built APK as `FlowState.apk`. Keep signing material/passwords out of source control and test installation/upgrades on a real compatible device.
- Provide separate source and artifact deliverables, reproducible commands, a practical friends' setup guide, privacy/Focus Lock limitations, and feature status before calling the application complete.

A free GitHub release can be considered only after actual artifacts build; no release has been published.

## Current verification record

Milestone 1A verification is recorded in [PROJECT_STATUS.md](PROJECT_STATUS.md), with commit `7405c2a`. Milestone 1B's current working checkpoint passes `dart format`, `flutter analyze`, and all 15 automated tests. The Windows debug build is blocked before compilation until Developer Mode permits plugin symlinks; 1B remains in progress. No release build, installer, APK, Android device test, or Linux test is claimed.
