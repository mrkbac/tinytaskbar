# TinyTaskbar

TinyTaskbar is a small, native macOS 26 utility that keeps a compact taskbar over
the bottom of each connected display. Each item represents one eligible window
reported by Accessibility and matched to a current on-screen Core Graphics window.
Clicking an item activates, focuses, and raises its owning window.

The executable is an `LSUIElement` AppKit application with no Dock icon during
normal taskbar operation, no helper, updater, analytics, thumbnail capture, or
third-party runtime dependency. It includes one small native onboarding/settings
window for Accessibility,
launch-at-login, and the window-title display preference; there is no SwiftUI or
general-purpose settings framework.

While Settings is visible, the app temporarily uses the regular activation policy so
WindowServer will present the normal window; macOS may show a Dock icon during that
interval. Closing Settings with X or Done restores accessory mode and removes the
temporary Dock presence.

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
and focus/raise. On first launch, or whenever access is denied, TinyTaskbar shows a
retained native onboarding/settings window and activates only that explicit window.
The Accessibility button calls `AXIsProcessTrustedWithOptions` only after the user
chooses it, opens Privacy & Security → Accessibility, and updates the status when
the app becomes active again. Closing the window keeps the process and taskbars
running; Done records onboarding completion. If access is denied, it remains
running without taskbars and does not automatically request TCC access.

The same window offers public `SMAppService.mainApp` launch-at-login control and a
persisted Show Window Titles toggle. Turning titles off changes compact button text
immediately while retaining full accessibility labels, tooltips, and app icons.

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
verification, and plist syntax/structure checks. Manual onboarding/settings flow,
Accessibility grant, app launch, relaunch/reopen behavior, close-without-quit,
click-to-focus, launch-at-login approval, multi-monitor/Spaces/fullscreen/Stage
Manager behavior, Developer ID signing, notarization/stapling, Gatekeeper on a
clean machine, and performance budgets remain explicitly pending until run on the
required real environment.
