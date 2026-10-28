# FlowState — Master Implementation Prompt

## 1. Your Role

Act as a senior Flutter engineer, software architect, UI/UX designer, and pragmatic cross-platform developer.

Build **FlowState**, a real, functional, offline-first personal productivity and collaborative study application for:

- Windows
- Linux
- Android

Use a shared Flutter/Dart codebase wherever practical. Native platform-specific components are permitted when required for focus enforcement.

This is a real application intended for personal use and use by friends. Do not deliver merely a mockup, static prototype, or collection of nonfunctional screens.

**Important:** Do not attempt to implement every feature in one enormous step. Inspect the environment, establish a reliable architecture, implement in milestones, test each milestone, and keep the application runnable throughout development.

## 2. Non-negotiable constraints

- Total budget: ₹0.
- No paid APIs, paid hosting requirements, paid domains, or services that require entering payment details.
- Prefer free and open-source tools, libraries, and self-hostable alternatives.
- Online services must have a free usage option suitable for initial personal use. Verify their current limits and terms before choosing them.
- The local productivity experience must continue working when the internet or backend is unavailable.
- Never fabricate working functionality, successful tests, security guarantees, or platform support.
- No mandatory account for basic personal productivity.
- Never claim Focus Lock is unbreakable.
- Preserve user data and provide sensible error handling, recovery, and migration paths.
- Do not sacrifice functionality for visual polish, but the finished app must look intentional and polished.

If a feature cannot be implemented reliably for ₹0, document the limitation and provide the best viable alternative before introducing a paid dependency.

## 3. Product identity and design

Product name: **FlowState**

Design a premium, minimal, dark productivity interface.

Visual direction:
- Charcoal and near-black surfaces.
- Restrained violet accents.
- Clear typography, consistent spacing, and a strong visual hierarchy.
- Subtle transitions and purposeful animations.
- Clean cards, progress indicators, readable charts, and useful empty states.
- No excessive gradients, glassmorphism, decorative clutter, or generic AI-generated dashboard aesthetics.

Desktop:
- Persistent navigation sidebar.
- Main workspace with responsive content.
- Suitable keyboard navigation and shortcuts.
- Proper resizing and window-state handling.

Android:
- Mobile-first layouts.
- Bottom navigation.
- Touch-friendly controls.
- Responsive timer, task, and room interfaces.
- No desktop-style layouts squeezed onto a phone.

Use Flutter Material 3 as a foundation with a custom FlowState design system. Keep typography, spacing, colors, components, and interaction patterns consistent across platforms.

## 4. Core application features

Implement the following sections:

### Home
- Today's focus time and completed sessions.
- Current session and timer controls.
- Today's tasks and habit progress.
- Recent notes and relevant study-room activity.
- Useful empty states for new users.

### Tasks
- Create, edit, complete, and delete tasks.
- Due dates, priorities, and optional descriptions.
- Filter and sort tasks.
- Persist all changes locally.

### Focus
Support three timer modes:

1. Stopwatch: counts upward until stopped.
2. Pomodoro: configurable focus and break durations.
3. Custom countdown: user-defined duration.

Requirements:
- Start, pause, resume, finish, and cancel where appropriate.
- Persist enough timer state to recover correctly after an application restart.
- Handle backgrounding, sleep, and system-clock changes sensibly.
- Use monotonic timing or platform-appropriate timing for elapsed intervals where possible.
- Never rely on repeatedly decrementing a counter as the sole source of timing truth.
- Record session start, end, duration, mode, interruptions, and relevant enforcement state.
- Clearly distinguish completed sessions from interrupted sessions.

### Habits
- Create and edit recurring habits.
- Mark habits complete for a day.
- Display streaks and completion history.
- Avoid counting the same completion twice.

### Notes
- Create, edit, search, and delete personal notes.
- Persist locally.
- Keep the first version simple and reliable.

### Insights
- Daily and weekly focus summaries.
- Completed sessions and task completion.
- Habit trends.
- Charts with meaningful empty states.
- Clearly label local statistics versus server-synchronized room statistics.

### Settings
- Theme and basic preferences.
- Timer presets.
- Notification preferences where supported.
- Focus Lock setup and status.
- Account, privacy, data export, and synchronization settings.
- Clear information about supported platforms and permissions.

