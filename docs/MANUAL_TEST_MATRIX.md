# Manual test matrix

These cases require a real interactive macOS 26 session. They are not claimed as
executed by the automated package checks.

| ID | Setup | Action | Expected evidence | Status |
| --- | --- | --- | --- | --- |
| M1 | Fresh app launch, Accessibility off | Launch `TinyTaskbar.app`; inspect the retained guide | Native onboarding/settings window is visible and key/front; status is Required; no automatic TCC request; no taskbar while denied | Pass — local Computer QA, 2026-08-07 |
| M2 | Guide visible, Accessibility off | Click Enable Accessibility… / Open Accessibility Settings…; grant in Privacy & Security; return to TinyTaskbar | Settings row changes to Granted; taskbars appear after event-driven recheck; no repeated prompt | Pending |
| M3 | One display, two normal windows | Move, resize, rename, minimize, restore, close | One short event-driven refresh; minimized items remain available for restore; items follow title state | Mocked lifecycle and native Close-menu pass; real-window pass pending |
| M4 | One app with two windows | Focus each window and click each item twice | First click activates and raises without reordering; clicking the active item minimizes it; clicking its retained item restores it | Mocked stable-switching/toggle pass; real-window pass pending |
| M5 | Two connected displays, windows straddling boundary | Open and move windows across displays | Greatest intersection assignment; deterministic tie; one panel per display | Pending |
| M6 | Multiple Spaces | Switch Spaces and move windows | Only current-Space on-screen CG windows appear; other-Space windows are omitted | Pending |
| M7 | Native fullscreen window | Enter and exit fullscreen | Fullscreen window appears when CG reports it; panel behavior is observed and recorded | Pending |
| M8 | Stage Manager enabled | Switch active/background app sets | Only CG on-screen windows appear; background sets are omitted | Pending |
| M9 | Accessibility-denied or malformed app | Revoke/deny access or use an app that rejects AX values | Affected app is skipped; process remains alive; later system event retries | Pending |
| M10 | Long titles and many windows | Open enough windows to overflow | App icon, full accessibility label/tooltip, 180-point title cap with tail truncation, horizontal scrolling, and active state are usable | Mocked pass with 120-window fixture; real-app pass pending |
| M11 | Activity Monitor/Instruments | Leave idle for 5 minutes, then interact | Record CPU, RSS, wakeups, refresh latency, click-to-focus latency against provisional budgets | Partial — five-minute mocked-AppKit CPU/memory/context-switch soak passed; real-AX wakeups/latency pending |
| M12 | Clean macOS 26 machine | Install signed/notarized DMG and launch | Gatekeeper accepts; launch, permission, uninstall, and crash-log paths work | Pending |
| M13 | TinyTaskbar already running | Relaunch/open the app; close Settings with X; reopen it | The retained Settings window shows on relaunch; a temporary Dock icon may appear only while Settings is visible; X hides it without quitting the process or removing taskbars | Pass — release denied flow and DEBUG taskbar flow, 2026-08-07 |
| M14 | Settings window visible with taskbars | Toggle Show Window Titles and Launch at Login; reopen Settings | Button text changes immediately without window re-enumeration; icons/full labels/tooltips remain; login status/error is inline and accurate | Partial — title toggle/reopen pass; installed-app login registration pending |
| M15 | Debug ad-hoc bundle, no Accessibility grant | Launch `dist/TinyTaskbar-Debug.app/Contents/MacOS/TinyTaskbar --ui-test-fixture=normal` | Real taskbar panels and item views appear without a TCC request; left-click switches without opening a menu; right-click Close removes only its fixture item; no permission prerequisite | Pass — Computer QA, 2026-08-08 |
| M16 | Debug fixture bundle | Repeat with `--ui-test-fixture=overflow` and `--ui-test-fixture=empty` | Overflow exercises horizontal scrolling and compact labels; empty renders no items safely; neither fixture calls AX/TCC | Pass — Computer QA, including horizontal scroll, 2026-08-07 |
| M17 | Debug fixture on a display with a bottom or side Dock | Launch the normal or overflow fixture and inspect panel placement | Bottom Dock leaves the configured visible-frame inset; side Dock trims the panel horizontally without lifting it; record display arrangement and screenshot | Pending real Dock-layout QA |

The debug fixture cases are mocked-E2E coverage of the real AppKit surface and
projection/layout path, not evidence of Accessibility, window discovery,
multi-monitor, Spaces, fullscreen, Stage Manager, or click-to-focus behavior for
real applications. Automated provider and reducer tests cover denied startup,
permission transitions, malformed snapshots, and stale activation without changing
TCC.

The 2026-08-07 and 2026-08-08 Computer runs also verified the native 640 × 340 Settings layout in
denied and mocked-granted states, leading-aligned rows at both accessory widths,
close-without-quit, relaunch/reopen, title-on/title-off rendering, full accessibility
labels/tooltips, neutral active styling, stable fixture activation without button
reordering, the one-command native Close menu with its system symbol, 120-window horizontal scrolling, and
an empty item list. Show Window Titles was restored to on afterward.
No Accessibility prompt/grant, real-window focus, installed launch-at-login
registration, multi-display topology, Space, fullscreen, or Stage Manager state was
changed during these checks.

The active test record should include macOS build, hardware, display arrangement,
Space/Stage Manager state, app build number, Accessibility state, timestamps, and
screenshots or Instruments traces. Do not convert an unexecuted case to Pass from
source inspection alone.
