# FlowState

FlowState is an offline-first productivity and collaborative study app for Windows, Linux, and Android. Development is intentionally incremental. Milestone 1B delivers a dark, responsive Home/Tasks/Focus app with local SQLite storage, persistent tasks, recoverable focus sessions, and dashboard statistics computed from saved records; it was built and exercised on Windows.

## Current milestone

**Milestones 0, 1A, and 1B are complete. Milestone 1B's persistence, task, session-recovery, and Home-dashboard behavior was verified by automated tests plus an on-device integration test and manual Windows runs.**

Milestone 1A includes:

- A Flutter Material 3 dark UI with a persistent desktop sidebar, timer/status cards, and a vertically scrollable compact layout for narrow/mobile screens.
- A usable stopwatch with start, pause, resume, completed finish, and interrupted/cancel states.
- A separate pure-Dart timer model based on a monotonic `Stopwatch` rather than decrementing ticks.
- Deterministic unit tests for running, pausing, resuming, finishing, cancelling, and idle calls.
- Explicit UI copy that session history is not saved and Focus Lock is not enabled.

Milestone 1A was verified in commit `7405c2a`; its Windows debug app was built and observed running. Milestone 1B adds local SQLite persistence, schema v2 migrations, session recovery and lifecycle handling, persistent task CRUD, responsive Home/Tasks/Focus navigation, and dashboard statistics derived from stored sessions/tasks. The app remains offline-first and requires no account or backend.

Milestone 1B is complete and verified on Windows: the debug app builds, starts into the Home dashboard, and the on-device integration test exercises task creation/completion, a start–pause–resume–finish focus session, dashboard statistics, and persistence across a restart against the same database file. Habits, notes, insights, settings, notifications, export, authentication, synchronization, rooms, Focus Lock, and release artifacts remain out of scope or later milestones.

## Architecture proposal

Keep a single Flutter/Dart codebase for the three target platforms. Split the app into presentation, domain, local-data, and optional remote-data layers. Personal productivity should not depend on an account or a network.

For local persistence, FlowState uses SQLite through Drift, with a feature-level data layer and versioned migrations. A session stores a wall-clock run anchor plus accumulated paused duration for restart recovery, while the UI timer uses monotonic elapsed measurements during each run. Task and session repositories isolate the UI from persistence. Section navigation is currently simple local state; broader routing/state packages are deferred until needed. No remote backend is required for personal productivity.

### Milestones

- [x] Milestone 0 — inspect workspace/toolchain; assess Focus Lock and zero-cost backend options; record risks and architecture.
- [x] Milestone 1A — responsive shell and tested stopwatch model (Flutter dependencies, analysis, tests, and Windows debug launch verified).
- [x] Milestone 1B — local SQLite with migrations, recoverable sessions, persistent task CRUD, saved-data Home dashboard, and timer integration; verified by 16 automated tests and a Windows on-device integration test.
- [ ] Milestone 1C — local habits, notes, insights, settings, data export, and offline tests.
- [ ] Milestone 2 — optional identities, friends, private rooms, authorization, realtime sessions and background sync.
- [ ] Milestone 3 — opt-in Chromium website-blocking extension; assess platform-specific native integrations only where users can configure them safely.
- [ ] Milestone 4 — research and, if policy and device testing support it, an opt-in Android Accessibility focus-friction prototype.
- [ ] Milestone 5 — migration, security, accessibility, cross-platform QA, documentation, reproducible release builds and installer/package generation.

No release milestone is complete until Windows installer, Linux package, and Android APK artifacts have actually built; platform-specific install/upgrade behavior must also be tested on the target operating systems/devices. This Windows workspace does not itself prove those tests.

## Verified environment and architecture decisions

### Toolchain used for Milestone 1A

The initial PATH and common-location checks found no Flutter SDK, so I downloaded the official Flutter 3.47.8 stable Windows SDK archive (1,937,300,499 bytes), verified its published MD5 `ca208e3066cce928600bb56b4c4c5011`, and extracted it under the Git-ignored project-local `.tooling/flutter/` directory. No system PATH or global settings were changed. This SDK includes Dart 3.13.7. Commands were run as `.tooling/flutter/bin/flutter <command>` and `.tooling/flutter/bin/dart <command>` from Git Bash.

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

