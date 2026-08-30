# Changelog

## Unreleased

- Raise an exact window after a 500 ms drag-hover over its taskbar button, without
  inspecting or accepting the dragged content.
- Preserve the current Window Server order when minimizing an active window, skipping
  same-application siblings so repeated toggles do not expose an unrelated window.
- Keep window context menus full-height and anchored to the right-click location at
  the bottom edge of the screen.
- Add Enter/Exit Full Screen beside Minimize when the exact window exposes the
  `AXFullScreen` Accessibility attribute; keep read-only attributes visible but disabled.
- Show a draggable native document proxy in a hover card only when its exact window
  exposes an existing local file through `AXDocument`; keep the source alive for the
  complete gesture and publish the file through macOS's native copy-only URL writer so
  sandboxed drop targets can access it.
- Restore exactly identified hidden application windows after TinyTaskbar starts,
  without admitting ambiguous off-screen records.
- Align the top separator with the taskbar edge while preserving the opaque pointer
  seam that blocks neighboring window resize cursors.
- Show each application's own labels for its Command-N, Command-Shift-N, and
  Command-T menu actions, including localized labels, while continuing to reject
  disabled, non-actionable, and ambiguous shortcuts.

## 1.3.0

- Added a capability-gated New Window command to window context menus. TinyTaskbar
  shows it only when the selected application exposes one enabled, unambiguous
  Accessibility action.
- Kept the command application-scoped and refreshed window discovery after execution,
  so every newly created physical window receives its own stable taskbar button.

## 1.2.0

- Kept taskbar panels out of Mission Control while preserving their display and Space
  attachment.
- Reduced idle and focus-change work with more selective, event-driven Accessibility
  refreshes.
- Simplified TinyTaskbar to one fixed standard layout: window titles, balanced
  buttons, shrink-then-scroll overflow, and physical-display ownership.
- Active-window clicks now always minimize, and the menu-bar Hide Taskbars command
  has been removed.
- Replaced the multi-section settings sidebar with one polished compact settings
  page for Accessibility, launch-at-login, and Dock controls.
- Removed pinned launchers, application exclusions, broad minimize commands,
  middle-click Close, and taskbar-level Settings/Quit shortcuts. Window context
  menus now contain only Minimize/Restore and Close; Settings and Quit remain in
  the menu-bar item.

## 1.1.0

- Added high-visibility orange attention indicators that pulse without moving or
  resizing taskbar items and remain static when Reduce Motion is enabled.
- Added compact Dock badge labels, shown once per application across running windows
  and pinned launchers.
- Release builds are now universal binaries for Apple silicon and Intel Macs.
