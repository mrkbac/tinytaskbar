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
bash scripts/test-build-app-rollback.sh
```

The local package tests cover eligibility, malformed input isolation, conservative
Core Graphics matching, one-to-one AX/CG assignment and activation keys, display
intersection/tie/fallback mapping, Dock-aware panel frames, stable ordering,
deduplication, lifecycle transitions including open/move/minimize/restore/close,
injected permission/window providers, and the 120-window projection path. They do
not replace tests on a real multi-display,
Spaces, fullscreen, or Stage Manager session.

## Local app bundle

Create one persistent local code-signing identity, then reuse it for installed
development builds:

```sh
bash scripts/setup-local-signing.sh
bash scripts/build-app.sh
```

The setup is idempotent, stores the private key only in the user's login keychain,
and adds a user-domain trust entry scoped to the Code Signing policy for that one
certificate. Reusing this identity with the unchanged bundle identifier gives
rebuilt versions the same designated requirement, so macOS can preserve the
existing Accessibility decision. This self-signed identity is for local development
only; it is not suitable for distribution, Gatekeeper, or notarization.
Passing `--local` selects the same mode explicitly.

Build and verify an ad-hoc bundle when only bundle structure matters:

```sh
bash scripts/build-app.sh --adhoc
codesign --verify --deep --strict --verbose=2 dist/TinyTaskbar.app
plutil -lint dist/TinyTaskbar.app/Contents/Info.plist
```

Ad-hoc code identity changes whenever the executable changes, so do not use it for
installed Accessibility testing. `dist/` is generated and ignored. Developer ID
signing is opt-in:

```sh
bash scripts/build-app.sh --identity "Developer ID Application: Example (TEAMID)"
bash scripts/package-dmg.sh
```

The disk image contains the signed app and an Applications shortcut for the
standard drag-to-install flow. The bundle includes a project-owned native macOS
app icon in Finder and Launch Services.

Production notarization requires a separately configured `notarytool` keychain
profile. See [docs/RELEASE.md](docs/RELEASE.md); do not put credentials in this
workspace.

For primary Computer QA without Accessibility or TCC changes, build the debug-only
fixture bundle and launch one of the deterministic scenes directly:

```sh
bash scripts/build-app.sh --adhoc --configuration debug \
  --output dist/TinyTaskbar-Debug.app
dist/TinyTaskbar-Debug.app/Contents/MacOS/TinyTaskbar \
  --ui-test-fixture=normal
dist/TinyTaskbar-Debug.app/Contents/MacOS/TinyTaskbar \
  --ui-test-fixture=overflow
dist/TinyTaskbar-Debug.app/Contents/MacOS/TinyTaskbar \
  --ui-test-fixture=empty
```

The fixture uses the real panel, item views, scrolling, and projection path while
injecting deterministic window metadata; it never calls Accessibility or TCC.
The flag is compiled only into Debug builds and is not a Release backdoor.

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
deprecated Core Graphics workspace key is intentionally not used. Minimized windows
remain associated with their last AX geometry so they can be restored; exact
cross-Space membership is not attempted.

The bar is an overlay. A third-party `NSPanel` cannot reserve screen work area like
the Dock, so TinyTaskbar may cover the bottom edge of application content. Panels
use each screen's full and visible AppKit frames: a bottom Dock lifts the bar exactly
to the visible-frame boundary, while a side Dock trims its horizontal span without
changing its vertical position. There is no additional floating outer margin.
A per-display panel uses public AppKit collection behavior for all Spaces,
fullscreen auxiliary participation, and Stage Manager/system-overlay joining;
real-machine behavior still needs validation.

App-provided AX metadata and notifications can be missing or malformed. A failing
application or window is skipped and revisited on later system events. Hidden
applications and non-minimized windows not reported on-screen by Core Graphics are
omitted in v1. Minimized AX windows remain as dimmed taskbar items and restore on
click. Stage Manager background sets are therefore omitted; fullscreen windows are
included when Core Graphics reports them on-screen.

## Evidence status

Validated in the local checkout: 51 automated tests, debug and release package
builds, Swift-format/pre-commit checks, app-bundle assembly, ad-hoc code-signature
verification, and plist syntax/structure checks. Computer QA covers the denied
onboarding guide, Settings layout/reopen/close-without-quit, title preference, stable
window switching, the native Close context menu, and the normal/120-window/empty
DEBUG taskbar fixtures including horizontal scrolling.
Scoped measurements recorded 0.0% CPU in all 11 samples of a five-minute final
four-window fixture soak and 15 MB physical footprint (35 MB for the earlier
120-window fixture); see `docs/PERFORMANCE.md` for RSS and limits. Real Accessibility
grant/window focus, installed launch-at-login,
multi-monitor/Spaces/fullscreen/Stage Manager behavior, five-minute energy/latency
traces, Developer ID signing, notarization/stapling, and Gatekeeper on a clean machine
remain explicitly pending.