The local Flutter SDK is kept in ignored `.tooling/flutter/`. On Windows, Developer Mode must be enabled so Flutter can create the native plugin symlinks used by Drift/SQLite; it is enabled on this machine. Then run from a terminal with `flutter` on PATH:

```sh
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
flutter run -d windows
flutter test integration_test/app_flow_test.dart -d windows
```

The app stores its SQLite file at `%APPDATA%\com.example\flowstate\flowstate.sqlite`. It is deliberately not placed in `Documents`: that folder is protected by Windows Controlled Folder Access by default, which blocks SQLite from creating the file (`SqliteException(14)`). Do not delete this file if you want to keep your tasks and sessions.

If the SDK is not on PATH, use the same commands with the project-local path, for example `.tooling/flutter/bin/flutter test`. The integration test needs a Windows desktop target and must be run with `-d windows`.

## Milestone 1B verification

Using Flutter 3.47.8/Dart 3.13.7 from ignored `.tooling/flutter/`, with Windows Developer Mode enabled and Visual Studio 2022's C++ desktop workload present:

- `flutter pub get` succeeded.
- `dart format` reported no changes.
- `flutter analyze` reported **No issues found!**
- `flutter test` passed **all 16 tests**: seven stopwatch model/restore tests, seven SQLite repository/session tests, one v1→v2 migration test, and one widget test for task-dialog lifecycle and task creation. They cover task CRUD, due/completed date queries, SQLite file close/reopen, session pause/resume, finish vs. interruption, clock-rollback clamping, running-session recovery after reopening the database, and a data-preserving schema migration.
- `flutter build windows --debug` succeeded and produced `build/windows/x64/runner/Debug/flowstate.exe`.
- The built app was launched and its window inspected: Home renders the sidebar, Today summary, and the three stat cards with no error state and no runtime exceptions in its log.
- `flutter test integration_test/app_flow_test.dart -d windows` passed on the real Windows desktop target. It creates a task, completes it, runs a focus session through start → pause → resume → finish, checks the recorded duration and Home statistics against stored data, then restarts against the same database file and confirms the completed task and statistics survived.
- After a full process restart of the debug executable, a previously stored task and completed session were still displayed (task visible, Focus time `00:20:00`).

Two real Windows defects were found and fixed during this verification: the database defaulted to the `Documents` folder, which Windows Controlled Folder Access blocks (the app started into a `SqliteException(14)` error screen); and the task editor disposed its text controllers while the dialog was still animating out, throwing `A TextEditingController was used after being disposed`. Both have regression coverage.

Android device tests, Linux builds, release builds, installers, and the APK are **not verified** and were not attempted; the Android SDK is absent from this machine. `flutter test -d windows` writes the integration-test entry point into the debug build output, so rebuild with `flutter build windows --debug` before launching the app by hand.

## Build and distribution roadmap

Release artifacts are **not yet generated**. Once the product and its data behavior are implemented and Flutter toolchains exist:

- Windows: `flutter build windows --release`, then produce and test the requested `FlowState-Setup.exe` installer, shortcuts, runtime dependencies, upgrade and uninstall.
- Linux: `flutter build linux --release`, package at least a `.deb` (consider AppImage), and test on a stated supported distribution.
- Android: configure a private release signing key and use `flutter build apk --release --build-name 0.1.0 --build-number 1`; deliver the built APK as `FlowState.apk`. Keep signing material/passwords out of source control and test installation/upgrades on a real compatible device.
- Provide separate source and artifact deliverables, reproducible commands, a practical friends' setup guide, privacy/Focus Lock limitations, and feature status before calling the application complete.

A free GitHub release can be considered only after actual artifacts build; no release has been published.

## Current verification record

Milestone 1A verification is recorded in [PROJECT_STATUS.md](PROJECT_STATUS.md), with commit `7405c2a`. Milestone 1B passes `dart format`, `flutter analyze`, all 16 automated tests, the Windows debug build, and an on-device Windows integration test, and the built app was observed running with persisted data surviving a restart. No release build, installer, APK, Android device test, or Linux test is claimed.
