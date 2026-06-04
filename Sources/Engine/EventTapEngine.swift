import CoreGraphics
import AppKit
import OSLog

final class EventTapEngine {
    static let shared = EventTapEngine()
    private let log = Logger(subsystem: "com.docktoggle", category: "EventTap")

    private var eventTap: CFMachPort?
    private(set) var isRunning = false
    private var shouldSwallowNextMouseUp = false

    private init() {}

    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
                                CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                let engine = Unmanaged<EventTapEngine>
                    .fromOpaque(userInfo!).takeUnretainedValue()
                return engine.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate returned nil")
            return false
        }

        eventTap = tap
        log.info("Event tap created (defaultTap)")

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        log.info("Event tap running on dedicated RunLoop")
        CFRunLoopRun()
        log.info("CFRunLoopRun returned")
        isRunning = false
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        eventTap = nil
        isRunning = false
        log.info("Event tap stopped")
    }

    var isTapEnabled: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .leftMouseUp {
            if shouldSwallowNextMouseUp {
                shouldSwallowNextMouseUp = false
                DebugLog.shared.write("[TAP] swallow mouseUp")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // type == .leftMouseDown
        let point = event.location
        guard let frame = DockInspector.shared.cachedGlobalDockFrame,
              frame.contains(point)
        else {
            return Unmanaged.passUnretained(event)
        }

        var capturedFrontmostPID = FrontmostTracker.shared.currentPID
        guard let targetPID = DockIconCache.shared.lookup(at: point) else {
            return Unmanaged.passUnretained(event)
        }

        let rawMode = UserDefaults.standard.string(forKey: "behaviorMode") ?? "hide"
        let mode = BehaviorMode(rawValue: rawMode) ?? .hide

        let targetName = NSRunningApplication(processIdentifier: targetPID)?
            .localizedName ?? "?"
        let frontmostName = NSRunningApplication(processIdentifier: capturedFrontmostPID)?
            .localizedName ?? "?"

        DebugLog.shared.write("[TAP] mouseDown@(\(Int(point.x)),\(Int(point.y))) frontmost=\(capturedFrontmostPID)(\(frontmostName)) target=\(targetPID)(\(targetName)) mode=\(rawMode)")

        // Debounce: if Dock is restoring this PID, stay out of the way
        if ActionExecutor.shared.isRestoring(pid: targetPID) {
            DebugLog.shared.write("[TAP] debounce — pass through for PID \(targetPID)")
            return Unmanaged.passUnretained(event)
        }

        // When cached frontmost doesn't match, try a live check
        // to handle race conditions where didActivateApplicationNotification
        // hasn't been processed yet on the main queue.
        if targetPID != capturedFrontmostPID {
            let livePID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            if livePID == targetPID {
                let liveName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                DebugLog.shared.write("[TAP] live check overrode frontmost: \(capturedFrontmostPID)(\(frontmostName)) -> \(livePID)(\(liveName))")
                capturedFrontmostPID = livePID
            }
        }

        // Toggle: target is frontmost → hide or minimize.
        // Also debounce to prevent immediate re-toggle after state change.
        if targetPID == capturedFrontmostPID {
            shouldSwallowNextMouseUp = true
            ActionExecutor.shared.markRestoring(pid: targetPID)
            DebugLog.shared.write("[TAP] SWALLOW + execute \(rawMode) on PID \(targetPID)")
            DispatchQueue.main.async {
                ActionExecutor.shared.execute(targetPID: targetPID, mode: mode)
            }
            return nil
        }

        // Not frontmost → pass through to Dock. Debounce to prevent
        // rapid follow-up clicks from immediately re-toggling after restore.
        ActionExecutor.shared.markRestoring(pid: targetPID)
        DebugLog.shared.write("[TAP] pass through (not frontmost) + debounce PID \(targetPID)")
        return Unmanaged.passUnretained(event)
    }
}
