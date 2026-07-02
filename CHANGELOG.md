# Changelog

All notable changes to TapHide are tracked here.

## 2.0.0 (2026-07-02)

### Changed
- **Project Renamed**: DockToggle is now **TapHide**. All configurations, bundle identifiers, and log paths have been updated.

### Fixed
- **Critical Fix**: Fixed an issue where the app was unable to correctly cast `AXURL` to `URL` on macOS 14+, which caused the app to fail to identify running applications and ignore all Dock clicks.


## 1.1.0 (2026-06-19)

### Fixed

- Keep permission polling active even when the app starts before Accessibility or Input Monitoring is granted.
- Stop the event tap on its owning run loop instead of trying to remove a newly-created source from the caller's run loop.
- Refresh the cached Dock frame together with the icon cache, so Dock position and size changes are picked up while the app is running.
- Ignore protected Dock/Finder targets instead of trying to hide or minimize them.
- Report launch-at-login registration failures in the app status and debug log instead of silently swallowing them.

### Changed

- Move debug logs from `/tmp/taphide.log` to `~/Library/Logs/TapHide/taphide.log`.
- Add log rotation at roughly 1 MB.
- Expand Settings with status text plus refresh, clear, and reveal-log actions.
- Document current limitations, log prefixes, and maintenance workflow.
- Design a new minimalist application icon representing the action of hiding/sliding down the macOS Dock, featuring a clean, flat aesthetic that fits perfectly with macOS design guidelines.

## 1.0.0

- Initial menu bar app with hide/minimize behavior for repeated clicks on the active Dock app icon.
- Universal binary build script for Apple Silicon and Intel Macs.