## 5. Offline-first architecture

Local data is the source of truth for personal productivity.

Evaluate this initial stack:
- Flutter and Dart.
- Riverpod for state management.
- go_router for navigation.
- SQLite with Drift for local persistence.
- fl_chart or a suitable maintained alternative for charts.
- A maintained authentication and synchronization solution that fits the zero-cost constraint.

Supabase's free tier may be evaluated for authentication, PostgreSQL, and realtime room updates, but do not assume its current limits or availability without checking.

Design clear repository and service boundaries so that the local app remains useful if the remote backend is unavailable.

Requirements:
- Tasks, notes, habits, settings, and personal sessions work locally.
- Local changes appear immediately.
- Remote synchronization happens automatically in the background when possible.
- Handle duplicate events, retries, conflicts, and interrupted synchronization.
- Use stable IDs and idempotent synchronization operations.
- Avoid silently overwriting newer user data.
- No mandatory manual session-submission workflow.
- No approval queue or host-validation process for offline personal sessions.
- Do not require the user to remain connected to the internet to use the timer.

Room members who are offline should retain their last synchronized room information. When they reconnect, changes should synchronize automatically without distracting pop-ups.

Be explicit about the difference between locally recorded focus time and server-accepted competitive statistics. A client-only offline record cannot be guaranteed cheat-proof by a remote server.

## 6. Accounts, friends, and study rooms

Basic personal productivity must work without an account.

Require an account only for features that genuinely need identity, friend connections, or shared remote data.

Implement:
- Usernames and friend requests.
- Accepting and rejecting friend requests.
- Private rooms with invited members only.
- Shareable room links or codes.
- Create, join, leave, and manage rooms.
- Owner-controlled invitations by default.
- Optional room setting allowing all members to invite others.
- Revocable and regenerable invite codes.
- Owner ability to remove members.
- Safe ownership transfer before the owner leaves.
- No public room discovery in the initial release.

Use server-side authorization for room membership and privileged operations. Never trust a client-supplied user ID, role, focus duration, or room-owner claim without appropriate validation.

### Independent study sessions

Each member can run their own timer while sharing a room.

Display:
- Current member status.
- Current or most recent session.
- Focus duration.
- Break or pause status.
- Completed sessions.
- Last-seen or offline state when relevant.

### Synchronized group sessions

- A leader can start a shared schedule.
- Members follow common focus and break intervals.
- Shared session timing is based on server-authoritative timestamps.
- Clients calculate the displayed remaining time from synchronized timestamps.
- Do not rely on simultaneous button presses or client clocks for synchronization.
- Members can leave early without stopping the session for everyone else.
- If a member is already running an independent timer, ask before switching. Record or preserve that session instead of silently discarding it.

### Lightweight room interaction

Include:
- Quick reactions.
- Short text messages.
- Simple, bounded room conversation.
- Basic abuse controls such as message limits and the ability to remove members.

Do not include:
- Voice chat.
- An endless social feed.
- Public room discovery.
- Unnecessary social features that distract from studying.

### Leaderboards

Provide daily and weekly rankings based on:
- Eligible focus time.
- Completed sessions.

Define reset boundaries consistently, preferably using UTC for backend aggregation while displaying the appropriate local dates.

Document the competitive eligibility rules. Server-side validation can improve integrity, but a personal-device app cannot prove that somebody genuinely studied or eliminate every cheating method.

Never present a local-only session as server-verified competitive time.

## 7. Focus Lock

Focus Lock is a core differentiator, not a cosmetic timer feature.

The goal is to restrict distracting applications and websites during an active focus session as strongly as the relevant operating system reasonably permits.

Maintain separate state for:
1. Timer state.
2. Enforcement state.
3. Synchronization state.

The timer running does not mean Focus Lock is active.

### Windows and Linux desktop

Start with:
- A Chromium-compatible browser extension.
- Native desktop integration where required.
- A guided one-time setup.
- Clear explanations of permissions and limitations.
- A visible list of selected allowed applications and websites.

