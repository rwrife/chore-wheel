# Chore Wheel — PLAN

## Scope

Local-first iPhone household chore board. One device owns the household; other residents are local profiles. Core loop: define chores with effort and cadence, let a deterministic rotation propose assignments, record completions, request/consent swaps, and review honest fairness totals. Everything is offline and exportable.

## Architecture

- `ChoreWheelApp` (SwiftUI) → `ChoreBoardViewModel` (`@Observable`, MainActor) → `ChoreLedger` domain layer → local SQLite/GRDB-style append-only event store (implementation chosen in the skeleton issue; no network layer).
- Events: household/member/chore edits, `assigned`, `completed`, `missed`, `swapRequested`, `swapAccepted`, `swapDeclined`. Current board is a pure fold over events, so history and fairness math stay reproducible and exportable.
- `RotationEngine`: deterministic, effort-weighted, least-recent-assigned tie-breaks; stable sequence under insertion order; documented rules with unit tests. Unknown state stays unknown — no silent credits or auto-completions.
- `ChoreWorkspaceLayout` seam isolates folded vs expanded presentation so a future native iPhone Duo dual-screen migration can attach real APIs without rewriting domain code; today it renders a standard single-screen iPhone layout only.

## Technology choices

Native Swift only, SwiftUI for UI plus UIKit where needed. Apple's iOS 26 SDK and Xcode 26.0.1 build 17A400, Swift language mode 6. SQLite provides local durability. `toolchain.json` is the machine-readable contract. Cross-platform/hybrid UI is prohibited: no Flutter, no React Native, no Expo, no Kotlin Multiplatform, no .NET MAUI, no Unity.

iPhone-only is mandatory: `TARGETED_DEVICE_FAMILY = 1` in every app-target configuration, and built `UIDeviceFamily` must be [1]. Android is not a roadmap item; native iPad support is disabled and requires explicit user opt-in. Bundle identifier is `com.infinityball.chorewheel` in PRODUCT_BUNDLE_IDENTIFIER, Info.plist, signing/provisioning, and App Store Connect registration.

## Milestones / dependency order

1. Repository skeleton, toolchain contract, CI Linux-side lint/structure checks.
2. Domain events, ledger fold, rotation engine, and exhaustive unit tests.
3. Persistence and migration-safe local store.
4. Today board and one-thumb completion flow.
5. Chore/member editing and cadence scheduling.
6. Swap request/consent/audit flow.
7. Fairness review, JSON backup/restore, redacted share export.
8. Accessibility hardening and VoiceOver/Dynamic Type journey.
9. App Store copy/icon, signing/TestFlight release Action, documentation.

## Testing

Domain and rotation logic use deterministic fixtures and property-style sequence tests. Persistence uses temp databases and stateful-test isolation. Future UI tests run only on Apple CI. Every acceptance criterion names the actual command/tool and output; Linux checks are structural only and never called an iOS build.

## Packaging

MVP remains local. When packaging starts, port the proven `rwrife/cook-console` workflow `.github/workflows/release.yml` unchanged in shape: `v*` tag or manual dispatch, macos-26, enforce iOS 26/Xcode 26.0.1/17A400, mode-600 App Store Connect key, signed IPA export, TestFlight upload, polling, GitHub release. Required secret names only: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`. App artwork must exist at `AppStore/icon.png` and be wired into the asset catalog; `AppStore/description.txt` is reviewed against shipped behavior.

## Risks and non-goals

Rotation fairness can feel subjective, so expose effort assumptions and keep manual override auditable. Household participants are local profiles only; multi-device sync would require consented transport and is deferred. Missed chores are recorded explicitly and never inferred. No accounts, payments/allowances, points for children, leaderboards, surveillance, cloud sync, remote notifications, camera, location, analytics, medical/behavioral claims, Android app, or native iPad UI. Future iPhone Duo support is a presentation migration through `ChoreWorkspaceLayout`, never a current build dependency.
