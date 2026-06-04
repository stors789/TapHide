import AppKit
import ApplicationServices

final class ActionExecutor {
    static let shared = ActionExecutor()

    private var restoringPIDs: Set<pid_t> = []
    private let lock = NSLock()

    private init() {}

    func execute(targetPID: pid_t, mode: BehaviorMode) {
        switch mode {
        case .hide:
            executeHide(pid: targetPID)
        case .minimize:
            executeToggleMinimize(pid: targetPID)
        }
    }

    func isRestoring(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return restoringPIDs.contains(pid)
    }

    func markRestoring(pid: pid_t) {
        lock.lock()
        restoringPIDs.insert(pid)
        lock.unlock()

        DebugLog.shared.write("[RESTORE] debounce PID \(pid) for 400ms")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.lock.lock()
            self?.restoringPIDs.remove(pid)
            self?.lock.unlock()
            DebugLog.shared.write("[RESTORE] debounce cleared for PID \(pid)")
        }
    }

    private func executeHide(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.hide()
    }

    private func restoreAnyMinimizedWindow(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windows) == .success,
              let windowArray = windows as? [AXUIElement]
        else { return false }

        for win in windowArray {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, "AXMinimized" as CFString, &minimized) == .success,
               let isMin = minimized as? Bool, isMin {
                AXUIElementSetAttributeValue(win, "AXMinimized" as CFString, false as CFBoolean)
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate()
                }
                DebugLog.shared.write("[MINIMIZE] restored minimized window for PID \(pid)")
                return true
            }
        }
        return false
    }

    private func executeToggleMinimize(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            "AXFocusedWindow" as CFString,
            &window
        ) == .success,
              let windowElement = window as! AXUIElement?
        else {
            // No focused window (e.g. just minimized). Try restoring any minimized window.
            DebugLog.shared.write("[MINIMIZE] no focused window for PID \(pid)")
            if !restoreAnyMinimizedWindow(pid: pid) {
                DebugLog.shared.write("[MINIMIZE] fallback to hide (no focused window) for PID \(pid)")
                executeHide(pid: pid)
            }
            return
        }

        // If focused window is already minimized → restore it (toggle / interrupt)
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(windowElement, "AXMinimized" as CFString, &minimized) == .success,
           let isMin = minimized as? Bool, isMin {
            AXUIElementSetAttributeValue(windowElement, "AXMinimized" as CFString, false as CFBoolean)
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
            DebugLog.shared.write("[MINIMIZE] toggle: un-minimized window for PID \(pid)")
            return
        }

        // Strategy A: press the actual minimize button (yellow dot)
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            windowElement,
            "AXMinimizeButton" as CFString,
            &button
        ) == .success,
           let minimizeButton = button as! AXUIElement? {
            let result = AXUIElementPerformAction(
                minimizeButton,
                kAXPressAction as CFString
            )
            if result == .success {
                DebugLog.shared.write("[MINIMIZE] pressed AXMinimizeButton for PID \(pid)")
                return
            }
            DebugLog.shared.write("[MINIMIZE] AXMinimizeButton press failed: \(result.rawValue)")
        }

        // Strategy B: fallback to AXMinimized attribute
        let setResult = AXUIElementSetAttributeValue(
            windowElement,
            "AXMinimized" as CFString,
            true as CFBoolean
        )
        if setResult == .success {
            // Verify it actually got minimized (some windows accept the call but ignore it)
            Thread.sleep(forTimeInterval: 0.1)
            var checkVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, "AXMinimized" as CFString, &checkVal) == .success,
               let isNowMinimized = checkVal as? Bool, isNowMinimized {
                DebugLog.shared.write("[MINIMIZE] set AXMinimized=true verified for PID \(pid)")
                return
            }
            DebugLog.shared.write("[MINIMIZE] set AXMinimized returned success but window not minimized - fallback to hide")
        } else {
            DebugLog.shared.write("[MINIMIZE] set AXMinimized failed: \(setResult.rawValue) - fallback to hide")
        }

        // Strategy C: minimize failed, fallback to hide
        executeHide(pid: pid)
    }
}
