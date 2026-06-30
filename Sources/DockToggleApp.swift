import SwiftUI
import AppKit
import ServiceManagement
import OSLog

let appLog = Logger(subsystem: "com.docktoggle", category: "App")

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var isEngineRunning = false
    @Published var showPermissionsWarning = false
    @Published var statusMessage = ""

    private var monitorTimer: Timer?
    private var cacheRefreshTimer: Timer?
    private var engineThread: Thread?

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func startIfPermitted() {
        DebugLog.shared.write("[APP] startIfPermitted called")
        PermissionsManager.shared.checkPermissions()
        let granted = PermissionsManager.shared.allGranted
        DebugLog.shared.write("[APP] permissions: ax=\(PermissionsManager.shared.accessibilityGranted) input=\(PermissionsManager.shared.inputMonitoringGranted)")
        startMonitorTimer(interval: granted ? 30.0 : 2.0)

        if granted {
            startEngine()
        } else {
            showPermissionsWarning = true
            statusMessage = "Permissions needed"
            showSettings()
        }
    }

    func startEngine() {
        guard !isEngineRunning else { return }

        _ = FrontmostTracker.shared
        _ = DockInspector.shared

        guard DockInspector.shared.resolve() else {
            statusMessage = "Dock not found"
            appLog.error("Failed to resolve Dock")
            return
        }

        guard let frame = DockInspector.shared.cachedGlobalDockFrame else {
            statusMessage = "Dock frame unavailable"
            appLog.error("Dock frame is nil after resolve")
            return
        }

        appLog.info("Dock frame: \(String(describing: frame))")

        engineThread = Thread {
            EventTapEngine.shared.start { [weak self] success in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if success {
                        self.isEngineRunning = true
                        self.statusMessage = "Running"
                        DockIconCache.shared.refresh()
                        
                        // Setup cache refresh timer (30s fallback/polling)
                        self.cacheRefreshTimer?.invalidate()
                        self.cacheRefreshTimer = Timer.scheduledTimer(
                            withTimeInterval: 30.0,
                            repeats: true
                        ) { _ in
                            DockInspector.shared.refreshFrame()
                            DockIconCache.shared.refresh()
                        }

                        // Setup Workspace notifications for event-driven updates
                        let workspaceCenter = NSWorkspace.shared.notificationCenter
                        if self.launchObserver == nil {
                            self.launchObserver = workspaceCenter.addObserver(
                                forName: NSWorkspace.didLaunchApplicationNotification,
                                object: nil,
                                queue: .main
                            ) { _ in
                                DebugLog.shared.write("[APP] Application launched, refreshing cache")
                                DockIconCache.shared.refresh()
                            }
                        }

                        if self.terminateObserver == nil {
                            self.terminateObserver = workspaceCenter.addObserver(
                                forName: NSWorkspace.didTerminateApplicationNotification,
                                object: nil,
                                queue: .main
                            ) { _ in
                                DebugLog.shared.write("[APP] Application terminated, refreshing cache")
                                DockIconCache.shared.refresh()
                            }
                        }

                        if self.screenObserver == nil {
                            self.screenObserver = NotificationCenter.default.addObserver(
                                forName: NSApplication.didChangeScreenParametersNotification,
                                object: nil,
                                queue: .main
                            ) { _ in
                                DebugLog.shared.write("[APP] Screen parameters changed, refreshing Dock frame and cache")
                                DockInspector.shared.refreshFrame()
                                DockIconCache.shared.refresh()
                            }
                        }
                    } else {
                        self.statusMessage = "Tap creation failed"
                        appLog.error("Event tap created but not enabled — check permissions")
                        self.isEngineRunning = false
                        self.engineThread = nil
                    }
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.isEngineRunning = false
                if self?.statusMessage == "Running" {
                    self?.statusMessage = "Event tap stopped"
                }
                self?.engineThread = nil
            }
        }
        engineThread?.name = "com.docktoggle.eventtap"
        engineThread?.start()
    }

    func onPermissionsChanged() {
        if PermissionsManager.shared.allGranted && !isEngineRunning {
            startEngine()
            showPermissionsWarning = false
            startMonitorTimer(interval: 30.0)
        }
    }

    func showSettings() {
        SettingsWindowManager.shared.show()
    }

    func stop() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        cacheRefreshTimer?.invalidate()
        cacheRefreshTimer = nil
        
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            launchObserver = nil
        }
        if let observer = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminateObserver = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }

        EventTapEngine.shared.stop()
        engineThread = nil
        isEngineRunning = false
        statusMessage = "Stopped"
        DebugLog.shared.flush()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            ConfigStore.shared.launchAtLogin = enabled
            DebugLog.shared.write("[APP] launchAtLogin=\(enabled)")
        } catch {
            ConfigStore.shared.launchAtLogin = !enabled
            statusMessage = "Login item failed"
            DebugLog.shared.write("[APP] launchAtLogin failed: \(error.localizedDescription)")
        }
    }

    private func startMonitorTimer(interval: TimeInterval = 2.0) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                PermissionsManager.shared.checkPermissions()
                let granted = PermissionsManager.shared.allGranted
                self.showPermissionsWarning = !granted

                if self.isEngineRunning && !EventTapEngine.shared.isTapEnabled {
                    self.isEngineRunning = false
                    self.statusMessage = "Event tap disabled"
                    self.showPermissionsWarning = true
                    EventTapEngine.shared.stop()
                    self.startMonitorTimer(interval: 2.0)
                    return
                }

                if granted && !self.isEngineRunning {
                    self.startEngine()
                    self.startMonitorTimer(interval: 30.0)
                } else if !granted {
                    self.statusMessage = "Permissions needed"
                    if interval != 2.0 {
                        self.startMonitorTimer(interval: 2.0)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            AppController.shared.startIfPermitted()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }
}

@main
struct DockToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var appController = AppController.shared
    @AppStorage("behaviorMode") private var behaviorMode: BehaviorMode = .hide

    var body: some Scene {
        MenuBarExtra("DockToggle", systemImage: "dock.rectangle") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DockToggle")
                        .font(.headline)
                    Spacer()
                    Circle()
                        .fill(appController.isEngineRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appController.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                Picker("Mode", selection: $behaviorMode) {
                    ForEach(BehaviorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Toggle("Launch at Login", isOn: Binding(
                    get: { ConfigStore.shared.launchAtLogin },
                    set: { newValue in
                        AppController.shared.setLaunchAtLogin(newValue)
                    }
                ))

                Divider()

                if appController.showPermissionsWarning {
                    Button("Permissions Needed") {
                        appController.showSettings()
                    }
                    .foregroundColor(.red)
                }

                Button("Open Settings...") {
                    appController.showSettings()
                }

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 260)
        }
    }
}
