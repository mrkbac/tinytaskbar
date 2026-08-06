# TinyTaskbar

TinyTaskbar is a small, native macOS 26 utility that keeps a compact taskbar over
the bottom of each connected display. Each item represents one eligible window
reported by Accessibility and matched to a current on-screen Core Graphics window.
Clicking an item activates, focuses, and raises its owning window.

The executable is an `LSUIElement` AppKit application. It has no Dock icon,
preferences window, helper, updater, analytics, thumbnail capture, or third-party
runtime dependency.

## Build and test

The package targets macOS 26 and is intended for Xcode 26.6 / Swift 6.3.3:

```sh
swift test
swift build
swift build -c release
pre-commit run --all-files
```

The local package tests cover eligibility, malformed input isolation, conservative
Core Graphics matching, display intersection/tie/fallback mapping, stable ordering,
deduplication, and lifecycle transitions. They do not replace tests on a real
multi-display, Spaces, fullscreen, or Stage Manager session.

## Local app bundle

Build and verify an ad-hoc bundle with:

```sh
bash scripts/build-app.sh --adhoc
codesign --verify --deep --strict --verbose=2 dist/TinyTaskbar.app
plutil -lint dist/TinyTaskbar.app/Contents/Info.plist
```

`dist/` is generated and ignored. Developer ID signing is opt-in:

```sh
bash scripts/build-app.sh --identity "Developer ID Application: Example (TEAMID)"
bash scripts/package-dmg.sh
```

Production notarization requires a separately configured `notarytool` keychain
profile. See [docs/RELEASE.md](docs/RELEASE.md); do not put credentials in this
workspace.

## Accessibility and privacy

Accessibility permission is required for semantic window enumeration, observation,
and focus/raise. TinyTaskbar checks trust once per launch, uses
`AXIsProcessTrustedWithOptions`, and presents one concise explanation with the
Privacy & Security → Accessibility path. If access is denied, it remains running
without taskbars and does not repeatedly prompt.

TinyTaskbar does not request Screen Recording. Window titles come from AX; Core
Graphics is used only for public owner, layer, on-screen, title, and geometry
metadata. No thumbnails or window content are captured.

## Important macOS boundaries

The current Space is represented conservatively by the intersection of AX window
geometry with the public `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)`
list. macOS does not expose a reliable public arbitrary-window Space ID, and the
deprecated Core Graphics workspace key is intentionally not used. Exact minimized
or cross-Space membership is not attempted.

The bar is an overlay. A third-party `NSPanel` cannot reserve screen work area like
the Dock, so TinyTaskbar may cover the bottom edge of application content. A
per-display panel uses public AppKit collection behavior for all Spaces,
fullscreen auxiliary participation, and Stage Manager/system-overlay joining;
real-machine behavior still needs validation.

App-provided AX metadata and notifications can be missing or malformed. A failing
application or window is skipped and revisited on later system events. Hidden
applications, minimized windows, and windows not reported on-screen by Core
Graphics are omitted in v1. Stage Manager background sets are therefore omitted;
fullscreen windows are included when Core Graphics reports them on-screen.

## Evidence status

Validated in the local checkout: debug tests, debug and release package builds,
Swift-format/pre-commit checks, app-bundle assembly, ad-hoc code-signature
verification, and plist syntax/structure checks. Manual Accessibility flow, app
launch, click-to-focus, multi-monitor/Spaces/fullscreen/Stage Manager behavior,
Developer ID signing, notarization/stapling, Gatekeeper on a clean machine, and
performance budgets remain explicitly pending until run on the required real
environment.
