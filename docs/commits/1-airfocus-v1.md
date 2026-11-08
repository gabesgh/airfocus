# 1st commit: airfocus v1.0.0 menu bar app, head-tracked window focus, mission control and desktop flicks, look-away screen saver, hidden overlay and menu bar icon, liquid glass settings window, shadow intent engine with traces, release workflow and installer, mit license

## Context
AirFocus focuses the window you're facing, using AirPods head tracking, so you can move between terminals running separate agents without leaving the keyboard. This first commit is the whole app as v1.0.0, renamed from its working name WindowTrack and cleaned up for a public GitHub release.

## Changes
- Swift package with a pure `AirFocusCore` library (calibration, target selection, flicks, look-away, intent engine, traces) and the `AirFocus` AppKit app around it.
- Head tracking through CMHeadphoneMotionManager, calibration with nose-pointed dots, recenter, and focus switching through SkyLight with an Accessibility fallback.
- Head flicks for Mission Control and Desktops, and picking a Mission Control window by holding the head on it.
- Look-away screen saver with wake to the unlock prompt.
- Hidden overlay by default, an optional visible overlay with styling, and a menu bar icon that can auto-hide or hide.
- SwiftUI Settings window with Liquid Glass, custom menu bar and app icons.
- Intent engine in shadow mode, opt-in session traces, and replay tools.
- Signing that defaults to ad hoc, with an untracked `signing-identity.local` for a personal certificate.
- [.github/workflows/release.yml](../../.github/workflows/release.yml) builds and publishes a release on a `v*` tag, and [install.sh](../../install.sh) installs the latest one.

## Why
The name WindowTrack described the mechanism, while AirFocus says what it does. The release setup copies the Ledge project's, which already works without an Apple Developer ID: an ad hoc build, a zip with a checksum, and a curl installer that clears stale permission entries on update. Session traces became opt in for the public build because they record key-press timing.

## Files
| File | Change |
|---|---|
| Package.swift, Makefile, scripts/build-app.sh | Package, build, signing and version stamping |
| Sources/AirFocusCore/ | Core logic |
| Sources/AirFocus/ | App, overlay, settings, motion, focus, CLI |
| Tests/AirFocusCoreTests/ | 219 unit tests |
| Support/ | Info.plist, app icon, menu bar icon |
| docs/SPEC.md, docs/RESEARCH.md | Behaviour spec and research notes |
| docs/releases/v1.0.0.md | Release notes |
| README.md, LICENSE, install.sh, .github/workflows/release.yml | Release and docs |

## Verification
`swift test` passes 219 tests. `make app` builds with no warnings and `codesign --verify --strict` passes. An ad hoc build with `SIGN_IDENTITY=- VERSION=1.0.0 BUILD_NUMBER=42` stamps the version and verifies. The app runs on macOS 26.7.1 with AirPods Pro, and window switching, flicks, Mission Control picking and look-away all work on real hardware. The intent engine is only checked on synthetic traces so far.

## Rollback
This is the first commit. Delete the repository to undo it, and remove `~/Applications/AirFocus.app` and the `com.gshimoon.airfocus` defaults domain locally.
