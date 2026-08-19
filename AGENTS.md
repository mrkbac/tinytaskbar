# TinyTaskbar

TinyTaskbar is a native macOS taskbar with one stable button per window, on every
display. It is intentionally small: Swift Package Manager, Swift 6, AppKit,
Accessibility, Core Graphics, Service Management, and no third-party dependencies.

## Platform posture

- Target macOS 26 and the toolchain documented in `README.md` and `Package.swift`.
- Prefer current native Apple APIs and Swift concurrency. Do not add compatibility
  layers, browser runtimes, or legacy fallbacks unless the task explicitly requires
  them.
- Keep window discovery and taskbar refresh AppKit-native, compact,
  fixed-geometry, and event-driven. Do not introduce repeating refresh timers or
  window-enumeration polling loops.
- Keep the app local and private: no network access, analytics, telemetry, Screen
  Recording, thumbnails, or capture of window contents.

## Repository map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | macOS target, executable/test targets, frameworks, Swift language mode |
| `Sources/TinyTaskbar/AppEntry.swift` | application entry point, composition, lifecycle, panel ownership |
| `Sources/TinyTaskbar/AXInterop.swift` | Accessibility permission, AX/CG snapshots, observers, and window actions |
| `Sources/TinyTaskbar/WindowModel.swift` | window/display models, matching, projection, layout, ordering, lifecycle reducers |
| `Sources/TinyTaskbar/FeatureModel.swift` | preferences, presentation entries, and semantic commands |
| `Sources/TinyTaskbar/Runtime.swift` | state continuity, store, settings, event observers, panels, and taskbar views |
| `Sources/TinyTaskbar/ApplicationIndicators.swift` | application attention and Dock badge observation |
| `Sources/TinyTaskbar/DockVisibility.swift` | reversible Dock preference management |
| `Sources/TinyTaskbar/DebugFixture.swift` | deterministic DEBUG-only UI fixtures that do not require TCC |
| `Tests/TinyTaskbarTests/` | Swift Testing coverage for models, permissions, runtime, UI behavior, and packaging helpers |
| `Resources/` | bundle metadata, entitlements, and app icon |
| `scripts/` | rollback-safe app assembly, signing, DMG packaging, and notarization |

## Non-negotiable behavior

- One physical window produces at most one taskbar item. Resolve an action by exact
  item ID, then only by a unique `(PID, CG window number)` match. Never promote,
  minimize, close, or otherwise act on sibling windows merely because they belong to
  the same application.
- Treat AX and Core Graphics as evidence, not perfectly synchronized truth. An
  incomplete or failed AX read is inconclusive; do not turn a transient omission into
  a disappearance. A completed active-Space transition may invalidate AX-only items.
- Preserve stable item identity, ordering, button instances, and frames across focus,
  title, badge, and attention changes. Express visual state with drawing/layers rather
  than constraint or intrinsic-size churn.
- Keep panels attached to the Space where they were created. Preserve the per-display,
  per-Space panel cache so an interactive Space swipe can show the correct taskbar on
  both sides.
- Keep window discovery and refresh event-driven and coalesced. New event sources must
  have explicit start/stop ownership and be torn down during termination.
- Keep the normal taskbar edge-to-edge and tiny. Geometry changes must cover the fixed
  standard layout, overflow, multiple displays, the bottom-edge hit target, and first
  layout.
- Hide taskbars on displays occupied by fullscreen windows and keep published work
  areas synchronized with the panels that are actually visible.
- Dock hiding must remain reversible. Preserve the original preference snapshot,
  restore it on shutdown or failure, and never leave a partial defaults write behind.
- `@MainActor` owns AppKit, Accessibility interaction, and long-lived runtime state.
  Pure model values crossing concurrency boundaries remain concrete and `Sendable`.

## Private API boundary

`AXInterop.swift` contains one deliberately isolated declaration of
`_AXUIElementGetWindow`. It exists only to preserve exact identity for minimized
windows, where public Accessibility has no AX-to-CG bridge.

