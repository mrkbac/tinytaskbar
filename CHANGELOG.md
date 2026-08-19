# Changelog

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
