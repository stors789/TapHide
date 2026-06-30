# TODO

## High Priority

- Fix the build pipeline so `./build.sh` reliably produces `.build/DockToggle.app`.
- Make event tap startup deterministic instead of relying on a short sleep before checking tap state.
- Validate cached Dock icon hits with live AX hit testing before swallowing clicks.
- Fix Dock coordinate handling for multiple displays and non-primary Dock placement.
- Fix the icon export pipeline. The current "Focus Then Hide" source artwork is clear, but the resized iconset/`.icns` output appears blurry at app-icon sizes.
- Test DockToggle across Dock positions: bottom, left, and right.
- Test with Dock magnification enabled and disabled.
- Verify behavior with multiple displays and different primary-display settings.
- Exercise common edge cases: full-screen apps, minimized-only apps, apps with no normal windows, and apps with helper processes.

## Medium Priority

- Sync Launch at Login UI from the real `SMAppService.mainApp.status`.
- Make the Settings window resizable or scrollable so diagnostics cannot clip controls.
- Add a diagnostic export button that copies recent logs and permission state into a support bundle.
- Replace duplicated PID extraction helpers in `DockInspector` and `DockIconCache` with one shared resolver.
- Decide whether `DecisionEngine` should be removed or revived as a fallback path.

## Low Priority

- Add a preference for debounce duration.
- Add a short troubleshooting screencast or GIF once behavior is stable.