- Do not add more private AX, CGS, SkyLight, or Space-management APIs.
- Do not spread this symbol behind a generic abstraction or call it outside the
  snapshot provider.
- Keep all Space behavior, window actions, and UI behavior on public APIs.
- Any change to this boundary requires focused identity regressions and an explicit
  compatibility/release-risk note.

## Change discipline

- Inspect the working tree first and preserve unrelated changes and artifacts.
- Make the smallest coherent change. Do not add app-specific hacks or weaken identity
  rules to accommodate one observed application.
- Put deterministic decisions in model helpers and cover them with Swift Testing.
  Keep side-effecting AppKit/AX code thin and dependency-injected where practical.
- A bug fix needs a regression test that fails for the reported event order or evidence
  shape. Exercise failure and inconclusive paths as well as the happy path.
- Use the DEBUG fixtures for visual or interaction work:
  `--ui-test-fixture=normal|overflow|empty`, plus `--ui-test-indicators` when relevant.
  These flags must remain absent from Release.
- Comments should explain a non-obvious reason or invariant. Prefer a well-named type,
  function, or test over narration of what the code does.
- If behavior, permissions, installation, or release expectations change, update the
  relevant user-facing documentation in the same change.

## Verification

Run the narrowest relevant tests while iterating, then finish Swift changes with:

```sh
swift test --disable-sandbox
swift build --disable-sandbox -c release
pre-commit run --all-files
git diff --check
```

For a scoped edit, `pre-commit run --files <changed-files>` is suitable during
iteration. Inspect the diff after hooks because the formatter runs in place.

Packaging is a separate gate:

```sh
bash scripts/build-app.sh --adhoc --configuration release --architecture universal
bash scripts/package-dmg.sh
```

## Release workflow

A release requires explicit user approval. Once approved, complete the release rather
than stopping at a local artifact:

1. Add a concise `CHANGELOG.md` section named `## X.Y.Z`, set the same
   `CFBundleShortVersionString` in `Resources/Info.plist`, commit, push `main`, and
   wait for CI to pass.
2. Trigger the `Release` workflow on `main` with the version without a `v` prefix:

   ```sh
   gh workflow run release.yml --repo mrkbac/tinytaskbar --ref main \
     -f version=X.Y.Z
   ```

3. Wait for the workflow to succeed and verify that release `vX.Y.Z` contains
   `TinyTaskbar-X.Y.Z.dmg` and `SHA256SUMS.txt`. The workflow is the sole publisher:
   it builds the universal ad-hoc-signed app, verifies both architectures, packages
   the DMG, calculates its checksum, and creates the GitHub release.
4. Update only `version` and `sha256` in
   `mrkbac/homebrew-tap/Casks/tinytaskbar.rb`, using the checksum from the published
   release. Run `brew style --cask`, `brew audit --cask --strict --online`, and
   `brew fetch --cask mrkbac/tap/tinytaskbar`, then commit and push the tap.
5. Verify the public release, latest-release redirect, tap contents, and documented
   install command: `brew install --cask mrkbac/tap/tinytaskbar`.

Do not upload locally built binaries, add release automation to the Homebrew tap,
rewrite a published tag, or claim notarization. Keep the tap to its README and cask.

Do not install into `/Applications`, change Dock preferences, request Accessibility,
sign with a persistent identity, notarize, publish, or launch a release workflow unless
the task explicitly asks for that side effect.

Report evidence precisely. Unit tests, compilation, bundle assembly, code signing,
notarization/Gatekeeper, Accessibility/TCC, clean-machine launch, and real multi-display
or Space behavior are separate claims. Never present one as proof of another.

## Reference posture

- Tinycast is a useful reference for latest-platform discipline, explicit invariants,
  repository orientation, and a concrete definition of done.
- Switch is a useful product and interaction reference. Its MRU ordering, thumbnails,
  cross-Space behavior, private SPI, and Screen Recording posture are not TinyTaskbar
  defaults and must not be imported incidentally.
- Treat external repositories as behavioral inspiration. Do not copy source across
  incompatible licenses or adopt an architectural choice without validating it against
  TinyTaskbar's constraints above.
