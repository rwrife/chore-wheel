#!/usr/bin/env python3
"""Linux-side structural gates for the chore-wheel skeleton (issue #1).

Checks, in order:
  1. toolchain.json matches the mandatory contract values.
  2. No cross-platform/hybrid framework files anywhere in the repo.
  3. Sources/ and Tests/ exist and contain Swift files.
  4. Every ChoreWheel.xcodeproj build configuration declares
     TARGETED_DEVICE_FAMILY = 1 and the app bundle id is
     com.infinityball.chorewheel (tests use the .tests suffix).
  5. .gitignore hygiene: signing material ignored, AppStore/icon.png
     force-tracked, no build junk tracked.
  6. Zero-network gate: no networking API references in Swift sources.

Structural only. This script never proves an iOS build; that belongs to
Apple CI (Xcode 26.0.1 / 17A400).
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def all_repo_files() -> list[str]:
    # Tracked + staged files only: matches CI's post-checkout view and fails
    # locally if new files were left uncommitted.
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--cached"],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    return out


tracked_files = all_repo_files


# --- 1. toolchain.json contract ---------------------------------------------
EXPECTED_TOOLCHAIN = {
    "schema": "tool-lab/toolchain/v1",
    "platform": "ios",
    "xcode_version": "26.0.1",
    "xcode_build": "17A400",
    "minimum_sdk_major": 26,
    "deployment_target": "26.0",
    "swift_language_mode": "6",
    "bundle_identifier": "com.infinityball.chorewheel",
    "targeted_device_family": "1",
    "native_ipad_support": False,
    "implementation": "native-swift",
    "device_family": "iphone-only",
}
try:
    toolchain = json.loads((ROOT / "toolchain.json").read_text())
    for key, want in EXPECTED_TOOLCHAIN.items():
        got = toolchain.get(key)
        if got != want:
            fail(f"toolchain.json: {key} = {got!r}, expected {want!r}")
except Exception as exc:  # noqa: BLE001
    fail(f"toolchain.json unreadable: {exc}")

# --- 2. no cross-platform/hybrid files ---------------------------------------
CROSS_PLATFORM_MARKERS = [
    "pubspec.yaml", "android/app/build.gradle", "build.gradle",
    "build.gradle.kts", "settings.gradle", "gradlew", "Kotlin", ".kt",
    ".aar", "Unity", "MAUI", "SkiaSharp",
]
prohibited = ["flutter", "react-native", "expo", "unity", "maui", "kotlin"]
for f in tracked_files():
    low = f.lower()
    if any(m in low for m in prohibited):
        fail(f"prohibited cross-platform path tracked: {f}")
    if low.endswith((".kt", ".kts")):
        fail(f"prohibited Kotlin source tracked: {f}")
    for marker in ("pubspec.yaml", "gradlew", "build.gradle"):
        if low.endswith(marker):
            fail(f"prohibited cross-platform marker tracked: {f}")

# --- 3. native Swift structure ------------------------------------------------
swift_files = [f for f in tracked_files() if f.endswith(".swift")]
if not any(f.startswith("Sources/") for f in swift_files):
    fail("no Swift sources under Sources/")
if not any(f.startswith("Tests/") for f in swift_files):
    fail("no Swift tests under Tests/")
if not (ROOT / "Package.swift").is_file():
    fail("Package.swift missing at repo root")

# --- 4. Xcode project contract ------------------------------------------------
proj = ROOT / "ChoreWheel.xcodeproj" / "project.pbxproj"
if not proj.is_file():
    fail("ChoreWheel.xcodeproj/project.pbxproj missing (run Tools/gen_project.rb)")
else:
    text = proj.read_text()
    fam = re.findall(r"TARGETED_DEVICE_FAMILY = (\S+?);", text)
    if not fam:
        fail("pbxproj: no TARGETED_DEVICE_FAMILY declaration found")
    bad = sorted({v for v in fam if v.strip('"') != "1"})
    if bad:
        fail(f"pbxproj: TARGETED_DEVICE_FAMILY must be 1 everywhere, found {bad}")
    ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = (\S+?);", text))
    if ids != {"com.infinityball.chorewheel", "com.infinityball.chorewheel.tests"}:
        fail(f"pbxproj: unexpected bundle identifiers: {sorted(ids)}")
    if "macosx" in text.lower():
        fail("pbxproj: macOS platform SDK referenced; app is iPhone/iOS only")
    if 'sdkroot = macosx' in text.lower():
        fail("pbxproj: macOS sdkroot found; app is iOS only")
    # Every app/domain/test Swift file must be wired into the hand-maintained
    # pbxproj; a file that exists only in Package.swift silently skips Apple CI.
    for prefix in ("Sources/ChoreWheel/App/", "Sources/ChoreWheel/Domain/", "Tests/ChoreWheelTests/"):
        for swift in sorted((ROOT / prefix).glob("*.swift")):
            if swift.name not in text:
                fail(f"pbxproj: {prefix}{swift.name} is not referenced in the Xcode project")

# --- 5. .gitignore hygiene -----------------------------------------------------
gitignore = (ROOT / ".gitignore").read_text()
for pattern in ("*.p8", "*.mobileprovision", "xcuserdata/", "DerivedData/", "*.xcresult/"):
    if pattern not in gitignore:
        fail(f".gitignore missing required pattern: {pattern}")
for f in tracked_files():
    if f.endswith((".p8", ".p12", ".mobileprovision", ".provisionprofile")):
        fail(f"signing material tracked in git: {f}")
    if "/.build/" in f or f.startswith(".build/") or "/DerivedData/" in f:
        fail(f"build artifact tracked in git: {f}")
ls_check = subprocess.run(
    ["git", "-C", str(ROOT), "check-ignore", "-q", "AppStore/icon.png"],
)
if ls_check.returncode == 0:
    fail("AppStore/icon.png is gitignored; icon artwork must be force-tracked")

# --- 6. zero-network gate -------------------------------------------------------
NET_PATTERNS = re.compile(
    r"URLSession|NWConnection|Network\.framework|MFMailComposeViewController|CFNetwork|WebSocket|CFStream|Firestore"
)
for f in swift_files:
    p = ROOT / f
    if not p.is_file():
        continue
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if NET_PATTERNS.search(line):
            fail(f"networking API reference banned by local-first contract: {f}:{i}: {line.strip()}")

if failures:
    print("STRUCTURE CHECK FAILURES:")
    for m in failures:
        print(f"  - {m}")
    sys.exit(1)
print("OK: toolchain contract, structure, project pins, gitignore, and zero-network gates all pass.")
