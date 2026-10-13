# Issue #1 verification — native skeleton & CI gates (Linux-side evidence)

Generated/verified on 2026-10-13 on this Linux (aarch64) host. These are
structural and Linux-toolchain checks only. They are NOT an iOS build; the
macOS CI lane (macos-26, Xcode 26.x, iOS 26 SDK) is the first native proof
and its result must be read from the PR's Checks tab.

## Commands and results

1. Xcode project generation (xcodeproj gem via Docker):

   ```
   docker run -v $PWD:/work -v .../chorewheel-genproj.sh:/gen.sh:ro \
     -v .../chorewheel-cache-home:/work/.cache-home -w /work \
     ruby:3.3-alpine sh /gen.sh
   # OK: generated ChoreWheel.xcodeproj
   ```

   Pitfall found: the xcodeproj gem defaults new targets to
   `TARGETED_DEVICE_FAMILY = "1,2"`, which shadows a project-level `1`.
   `Tools/gen_project.rb` overrides it at target level; `check_structure.py`
   fails if any `TARGETED_DEVICE_FAMILY` value other than `1` appears.

2. SwiftPM build + swift-testing suite (Docker swift:6.2):

   ```
   docker run --user 1000:1000 -e HOME=/work -v $PWD:/work -w /work \
     swift:6.2 swift test
   # Build complete! (5.48s)
   # ✔ Test "scaffold version is pinned" passed
   # ✔ Test run with 1 test in 1 suite passed
   ```

3. Structural gates:

   ```
   python3 Tools/Checks/check_structure.py
   # OK: toolchain contract, structure, project pins, gitignore, and zero-network gates all pass.
   ```

4. Workflow lint: `actionlint` on `.github/workflows/ci.yml` (result recorded
   in the PR discussion).

## What is NOT proven here

- No iOS compilation, simulator boot, `UIDeviceFamily` inspection, archive,
  or TestFlight upload. Those run only in the macOS CI job of this PR.
- No app icon (`AppStore/icon.png` intentionally absent; issue #8 owns it).
