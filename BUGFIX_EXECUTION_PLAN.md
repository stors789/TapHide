# DockToggle Bugfix Execution Plan

This document consolidates the review findings from the Codex subagents and the local analyzer report at `/Users/eros/.gemini/antigravity/brain/a8fec585-22ce-42cf-8ba8-25026db0c1d5/analysis_report.md`.

## Current Verification

- `Resources/Info.plist` is syntactically valid according to the packaging subagent.
- `./build.sh` currently fails in this environment.
- The blocking build error is SwiftUI macro resolution: direct `swiftc` compilation cannot find `SwiftUIMacros.StateMacro`, so `@State` does not expand in `Sources/SettingsView.swift`.
- The build script also has a fallback bug: `ARCH_BINS` records target paths before successful compilation, so cross-architecture failures do not reliably fall back to native-only output.

## Priority 0: Build Must Succeed

### Findings

1. Direct `swiftc` build cannot resolve SwiftUI macros.
   - Files: `build.sh`, `Sources/SettingsView.swift`
   - Trigger: running `./build.sh` with the current Command Line Tools setup.
   - Impact: no app bundle is produced.

2. Native-only fallback in `build.sh` is broken.
   - Files: `build.sh`
   - Trigger: one architecture target fails but another target succeeds.
   - Impact: the script can still exit with `No binaries were compiled successfully`.

### Recommended Fix

- Prefer creating a minimal Swift Package or Xcode project build path that lets the Swift driver discover required SwiftUI macro plugins.
- If keeping `build.sh`, only append a binary to `ARCH_BINS` after `swiftc` succeeds, or filter `ARCH_BINS` to existing files before `lipo`.
- Keep the app bundle layout and ad-hoc signing behavior unchanged unless the new build path replaces it cleanly.

## Priority 1: Event Tap Lifecycle And Thread Safety

### Findings

1. `EventTapEngine` state is read and written across threads without a single synchronization boundary.
   - Files: `Sources/Engine/EventTapEngine.swift`, `Sources/DockToggleApp.swift`
   - State involved: `eventTap`, `runLoop`, `runLoopSource`, `isRunning`
   - Trigger: startup, permission recovery, timer checks, app termination, secure input, event tap auto-disable.
   - Impact: UI can show `Tap creation failed` while the tap is actually running, or stop logic can race with the event tap run loop.

2. Startup relies on `Thread.sleep(forTimeInterval: 0.05)`.
   - File: `Sources/DockToggleApp.swift`
   - Trigger: slow event tap creation or delayed thread scheduling.
   - Impact: false startup failure and split app state.

3. Mouse-up swallow state is coordinated through a main-thread timer while the tap callback runs on the event tap thread.
   - File: `Sources/Engine/EventTapEngine.swift`
   - Trigger: main thread stalls during the 0.5 second timer window.
   - Impact: delayed or incorrect mouse-up swallowing.

### Recommended Fix

- Make event tap lifecycle state thread-safe with a serial queue, lock, or actor-compatible wrapper.
- Replace the fixed sleep with a deterministic startup completion signal.
- Keep event tap callback work fast and avoid main-thread dependence for state needed by the callback.
- Consider replacing the mouse-up timer with a timestamp checked directly on the tap thread.

## Priority 2: Dock Target Identification Correctness

### Findings

1. Cached Dock icon hit testing can be wrong after Dock layout changes.
   - Files: `Sources/Engine/EventTapEngine.swift`, `Sources/Engine/DockIconCache.swift`
   - Trigger: Dock magnification, icon reorder, Dock size change, orientation change, stale cache, failed cache refresh.
   - Impact: clicking a different Dock icon can be misread as clicking the frontmost app, causing DockToggle to swallow the click and hide or minimize the wrong app.

2. Dock magnification makes static cached frames especially unsafe.
   - Files: `Sources/Engine/EventTapEngine.swift`, `Sources/Engine/DockIconCache.swift`
   - Trigger: `com.apple.dock` magnification enabled and pointer hovering near icons.
   - Impact: icon frames shift under the pointer while the cache still reflects the resting layout.

3. `localizedName` matching is too permissive.
   - File: `Sources/Engine/EventTapEngine.swift`
   - Trigger: helper processes, two apps with the same localized name, fuzzy extraction returning a nearby app.
   - Impact: false same-app decisions.

4. `DockInspector` does not re-resolve the Dock after Dock process restart.
   - File: `Sources/Engine/DockInspector.swift`
   - Trigger: `killall Dock`, Dock crash/restart, system setting changes that restart Dock.
   - Impact: stale `dockPID` and stale AX element break direct identification.

5. Locale-sensitive fallback matching can miss apps.
   - File: `Sources/Engine/DockAppExtractor.swift`
   - Trigger: app name parsed from `.app` path does not match localized running app name.
   - Impact: target PID cannot be found, or a fuzzy match is used instead.

### Recommended Fix

- Treat live AX hit testing as authoritative before swallowing a click.
- Use `DockIconCache` only as a fast path that is verified before action, or as a fallback when AX hit testing fails.
- Bypass or invalidate the cache when Dock magnification is enabled.
- Clear or mark the cache invalid when refresh fails instead of keeping stale entries indefinitely.
- Remove name-only same-app matching, or require stronger evidence such as matching bundle IDs.
- Re-resolve Dock when AX calls fail or when the Dock PID changes.
- Prefer bundle ID extraction from app bundles over localized name matching.

## Priority 3: Multi-Display And Dock Geometry

### Findings

1. Coordinate conversion uses the first screen height for all screens.
   - File: `Sources/Engine/DockInspector.swift`
   - Trigger: multiple displays, different display heights, vertical display arrangement, Dock on a non-primary display.
   - Impact: Dock hotspot and cached frame comparisons can be wrong.

