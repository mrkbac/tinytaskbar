# Installing the unsigned build

TinyTaskbar is currently distributed without an Apple Developer ID certificate. The
app is ad-hoc signed for bundle integrity, but it is not identified or notarized by
Apple. macOS will block its first launch by default.

Only continue if you intended to download TinyTaskbar from its official GitHub
release and the artifact checksum matches that release.

## Install

TinyTaskbar requires macOS 26 or newer.

With the project Homebrew tap:

```sh
brew trust --tap mrkbac/tap
brew install --cask mrkbac/tap/tinytaskbar
```

Alternatively, download the latest DMG from GitHub Releases, open it, and drag
TinyTaskbar to Applications.

For a direct download, verify the disk image before opening it:

```sh
shasum -a 256 /path/to/downloaded.dmg
```

Compare the complete result with the SHA-256 checksum published alongside the
download. Stop if no checksum is published or if it differs.

## Allow the first launch

1. Open TinyTaskbar once and let macOS block it.
2. Open **System Settings → Privacy & Security**.
3. In the Security section, click **Open Anyway** for TinyTaskbar.
4. Authenticate, confirm **Open**, and launch TinyTaskbar again.

Apple documents this as a per-app exception. The button is available for about one
hour after the blocked launch. See
[Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac).

Do not disable Gatekeeper or System Integrity Protection. TinyTaskbar does not require
`spctl --master-disable`, quarantine-removal commands, or reduced system-wide security.
Do not override an alert saying the app contains malware or has been damaged; instead,
delete the artifact and report the exact release filename and checksum.

## Grant Accessibility

TinyTaskbar needs Accessibility permission to enumerate and control windows. After it
opens, use its Settings window to open **Privacy & Security → Accessibility**, enable
TinyTaskbar, and return to the app.

Because the distributed app has no stable Apple-issued identity, an update may require
the Open Anyway step and Accessibility approval again. If window controls stop working
after an upgrade, remove the old TinyTaskbar entry from Accessibility, add or enable the
installed app again, and relaunch it.

## Uninstall

Disable **Launch at Login** and **Fully hide the Mac Dock** in TinyTaskbar, then quit it.
For a Homebrew installation:

```sh
brew uninstall --cask tinytaskbar
```

For a manual installation, move `TinyTaskbar.app` from Applications to Trash.
