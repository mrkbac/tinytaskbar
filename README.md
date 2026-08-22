# TinyTaskbar

**A native macOS taskbar with one stable button per window, on the display where it
lives.**

TinyTaskbar keeps every window one click away in a fixed 30-point bar—without
thumbnails, visual clutter, or a browser runtime.

<p align="center">
  <img src="docs/demo.gif" alt="TinyTaskbar focusing and minimizing synthetic windows without moving their buttons" width="960">
</p>
<p align="center">
  <sub>Focus and minimize without reordering or resizing the taskbar.</sub>
</p>

## What it does

- **One button per window** — titles, native app icons, minimized state, attention,
  and Dock badges.
- **Stable geometry** — balanced buttons keep their identity and order; crowded bars
  shrink, then scroll horizontally.
- **Direct control** — click to focus or restore; click the focused window to
  minimize; hover or right-click for close and supported New Window actions.
- **Display-aware** — windows appear only on their physical display, and only the
  display occupied by a fullscreen window hides its taskbar.
- **Quiet system integration** — stays out of Mission Control, remains attached to
  its Space, and can launch at login.
- **Optional Dock replacement** — keep the Mac Dock fully hidden while TinyTaskbar
  runs, with its previous settings restored on quit.

| Action | Result |
| --- | --- |
| Click a window | Focus or restore it |
| Click the focused window | Minimize it |
| Hover | Show its full title and available tab or close actions |
| Right-click | Open a new app window when supported, or minimize, restore, and close |

Settings and Quit live only in the menu-bar icon.

## Install

TinyTaskbar requires macOS 26. Releases are universal for Apple silicon and Intel.

### Homebrew

```sh
brew install --cask mrkbac/tap/tinytaskbar
```

### Direct download

Download the latest DMG from [Releases](https://github.com/mrkbac/tinytaskbar/releases/latest),
drag TinyTaskbar to Applications, and open it.

TinyTaskbar is distributed without an Apple Developer ID certificate. If macOS blocks
the first launch, follow the safe [Open Anyway instructions](docs/INSTALL_UNSIGNED.md).

## Permissions and privacy

TinyTaskbar runs entirely on your Mac with no network requests, analytics, telemetry,
Screen Recording permission, thumbnails, or capture of window contents. Accessibility
is used only to list and control windows. One isolated private Accessibility function
preserves exact minimized-window identity.

## Build

Requires Xcode 26.6 with Swift 6.3.3.

```sh
swift test --disable-sandbox
bash scripts/build-app.sh --adhoc
```

## License

[GPL-3.0-only](LICENSE)
