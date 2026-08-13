# TinyTaskbar

TinyTaskbar is a small, native macOS 26 utility that keeps a compact taskbar over
the bottom of each connected display. Each item represents one eligible window
reported by Accessibility and matched to a Core Graphics window. Normal windows
must be on-screen; exactly identified minimized windows and previously observed
windows from hidden applications remain available.
Clicking an item activates, focuses, and raises its owning window.

The executable is an `LSUIElement` AppKit application with no Dock icon during
normal taskbar operation, no helper, updater, analytics, thumbnail capture, or
third-party runtime dependency. It includes one small native onboarding/settings
window for Accessibility, launch-at-login, click behavior, ordering, labels,
button width, overflow behavior, bar size, multi-display behavior, and application
lists; there is no SwiftUI or general-purpose settings framework.

A permanent native menu-bar item can show or hide all taskbars, open Settings, or
quit even when Accessibility access is unavailable. Taskbar visibility is not
persisted. Window buttons support explicit restore/minimize, Minimize All across the
current Space, Option-click Minimize Others on the same display, middle-click semantic
Close, and complete native context menus. Frequently used window actions stay in the
main menu with Close at its bottom edge; TinyTaskbar preferences and Quit are isolated
in a submenu. Applications can be pinned as icon-only launchers or excluded
by stable identity; both lists are managed from the Applications sheet.

While Settings is visible, the app temporarily uses the regular activation policy so
WindowServer will present the normal window; macOS may show a Dock icon during that
interval. Closing Settings restores accessory mode and removes the temporary Dock
presence.

## Build and test

The package targets macOS 26 and is intended for Xcode 26.6 / Swift 6.3.3:

```sh
swift test --disable-sandbox
swift build --disable-sandbox
swift build --disable-sandbox -c release
pre-commit run --all-files
bash scripts/test-build-app-rollback.sh
```

The local package tests cover eligibility, malformed input isolation, exact minimized
and hidden window identity, conservative Core Graphics matching, one-to-one AX/CG assignment and activation keys, display
intersection/tie/fallback mapping, Dock-aware panel frames, stable ordering,
deduplication, lifecycle transitions including open/move/minimize/restore/close,
preference migration and corruption recovery, pin/exclusion conflicts, grouped
ordering, launchers, pointer command scope, compact/icon-only geometry, injected
permission/window providers, shrink-before-scroll overflow, automatic icon-only
fallback, multi-display presentation policies, and the 120-window projection path. They do
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
running without taskbars and does not automatically request TCC access. Closing the
window records onboarding completion without quitting the utility.

The same window offers public `SMAppService.mainApp` launch-at-login control and
small typed preferences for active-window clicks, ordering, labels, button width,
overflow behavior, bar size, and multi-display behavior.
Every window button, including icon-only and truncated labels, shows a native hover
card with its app icon and full wrapping title after a short delay. Full
accessibility labels remain available independently. Invalid enum values use retained
defaults, while corrupt pin/exclusion records are discarded individually.

TinyTaskbar does not request Screen Recording. Window titles come from AX; Core
Graphics is used only for owner, layer, on-screen, title, geometry, and numeric
window metadata. No thumbnails or window content are captured. One deliberately
isolated private Accessibility bridge, `_AXUIElementGetWindow`, associates an AX
window with that numeric Core Graphics identity so windows already minimized when
TinyTaskbar starts can be restored without title/frame guesses. No private Space
management APIs are used.

## Important macOS boundaries

The current Space is represented conservatively by on-screen records from public
`CGWindowListCopyWindowInfo(.optionAll, ...)` metadata. Non-minimized off-screen
records remain excluded unless AX identifies them as minimized. Minimized windows may
match their exact `_AXUIElementGetWindow` identity in that list, including at cold
start. Windows from an application hidden after discovery are retained from positive
prior on-screen evidence; hidden off-screen records are not promoted at cold start.
macOS
does not expose a reliable public arbitrary-window Space ID, and the deprecated Core
Graphics workspace key is intentionally not used; exact cross-Space membership is
not attempted.

The bar is an overlay because a third-party `NSPanel` cannot reserve screen work
area like the Dock. When a normal window spans the full native work-area height,
TinyTaskbar uses Accessibility to shorten that window by the current bar height while
preserving its horizontal tile. This covers native maximize plus Rectangle/Raycast-style
left, right, and fractional layouts. Corrections are rechecked with bounded retries and
each write preserves the latest live width, so a window manager finishing its tile a
moment later cannot permanently overwrite TinyTaskbar's height correction. It updates
the constraint when density changes,
restores the original size when taskbars are hidden or TinyTaskbar quits, and
relinquishes ownership after a manual resize. Full-display fullscreen geometry is not
resized. Other manually positioned windows can still extend behind the overlay. Panels
use each screen's full and visible AppKit
frames: a bottom Dock lifts the bar exactly to the visible-frame boundary, while a
side Dock trims its horizontal span without changing its vertical position. There is
no additional floating outer margin.
A per-display panel uses public AppKit collection behavior for all Spaces,
fullscreen auxiliary participation, and Stage Manager/system-overlay joining;
real-machine behavior still needs validation. Settings can keep windows on their owning
display, mirror all current-Space windows on every display, or show one taskbar with all
windows on the main display.

App-provided AX metadata and notifications can be missing or malformed. A failing
application or window is skipped and revisited on later system events. Hidden
applications remain as dimmed taskbar items and are unhidden before activation.
Exactly identified minimized windows also appear as dimmed taskbar items and restore
on click, including after a TinyTaskbar restart; AX-only native tab
siblings are not promoted through title/frame guesses. Stage Manager background sets
are therefore omitted; fullscreen windows are included when Core Graphics reports
them on-screen.

## Evidence status

Validated for the earlier baseline in the local checkout: debug and release package
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

The retained-feature implementation has 87 passing automated tests in this checkout.
Computer QA on its deterministic fixtures verified the expanded context and launcher
menus, pin/exclude/restore/unpin flows, closed pinned launchers, failed-launch pin
retention, live Settings summaries, the scrollable Applications sheet, grouped
ordering, compact icon-only rendering, stable numeric overflow ordering, and explicit
sheet dismissal. Its menu-bar control, modifier/middle-click behavior, real app
launch/move behavior, multi-display topology, and real Accessibility behavior still
require the manual matrix before release claims are updated.
