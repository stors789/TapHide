import ApplicationServices
import AppKit

struct DockAppExtractor {
    static func extractApp(from dockItem: AXUIElement, runningApps: [NSRunningApplication]? = nil) -> (bundleID: String?, pid: pid_t?) {
        let apps = runningApps ?? NSWorkspace.shared.runningApplications
        
        // Strategy A: AXURL
        if let urlStr = getAXURLString(from: dockItem), let url = URL(string: urlStr) {
            // 1. Try Bundle ID matching
            if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                let pid = apps.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier
                return (bundleID, pid)
            }
            
            // 2. Try precise Bundle URL matching
            if let pid = pidByBundleURL(url, in: apps) {
                let bundleID = apps.first(where: { $0.processIdentifier == pid })?.bundleIdentifier
                return (bundleID, pid)
            }
        }
        
        // Strategy B: Sub-element PID (some apps like Electron might expose this)
        if let pid = pidFromSubElements(of: dockItem) {
            let bundleID = apps.first(where: { $0.processIdentifier == pid })?.bundleIdentifier
            return (bundleID, pid)
        }
        
        return (nil, nil)
    }
    
    private static func getAXURLString(from element: AXUIElement) -> String? {
        var axURL: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &axURL) == .success,
           let urlStr = axURL as? String {
            return urlStr
        }
        return nil
    }
    
    private static func pidByBundleURL(_ url: URL, in apps: [NSRunningApplication]) -> pid_t? {
        let standardURL = url.standardizedFileURL
        return apps.first(where: { $0.bundleURL?.standardizedFileURL == standardURL })?.processIdentifier
    }
    
    private static func pidFromSubElements(of element: AXUIElement) -> pid_t? {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success,
              let childrenArray = children as? [AXUIElement]
        else { return nil }
        
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        for child in childrenArray {
            var childPID: pid_t = 0
            if AXUIElementGetPid(child, &childPID) == .success,
               childPID != 0,
               childPID != dockPID
            {
                return childPID
            }
        }
        return nil
    }
}