2. Fallback Dock geometry uses only `NSScreen.main`.
   - File: `Sources/Engine/DockInspector.swift`
   - Trigger: Dock located on another display.
   - Impact: fallback Dock frame points to the wrong edge or display.

3. Autohide fallback uses a hardcoded 100 point thickness.
   - File: `Sources/Engine/DockInspector.swift`
   - Trigger: very small Dock, fullscreen windows near the Dock edge, unusual Dock size settings.
   - Impact: the app may treat non-Dock edge clicks as Dock clicks.

### Recommended Fix

- Use a single coordinate system for `CGEvent.location`, screen bounds, Dock frame, and icon frames.
- Prefer CoreGraphics display bounds where possible.
- If using `NSScreen`, convert each screen with its own bounds, not the first screen.
- Compute autohide fallback size from Dock defaults such as `tilesize` and `largesize` rather than hardcoding 100.

## Priority 4: Settings, State Synchronization, And UI Polish

### Findings

1. Launch-at-login UI uses local `UserDefaults`, not the system login item status.
   - Files: `Sources/DockToggleApp.swift`, `Sources/Settings/ConfigStore.swift`
   - Trigger: user changes login item in System Settings, app is moved, app is reinstalled, register/unregister fails.
   - Impact: UI can show the wrong state.

2. `ConfigStore` is an `ObservableObject`, but its settings are only `@AppStorage`.
   - Files: `Sources/Settings/ConfigStore.swift`, `Sources/SettingsView.swift`, `Sources/DockToggleApp.swift`
   - Trigger: changing settings from the menu bar while the settings window is open, or vice versa.
   - Impact: views may not refresh each other consistently.

3. Settings window can clip content.
   - Files: `Sources/SettingsWindowManager.swift`, `Sources/SettingsView.swift`
   - Trigger: diagnostics loaded by default, fixed 200 point log area, non-resizable 540 by 560 window.
   - Impact: bottom controls can be clipped.

4. Version is hardcoded incorrectly.
   - Files: `Sources/SettingsView.swift`, `Resources/Info.plist`
   - Trigger: opening settings.
   - Impact: UI shows `Version 1.0.0` while the bundle says `1.1.0`.

5. README says Dock icon cache has a 1 second refresh, but the app uses a 30 second timer plus launch/terminate/screen updates.
   - Files: `README.md`, `Sources/DockToggleApp.swift`
   - Trigger: reading project documentation.
   - Impact: maintainers debug against the wrong mental model.

### Recommended Fix

- Derive launch-at-login display state from `SMAppService.mainApp.status`.
- Either use `@AppStorage` directly in each SwiftUI view or turn `ConfigStore` into a true observable source with `@Published` properties and UserDefaults synchronization.
- Make settings content scrollable or make the window resizable.
- Read version from `Bundle.main.infoDictionary`.
- Update README to reflect the actual cache refresh behavior.

## Priority 5: Performance And Follow-Up Enhancements

### Findings

1. Synchronous AX calls can run on the main thread.
   - File: `Sources/Engine/DockInspector.swift`
   - Trigger: `cacheRefreshTimer`, screen parameter notifications, Dock under load.
   - Impact: menu bar UI can hang.

2. Permission polling runs every 2 to 30 seconds.
   - File: `Sources/DockToggleApp.swift`
   - Trigger: app lifetime.
   - Impact: unnecessary wakeups.

3. `UserDefaults` is read inside the event tap hot path.
   - File: `Sources/Engine/EventTapEngine.swift`
   - Trigger: every left mouse down.
   - Impact: small but avoidable hot-path overhead.

4. Debounce removal does not extend on repeated clicks.
   - File: `Sources/Engine/ActionExecutor.swift`
   - Trigger: rapid repeated clicks on the same app within the debounce window.
   - Impact: a later click can lose its intended debounce protection when the earlier scheduled removal fires.

5. Stage Manager detection uses an undocumented defaults key.
   - File: `Sources/Engine/EventTapEngine.swift`
   - Trigger: macOS changes the private `com.apple.WindowManager` key.
   - Impact: hide-to-minimize override can stop matching real Stage Manager behavior.

### Recommended Fix

- Move full Dock frame refresh work off the main thread.
- Reduce polling by checking permissions on app activation, menu open, or settings interactions where practical.
- Cache behavior mode, trigger modifier, and exclusion list in a thread-safe settings snapshot.
- Replace debounce set with expiration timestamps or cancellable work items.
- Treat Stage Manager detection as best-effort and log/fallback cleanly.

## Suggested Overall Order

1. Build pipeline and `build.sh` fallback.
2. Event tap lifecycle/thread safety.
3. Dock target identification and stale cache prevention.
4. Multi-display Dock geometry.
5. Settings/UI/documentation consistency.
6. Performance and follow-up reliability improvements.

## Manual Test Matrix

- Build from a clean checkout with `./build.sh`.
- Launch from `.build/DockToggle.app`.
- Grant Accessibility and Input Monitoring permissions.
- Test Dock positions: bottom, left, right.
- Test Dock magnification on and off.
- Test Dock autohide on and off.
- Test multiple displays with Dock on primary and external display.
- Test app focus then repeated Dock click in hide mode.
- Test app focus then repeated Dock click in minimize mode.
- Test Finder exclusion and Dock protection.
- Test fullscreen apps, minimized-only apps, apps without standard windows, helper-process apps, and duplicate/localized app names.
- Test `killall Dock` while DockToggle is running.
- Test Stage Manager on and off.
- Test moving Spaces or Mission Control while clicking Dock icons.
- Test Launch at Login after toggling it in DockToggle and in System Settings.
