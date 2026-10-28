# FlowState

FlowState is an offline-first productivity and collaborative study app for Windows, Linux, and Android. Development is intentionally incremental. The current starter milestone is a dark, responsive app shell with a working, in-memory monotonic focus stopwatch; it is not yet the complete product.

## Current milestone

The starter includes:

- A Flutter Material 3 app shell, with a desktop sidebar and a compact mobile layout.
- A working stopwatch with start, pause, resume, finish, and interrupted/cancel states.
- A pure-Dart timer model using a monotonic `Stopwatch`, plus deterministic unit tests.
- Honest empty-state messaging: session history and persistence are not implemented yet; Focus Lock is not enabled.

Not implemented yet: a database, crash/restart recovery, Pomodoro/custom countdowns, tasks, habits, notes, insights, navigation between sections, notification delivery, export, authentication, synchronization, rooms, browser/native enforcement, or release artifacts. UI placeholders are not functional features.

## Architecture proposal

Keep a single Flutter/Dart codebase for the three target platforms. Split the app into presentation, domain, local-data, and optional remote-data layers. Personal productivity should not depend on an account or a network.

For the initial local milestone, use a feature-oriented structure, with Flutter Material 3 UI, Riverpod for application state, `go_router` for real section navigation, and SQLite via Drift for persisted personal data and versioned migrations. Keep interfaces between repositories and UI/domain code so future remote synchronization cannot replace local source-of-truth behavior. Model persisted entities with stable IDs and timestamps; record sessions as append-oriented events so interrupted sessions and future sync retries can be understood without silently overwriting newer data. Timer state should store the session's wall-clock anchor and paused accumulated duration for restart recovery, while using monotonic elapsed measurements within a running process. Persist task, note, habit, preference, and session data locally before adding sync.

Do not add the database, routing, or state packages until their first real milestone needs them; this bootstrap deliberately has zero third-party Dart packages.

### Milestones

- [x] Milestone 0 — inspect workspace/toolchain; assess Focus Lock and zero-cost backend options; record risks and architecture.
- [ ] Milestone 1A — responsive shell and tested stopwatch model (this initial implementation).
- [ ] Milestone 1B — database, migrations, recoverable sessions, and functional home/tasks/focus screens.
- [ ] Milestone 1C — local habits, notes, insights, settings, data export, and offline tests.
- [ ] Milestone 2 — optional identities, friends, private rooms, authorization, realtime sessions and background sync.
- [ ] Milestone 3 — opt-in Chromium website-blocking extension; assess platform-specific native integrations only where users can configure them safely.
- [ ] Milestone 4 — research and, if policy and device testing support it, an opt-in Android Accessibility focus-friction prototype.
- [ ] Milestone 5 — migration, security, accessibility, cross-platform QA, documentation, reproducible release builds and installer/package generation.

No release milestone is complete until Windows installer, Linux package, and Android APK artifacts have actually built; platform-specific install/upgrade behavior must also be tested on the target operating systems/devices. This Windows workspace does not itself prove those tests.

## Milestone 0 findings

### Toolchain available in this workspace

The environment is Windows 11 (MINGW64/Git Bash) with Java 21. Flutter, Dart, Android Debug Bridge, CMake, Ninja, Clang, and Gradle are not on `PATH`. Consequently this workspace cannot currently run `flutter pub get`, `flutter analyze`, `flutter test`, any Flutter build, or a device-install test. No installable artifact has been produced. No other project files existed at initial inspection.

Required next: install the Flutter stable SDK and add its `bin` folder to `PATH`; install Android Studio/Android SDK tools (and connect a physical Android device or start an emulator); install Visual Studio with the **Desktop development with C++** workload for Windows builds. Linux builds require a Linux build machine/CI runner plus Flutter, Clang, CMake, Ninja, pkg-config, GTK 3 development headers, and the C++ standard library headers. See the official [Flutter install guide](https://docs.flutter.dev/install), [Android setup](https://docs.flutter.dev/platform-integration/android/setup), [Windows setup](https://docs.flutter.dev/platform-integration/windows/setup), and [Linux setup](https://docs.flutter.dev/platform-integration/linux/setup).

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

With Flutter installed:

```sh
flutter pub get
flutter test
flutter run -d windows
```

For a connected Android device, use `flutter run -d <device-id>` after `flutter devices`. The current timer tests exercise the pure-Dart lifecycle with a deterministic fake monotonic clock; they do not establish UI, persistence, background execution, or platform Focus Lock behavior.

## Build and distribution roadmap

Release artifacts are **not yet generated**. Once the product and its data behavior are implemented and Flutter toolchains exist:

- Windows: `flutter build windows --release`, then produce and test the requested `FlowState-Setup.exe` installer, shortcuts, runtime dependencies, upgrade and uninstall.
- Linux: `flutter build linux --release`, package at least a `.deb` (consider AppImage), and test on a stated supported distribution.
- Android: configure a private release signing key and use `flutter build apk --release --build-name 0.1.0 --build-number 1`; deliver the built APK as `FlowState.apk`. Keep signing material/passwords out of source control and test installation/upgrades on a real compatible device.
- Provide separate source and artifact deliverables, reproducible commands, a practical friends' setup guide, privacy/Focus Lock limitations, and feature status before calling the application complete.

A free GitHub release can be considered only after actual artifacts build; no release has been published.
