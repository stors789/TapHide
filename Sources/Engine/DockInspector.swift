import ApplicationServices
import AppKit
import CoreGraphics
import OSLog

final class DockInspector {
    static let shared = DockInspector()
    private let log = Logger(subsystem: "com.docktoggle", category: "DockInspector")

    private var dockPID: pid_t = 0
    private var dockAppElement: AXUIElement?

    private var _cachedFrame: CGRect?
    private let frameQueue = DispatchQueue(
        label: "com.docktoggle.dockframe",
        attributes: .concurrent
    )

    var cachedGlobalDockFrame: CGRect? {
        frameQueue.sync { _cachedFrame }
    }

    private init() {}

    @discardableResult
    func resolve() -> Bool {
        let docks = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        )
        guard let dock = docks.first else {
            log.error("Dock process not found")
            return false
        }
        dockPID = dock.processIdentifier
        dockAppElement = AXUIElementCreateApplication(dockPID)
        log.info("Dock resolved: PID=\(self.dockPID)")

        Thread.sleep(forTimeInterval: 0.05)
        refreshFrame()
        return true
    }

    func refreshFrame() {
        guard let element = dockAppElement else {
            log.warning("refreshFrame: no dockAppElement")
            return
        }

        // Strategy 1: direct AXFrame on Dock application
        if let rect = axFrame(of: element), !rect.isEmpty {
            frameQueue.async(flags: .barrier) { self._cachedFrame = rect }
            log.info("Dock frame (direct): \(String(describing: rect))")
            return
        }

        // Strategy 2: AXPosition + AXSize
        if let rect = axPositionAndSize(of: element), !rect.isEmpty {
            frameQueue.async(flags: .barrier) { self._cachedFrame = rect }
            log.info("Dock frame (pos+size): \(String(describing: rect))")
            return
        }

        // Strategy 3: first child AXList element
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element,
                "AXChildren" as CFString, &children) == .success,
           let childrenArray = children as? [AXUIElement],
           let firstChild = childrenArray.first {
            if let rect = axFrame(of: firstChild), !rect.isEmpty {
                frameQueue.async(flags: .barrier) { self._cachedFrame = rect }
                log.info("Dock frame (child): \(String(describing: rect))")
                return
            }
            if let rect = axPositionAndSize(of: firstChild), !rect.isEmpty {
                frameQueue.async(flags: .barrier) { self._cachedFrame = rect }
                log.info("Dock frame (child pos+size): \(String(describing: rect))")
                return
            }
        }

        // Strategy 4: compute from screen geometry (all Dock positions)
        if let screen = NSScreen.main {
            let sf = screen.frame
            let vf = screen.visibleFrame
            
            let cgScreenFrame = convertToCG(sf)
            let cgVisibleFrame = convertToCG(vf)
            
            let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
            let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
            let autohide = dockDefaults?.bool(forKey: "autohide") ?? false
            
            var dockRect = CGRect.zero
            
            if autohide {
                // In autohide mode, visibleFrame == screen.frame.
                // We define a default 100px thick zone along the appropriate edge.
                let thickness: CGFloat = 100
                switch orientation {
                case "bottom":
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.maxY - thickness, width: cgScreenFrame.width, height: thickness)
                case "left":
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.origin.y, width: thickness, height: cgScreenFrame.height)
                case "right":
                    dockRect = CGRect(x: cgScreenFrame.maxX - thickness, y: cgScreenFrame.origin.y, width: thickness, height: cgScreenFrame.height)
                default:
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.maxY - thickness, width: cgScreenFrame.width, height: thickness)
                }
            } else {
                // Non-autohide: calculate based on visibleFrame difference in CoreGraphics coordinates
                let bottomH = cgScreenFrame.maxY - cgVisibleFrame.maxY
                let leftW = cgVisibleFrame.minX - cgScreenFrame.minX
                let rightW = cgScreenFrame.maxX - cgVisibleFrame.maxX
                let topH = cgVisibleFrame.minY - cgScreenFrame.minY
                
                if bottomH > 0 {
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgVisibleFrame.maxY, width: cgScreenFrame.width, height: bottomH)
                } else if leftW > 0 {
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.origin.y, width: leftW, height: cgScreenFrame.height)
                } else if rightW > 0 {
                    dockRect = CGRect(x: cgVisibleFrame.maxX, y: cgScreenFrame.origin.y, width: rightW, height: cgScreenFrame.height)
                } else if topH > 0 {
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.origin.y, width: cgScreenFrame.width, height: topH)
                }
            }

            if !dockRect.isEmpty {
                frameQueue.async(flags: .barrier) { self._cachedFrame = dockRect }
                log.info("Dock frame (screen calc): \(String(describing: dockRect))")
                DebugLog.shared.write("[DOCK] screen calc: cgScreen=\(cgScreenFrame) cgVisible=\(cgVisibleFrame) -> dock=\(dockRect)")
                return
            }
        }

        log.error("All Dock frame resolution strategies failed")
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                "AXFrame" as CFString, &value) == .success,
              let rawValue = value
        else { return nil }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(axValue, .cgRect, &rect)
        return rect
    }

    private func axPositionAndSize(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                "AXPosition" as CFString, &posValue) == .success,
              let rawPos = posValue,
              AXUIElementCopyAttributeValue(element,
                "AXSize" as CFString, &sizeValue) == .success,
              let rawSize = sizeValue
        else { return nil }

        let posAX = rawPos as! AXValue
        let sizeAX = rawSize as! AXValue

        guard AXValueGetType(posAX) == .cgPoint,
              AXValueGetType(sizeAX) == .cgSize
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posAX, .cgPoint, &point)
        AXValueGetValue(sizeAX, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    func isDockHidden() -> Bool {
        guard let element = dockAppElement else { 
            resolve()
            return false 
        }
        var hidden: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            "AXHidden" as CFString,
            &hidden
        )
        if status == .invalidUIElement || status == .cannotComplete {
            resolve()
            return false
        }
        guard status == .success,
              let val = hidden as? Bool
        else { return false }
        return val
    }

    func identifyApp(at point: CGPoint) -> (bundleID: String?, pid: pid_t?) {
        guard let appElement = dockAppElement else {
            DebugLog.shared.write("[DOCK] no dockAppElement, trying to resolve")
            resolve()
            return (nil, nil)
        }

        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            appElement,
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard status == .success, let hitElement = hit else {
            DebugLog.shared.write("[DOCK] AX hit test FAILED at (\(point.x), \(point.y)): status=\(status.rawValue)")
            if status == .invalidUIElement || status == .cannotComplete {
                DebugLog.shared.write("[DOCK] Dock AX element invalid, re-resolving...")
                resolve()
            }
            return (nil, nil)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(hitElement, &pid)
        DebugLog.shared.write("[DOCK] AX hit pid=\(pid), dockPID=\(self.dockPID)")

        guard pid == dockPID else {
            return (nil, nil)
        }

        guard let dockItem = findParentDockItem(from: hitElement) else {
            DebugLog.shared.write("[DOCK] No DockItem in parent chain")
            return (nil, nil)
        }

        let result = DockAppExtractor.extractApp(from: dockItem)
        DebugLog.shared.write("[DOCK] extractApp: bundleID=\(result.bundleID ?? "nil"), pid=\(result.pid ?? 0)")
        return result
    }

    private func findParentDockItem(from element: AXUIElement) -> AXUIElement? {
        var current = element
        for i in 0..<10 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(
                current,
                "AXRole" as CFString,
                &role
            )
            let roleStr = (role as? String) ?? ""
            DebugLog.shared.write("[DOCK] depth=\(i) role=\(roleStr)")

            if isDockItemRole(roleStr) {
                return current
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current,
                "AXParent" as CFString,
                &parentValue
            ) == .success,
                  let rawParent = parentValue
            else { return nil }
            let parent = rawParent as! AXUIElement
            current = parent
        }
        return nil
    }

    private func isDockItemRole(_ role: String) -> Bool {
        role.lowercased().contains("dockitem")
    }

    private func convertToCG(_ rect: NSRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        let primaryHeight = primaryScreen.frame.height
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    func isPointInDockArea(_ point: CGPoint) -> Bool {
        if let cachedFrame = cachedGlobalDockFrame, cachedFrame.contains(point) {
            return true
        }

        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"

        guard let screen = NSScreen.screens.first(where: { convertToCG($0.frame).contains(point) }) else {
            return false
        }

        let screenCGFrame = convertToCG(screen.frame)
        let thickness: CGFloat = 100

        switch orientation {
        case "bottom":
            let hotspot = CGRect(x: screenCGFrame.origin.x, y: screenCGFrame.maxY - thickness, width: screenCGFrame.width, height: thickness)
            return hotspot.contains(point)
        case "left":
            let hotspot = CGRect(x: screenCGFrame.origin.x, y: screenCGFrame.origin.y, width: thickness, height: screenCGFrame.height)
            return hotspot.contains(point)
        case "right":
            let hotspot = CGRect(x: screenCGFrame.maxX - thickness, y: screenCGFrame.origin.y, width: thickness, height: screenCGFrame.height)
            return hotspot.contains(point)
        default:
            return false
        }
    }
}
