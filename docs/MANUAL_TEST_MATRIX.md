# Manual test matrix

These cases require a real interactive macOS 26 session. They are not claimed as
executed by the automated package checks.

| ID | Setup | Action | Expected evidence | Status |
| --- | --- | --- | --- | --- |
| M1 | Fresh app launch, Accessibility off | Launch `TinyTaskbar.app` | One concise permission explanation; no repeating prompt; no taskbar while denied | Pending |
| M2 | Privacy & Security → Accessibility | Enable TinyTaskbar, relaunch | Panels appear; no Dock icon; list contains eligible windows only | Pending |
| M3 | One display, two normal windows | Move, resize, rename, minimize, restore, close | One short event-driven refresh; items follow eligibility and title state | Pending |
| M4 | One app with two windows | Focus each window and click each item | Focused/main item is active; click activates and raises the selected window | Pending |
| M5 | Two connected displays, windows straddling boundary | Open and move windows across displays | Greatest intersection assignment; deterministic tie; one panel per display | Pending |
| M6 | Multiple Spaces | Switch Spaces and move windows | Only current-Space on-screen CG windows appear; other-Space windows are omitted | Pending |
| M7 | Native fullscreen window | Enter and exit fullscreen | Fullscreen window appears when CG reports it; panel behavior is observed and recorded | Pending |
| M8 | Stage Manager enabled | Switch active/background app sets | Only CG on-screen windows appear; background sets are omitted | Pending |
| M9 | Accessibility-denied or malformed app | Revoke/deny access or use an app that rejects AX values | Affected app is skipped; process remains alive; later system event retries | Pending |
| M10 | Long titles and many windows | Open enough windows to overflow | App icon, accessibility label, truncation, horizontal scrolling, and active state are usable | Pending |
| M11 | Activity Monitor/Instruments | Leave idle for 5 minutes, then interact | Record CPU, RSS, wakeups, refresh latency, click-to-focus latency against provisional budgets | Pending |
| M12 | Clean macOS 26 machine | Install signed/notarized DMG and launch | Gatekeeper accepts; launch, permission, uninstall, and crash-log paths work | Pending |

The active test record should include macOS build, hardware, display arrangement,
Space/Stage Manager state, app build number, Accessibility state, timestamps, and
screenshots or Instruments traces. Do not convert an unexecuted case to Pass from
source inspection alone.
