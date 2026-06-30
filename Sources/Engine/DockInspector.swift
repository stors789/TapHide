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
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
        let autohide = dockDefaults?.bool(forKey: "autohide") ?? false
        
        for screen in NSScreen.screens {
            let sf = screen.frame
            let vf = screen.visibleFrame
            let cgScreenFrame = getCGScreenBounds(for: screen)
            
            var dockRect = CGRect.zero
            
            if autohide {
                let thickness: CGFloat = 4 // conservative
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
                let bottomGap = vf.minY - sf.minY
                let leftGap = vf.minX - sf.minX
                let rightGap = sf.maxX - vf.maxX
                
                if orientation == "bottom" && bottomGap > 0 {
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.maxY - bottomGap, width: cgScreenFrame.width, height: bottomGap)
                } else if orientation == "left" && leftGap > 0 {
                    dockRect = CGRect(x: cgScreenFrame.origin.x, y: cgScreenFrame.origin.y, width: leftGap, height: cgScreenFrame.height)
                } else if orientation == "right" && rightGap > 0 {
                    dockRect = CGRect(x: cgScreenFrame.maxX - rightGap, y: cgScreenFrame.origin.y, width: rightGap, height: cgScreenFrame.height)
                }
            }

            if !dockRect.isEmpty {
                frameQueue.async(flags: .barrier) { self._cachedFrame = dockRect }
                log.info("Dock frame (screen calc): \(String(describing: dockRect))")
                DebugLog.shared.write("[DOCK] screen calc: cgScreen=\(cgScreenFrame) -> dock=\(dockRect)")
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

    private func getCGScreenBounds(for screen: NSScreen) -> CGRect {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return CGDisplayBounds(screenNumber)
        }
        guard let primaryScreen = NSScreen.screens.first else { return screen.frame }
        return CGRect(
            x: screen.frame.origin.x,
            y: primaryScreen.frame.height - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    func isPointInDockArea(_ point: CGPoint) -> Bool {
        if let cachedFrame = cachedGlobalDockFrame, cachedFrame.contains(point) {
            return true
        }

        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
        let autohide = dockDefaults?.bool(forKey: "autohide") ?? false

        guard let screen = NSScreen.screens.first(where: { getCGScreenBounds(for: $0).contains(point) }) else {
            return false
        }

        let screenCGFrame = getCGScreenBounds(for: screen)

        if autohide {
            let thickness: CGFloat = 4 // conservative
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
        } else {
            let sf = screen.frame
            let vf = screen.visibleFrame
            let bottomGap = vf.minY - sf.minY
            let leftGap = vf.minX - sf.minX
            let rightGap = sf.maxX - vf.maxX
            
            switch orientation {
            case "bottom":
                if bottomGap > 0 {
                    let rect = CGRect(x: screenCGFrame.origin.x, y: screenCGFrame.maxY - bottomGap, width: screenCGFrame.width, height: bottomGap)
                    return rect.contains(point)
                }
            case "left":
                if leftGap > 0 {
                    let rect = CGRect(x: screenCGFrame.origin.x, y: screenCGFrame.origin.y, width: leftGap, height: screenCGFrame.height)
                    return rect.contains(point)
                }
            case "right":
                if rightGap > 0 {
                    let rect = CGRect(x: screenCGFrame.maxX - rightGap, y: screenCGFrame.origin.y, width: rightGap, height: screenCGFrame.height)
                    return rect.contains(point)
                }
            default:
                break
            }
        }
        
        return false
    }
}