Website restrictions:
- Block configured distracting sites and allow configured sites according to the selected mode.
- Use supported browser extension APIs and test navigation, redirects, tabs, and common bypass routes.
- Handle extension removal, disabling, browser closure, and permission loss honestly.
- Do not assume the extension can control every browser or application.

Application restrictions:
- Investigate practical enforcement mechanisms for Windows and common Linux desktop environments.
- Prefer supported OS mechanisms and transparent configuration.
- Avoid dangerous changes to the operating system, indiscriminate process termination, or disabling security tools.
- Do not promise universal application blocking.
- Do not silently elevate privileges or bypass operating-system security.
- Document differences between Windows, Linux distributions, desktop environments, and browser versions.

Begin with one Chromium-based extension that can be tested reliably in compatible browsers such as Chrome, Edge, and Brave. Expand browser support only after the initial implementation is stable.

If the native component or extension is not available, permission is lost, or enforcement cannot be confirmed, mark the session's protection as degraded or unavailable.

### Android

Build an early Accessibility-based Focus Lock prototype and test it on a real, ordinary Android phone.

Requirements:
- Explain why the permission is needed.
- Request explicit user consent.
- Provide setup, status, troubleshooting, and disable instructions.
- Follow Android platform restrictions and applicable distribution policies.
- Investigate whether the chosen enforcement behavior is permitted and reliable before implementing it.
- Do not misrepresent Usage Access as app blocking.
- Do not claim that Accessibility can prevent every possible bypass.
- Handle app restarts, permission revocation, background limitations, and system changes.
- Do not make device-owner provisioning or managed-device kiosk mode a requirement for ordinary users.

If reliable blocking cannot be achieved on the target device, report the limitation and retain the usable timer functionality.

### Emergency exit and enforcement failures

- Always provide a clear emergency exit.
- Explain that leaving early releases applicable restrictions.
- Release restrictions safely.
- Record the interruption locally.
- Apply documented eligibility rules to competitive focus statistics.
- Restore normal access after normal completion.
- Do not trap the user, conceal the exit, or interfere with emergency access or essential system functions.

Focus Lock must be designed for accountability, not coercion.

## 8. Personal statistics and competitive integrity

Maintain separate concepts:

**Local personal focus time**
- Updated immediately after locally recorded sessions.
- Available offline.
- Calculated from local records and local enforcement checks.
- Never requires host approval.

**Room competitive statistics**
- Synchronized automatically when online.
- Subject to documented server-side eligibility rules.
- May lag behind for disconnected members.
- Must not claim to be fully cheat-proof.

A locally checked session may count toward the user's personal verified-time total according to the app's local checks. However, local verification is not the same as independent server verification.

Do not interrupt users to submit offline sessions. Do not introduce distracting pending-validation banners. Resolve synchronization in the background and explain any material discrepancy in a calm, transparent way.

## 9. Privacy and security

- Collect only information required for the features.
- Keep personal notes and private productivity data private by default.
- Restrict room messages and member information to authorized room members.
- Never embed backend service-role secrets in the application.
- Use secure authentication practices and appropriate local credential storage.
- Enforce database access controls and server-side authorization.
- Validate and rate-limit invites, friend requests, and room messages.
- Provide a way to export personal data.
- Explain what is stored locally and what is synchronized.
- Do not transmit private notes or unrelated personal data to the study-room backend unnecessarily.

## 10. Notifications and user experience

Use notifications only when useful and supported by the platform:
- Focus session completion.
- Break completion.
- Relevant synchronized room events.

Avoid notification spam and distracting animations.

Provide:
- Accessible labels and keyboard navigation.
- Loading, error, and empty states.
- Clear permission-denied handling.
- Recoverable failures.
- Useful setup instructions.
- Confirmation before destructive operations.
- Consistent behavior when switching between desktop and Android.

## 11. Development milestones

### Milestone 0 — Feasibility and architecture

Before implementing the full application:
- Inspect the repository and development environment.
- Confirm available Flutter SDKs and platform toolchains.
- Identify the actual build target and limitations.
- Research the current feasibility and permissions of desktop and Android enforcement.
- Check the current free-tier requirements of candidate backend services.
- Propose the architecture, data model, and module boundaries.
- Identify high-risk assumptions and test them with small prototypes.

Do not build the entire product around an untested Focus Lock assumption.

