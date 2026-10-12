# Chore Wheel

Local-first iPhone chore board for households: deterministic rotation, one-thumb done check-ins, swap requests, and honest fairness counts — no accounts or cloud.

## Why / who

Roommates and families need a clear answer to who handles recurring chores next without a nagging administrator, punitive points, or a shared account. One person can maintain a household board on their iPhone; other participants are named profiles, not remotely synchronized users. Sharing a snapshot requires explicit export. Nobody else's phone receives live updates in MVP.

## Workflow

Create named members and chores with estimated effort, repeat cadence, and rotation order. See today's assignments; mark a task done or request a swap. Resolve swaps on the same phone with explicit consent and an audit entry. Review completed effort by member and period; missed entries stay unknown, not silently credited. Export a portable JSON backup and a redacted printable/shareable board. Restore requires explicit confirmation.

Folded use: one-thumb next task and done controls. Future iPhone Duo design target: persistent assignments and fairness context on one screen, task detail and swap history on the other. Current app is a standard iPhone app; no fold APIs exist in this scaffold. Migrate via `ChoreWorkspaceLayout` when Apple provides public dual-screen APIs; native iPad support is disabled, and iPad layouts require explicit opt-in.

## MVP / non-goals

- Local household, members, chores, assignment rotation, completion log, consented swap, fairness totals, JSON import/export, accessible iPhone UI.
- No multi-device sync, accounts, payment/allowance, child surveillance, reward leaderboards, auto-verification, or remote notifications. No Android or native iPad support; no Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity.
- iPhone only, native Swift/SwiftUI/UIKit. iOS 26+ SDK, pinned Xcode 26.0.1 (17A400); `TARGETED_DEVICE_FAMILY = 1` in every app configuration and built `UIDeviceFamily = [1]`. iPhone compatibility mode on iPad is not native iPad support.

## Privacy and accessibility

Data stays on device in an app-local store. JSON/share exports are explicit and may reveal member names; preview and redact names before sharing. No account, tracker, analytics, camera, location, contacts, or internet permission. Notifications optional, local only, and off by default. VoiceOver labels, Dynamic Type, contrast, reduced motion, and large tap targets are MVP acceptance criteria. Delete household and exports separately. This is household coordination, not a safety or health system.

## Status / development

Documentation-only scaffold. No application, icon, release workflow, native build, or TestFlight build exists yet. See [PLAN.md](PLAN.md) and issues for milestones. On macOS with Xcode 26.0.1/17A400, build the future Xcode project using `xcodebuild`; Linux cannot prove an iOS build. `toolchain.json` records planned pins, not measured CI evidence.

Bundle ID: `com.infinityball.chorewheel` (App Store Connect: CREATED). Future Xcode app target uses this exact `PRODUCT_BUNDLE_IDENTIFIER` and Info.plist identity. App Store copy draft: `AppStore/description.txt`; real `AppStore/icon.png` must be generated with `hermes-image-gen` and wired into Xcode app-icon assets by its issue, not replaced with placeholder.

Release milestone must port `rwrife/cook-console` `.github/workflows/release.yml`: `v*` tag/manual dispatch, macos-26, iOS 26+ SDK, signed IPA, App Store Connect API upload/processing, GitHub release. Secrets already configured: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`. Values never logged. Release is not implemented in this scaffold.
