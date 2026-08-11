# Release and validation

TinyTaskbar has repository metadata for source history, but no updater, helper, or
analytics. Its typed preferences include a one-time compatibility migration from
the legacy window-title toggle. Its minimal launch-at-login preference uses
`SMAppService.mainApp`; there is no helper or separate login-item target. Version
and build numbers live in `Resources/Info.plist`:

* `CFBundleShortVersionString`: user-visible semantic version, currently `1.0.0`.
* `CFBundleVersion`: monotonically increasing build number, currently `1`.

## Local structural build

```sh
swift test --disable-sandbox
swift build --disable-sandbox
swift build --disable-sandbox -c release
pre-commit run --all-files
bash scripts/build-app.sh --adhoc
codesign --verify --deep --strict --verbose=2 dist/TinyTaskbar.app
plutil -lint dist/TinyTaskbar.app/Contents/Info.plist
```

The ad-hoc path is suitable for local bundle structure and launch experiments. It
is not a distribution signature and cannot establish notarization or Gatekeeper
acceptance.

For repeated installed Accessibility testing, create and reuse the local-only
signing identity instead:

```sh
bash scripts/setup-local-signing.sh
bash scripts/build-app.sh
```

The setup script is idempotent, imports the private key into the user's login
keychain, grants key access only to `/usr/bin/codesign`, and adds a user-domain trust
entry limited to the Code Signing policy for that certificate. The resulting stable
designated requirement lets macOS recognize rebuilt versions as the same local app.
It does not add system-wide, TLS, or unrestricted trust and must never replace
Developer ID signing for a distributed build.
Passing `--local` selects the same mode explicitly; `--adhoc` remains available for
structural tests that do not access privacy-protected resources.

`build-app.sh` performs the selected Swift build before resolving the executable
path. Its default is Release; Debug is available only for local fixture QA:

```sh
bash scripts/build-app.sh --adhoc --configuration debug \
  --output dist/TinyTaskbar-Debug.app
```

The debug fixture is not a production feature and does not provide real window or
Accessibility evidence.

## Developer ID distribution

1. Bump both plist values deliberately and record the change in the release note.
2. Confirm the exact `Developer ID Application` identity with
   `security find-identity -v -p codesigning`.
3. Assemble with `bash scripts/build-app.sh --identity "<identity>"`. The script
   builds into a fresh staging bundle before replacing the destination, enables
   Hardened Runtime, adds a secure timestamp, uses only the empty/minimal
   entitlements file, and verifies both the staged and final result.
   `bash scripts/test-build-app-rollback.sh` fault-injects a final-verification
   failure and proves that the previous destination bundle is restored.
4. Create a DMG with `bash scripts/package-dmg.sh`. This stages the app beside an
   Applications shortcut for drag-to-install and performs no hidden network work.
5. Store notarization credentials in a named keychain profile using Apple’s
   `notarytool` setup. Never put an Apple ID password, app-specific password, or
   API private key in this workspace or command history.
6. Submit, wait, staple, validate, and run Gatekeeper checks through:

   ```sh
   bash scripts/notarize.sh --profile "<keychain-profile>" --artifact dist/TinyTaskbar.dmg
   ```

   A ZIP may be submitted when a service requires it, but ZIP files cannot be
   stapled. In that case pass `--staple` with the original `.app` or `.dmg` path.

7. On a clean macOS 26 machine, install from the DMG, launch, grant Accessibility,
   exercise the manual matrix, inspect the crash-log location, and uninstall by
   quitting and moving the app bundle to Trash.

Apple’s notary service requires a valid Developer ID signature, Hardened Runtime,
and a secure timestamp. The local ad-hoc verification does not establish any of
those distribution claims.

## Support and recovery notes

* Crash reports: `~/Library/Logs/DiagnosticReports/`.
* Uninstall: quit TinyTaskbar, move `TinyTaskbar.app` to Trash, and remove any
  manually copied bundle.
* Reset only this app’s Accessibility TCC decision when explicitly needed:

  ```sh
  tccutil reset Accessibility com.tinytaskbar.TinyTaskbar
  ```

  This is a destructive permission reset and is not part of automated validation.
* Re-test launch/onboarding/reopen behavior, permission denial and grant,
  close-without-quit, clean-machine installation, launch-at-login approval, and all
  multi-display/Space/fullscreen/Stage Manager cases after each release-signing or
  macOS update.

Developer ID identity availability, Apple notarization, stapling, Gatekeeper,
clean-machine installation, and real-machine behavior remain pending until their
respective evidence is collected.