### Milestone 1 — Functional local application

Implement:
- Dark UI and navigation.
- Local database and migrations.
- Home, tasks, focus timers, habits, notes, insights, and settings.
- Reliable session persistence and recovery.
- Basic tests and usable empty states.

The application must work without registration or an internet connection.

### Milestone 2 — Accounts and study rooms

Implement:
- Authentication.
- Friends and invitations.
- Private rooms and authorization.
- Independent and synchronized sessions.
- Room status, lightweight messaging, reactions, and leaderboards.
- Background synchronization and offline recovery.

### Milestone 3 — Desktop Focus Lock

Implement and test:
- Chromium extension.
- Native desktop integration.
- Practical application restrictions.
- Guided setup and truthful enforcement states.
- Emergency exit and interruption recording.

### Milestone 4 — Android Focus Lock prototype

Test the Accessibility-based approach on real hardware. Document actual behavior, battery impact, permission requirements, platform restrictions, and bypass limitations.

### Milestone 5 — Hardening and release

- Cross-platform testing.
- Data migration and recovery testing.
- Security and authorization testing.
- Synchronization and conflict testing.
- Performance and accessibility improvements.
- Build instructions and release documentation.
- Free distribution options such as GitHub releases and direct APK distribution where appropriate.

## 12. Quality requirements

- Keep modules maintainable and clearly separated.
- Use typed models, predictable state management, and repository abstractions.
- Include automated tests for core business logic.
- Test timer recovery, duplicate synchronization, offline operation, permissions, room access, and session eligibility.
- Add integration tests where practical.
- Never claim a platform or feature is supported until it has been tested.
- Keep dependencies maintained and avoid unnecessary packages.
- Record architectural decisions and known limitations.
- Do not use mock data as a substitute for real functionality in the finished feature.

## 13. Final deliverables

Produce:
- The working Flutter application.
- All required source code.
- Native desktop components and browser extension source, where implemented.
- Database schema and migrations.
- Backend schema, authorization policies, and setup instructions, if a backend is used.
- Automated tests and test instructions.
- Windows, Linux, and Android build instructions.
- A practical setup guide for friends.
- A privacy and Focus Lock limitations guide.
- A list of implemented, partially implemented, and unimplemented features.
- A zero-cost deployment and distribution guide.

## 14. How to begin

Start by inspecting the existing project and the available development environment.

Then present:
1. A concise architecture proposal.
2. A milestone checklist.
3. The major technical risks, especially Focus Lock.
4. Any required environment setup.
5. The smallest first milestone that can be completed and tested end to end.

If a decision is not specified, choose a sensible, privacy-conscious, zero-cost default and document it. Ask questions only when a decision genuinely blocks progress.

Do not claim that the complete product exists until it has actually been implemented and tested.

**Begin with Milestone 0, then proceed incrementally toward a real, polished, cross-platform FlowState application.**

### 15. Mandatory Build and Distribution Requirements

The project is not complete until installable release artifacts have been generated and their build results documented.

**Windows**
- Build a release version of the Flutter Windows application.
- Package it into a user-friendly Windows installer named `FlowState-Setup.exe`.
- Include installation, Start Menu shortcut, optional desktop shortcut, and uninstall support.
- Ensure required runtime dependencies are included or installed correctly.
- Test installation, launch, application data persistence, upgrade behavior, and uninstall on Windows 11.

**Linux**
- Generate at least one usable distribution package, preferably `.deb`, and evaluate AppImage where practical.
- Document dependencies and supported distributions.
- Test installation and launch on a supported Linux environment.

**Android**
- Build a release APK named `FlowState.apk`.
- Ensure it can be installed directly on a compatible Android device without requiring Google Play.
- Test installation, permissions, local database persistence, timer recovery, and app upgrades.
- Document Android version requirements and any signing requirements.

**Release automation**
- Provide reproducible build scripts or documented commands.
- Keep signing keys, passwords, and secrets out of source control.
- Use GitHub Releases for distributing the generated artifacts at no cost, subject to current platform limits.
- Do not claim an installer or APK has been created until the actual file exists and its build has succeeded.
- Keep the Windows installer, Linux package, Android APK, and source code as separate deliverables.