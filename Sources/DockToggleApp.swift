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
    private var activeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppBecameActive()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            EventTapEngine.shared.refreshSnapshot()
        }
    }

    func onAppBecameActive() {
        PermissionsManager.shared.checkPermissions()
        let granted = PermissionsManager.shared.allGranted
        showPermissionsWarning = !granted
        if granted && !isEngineRunning {
            startEngine()
            startMonitorTimer(interval: 30.0)
        }
    }

    func startIfPermitted() {
        DebugLog.shared.write("[APP] startIfPermitted called")
        PermissionsManager.shared.checkPermissions()
        let granted = PermissionsManager.shared.allGranted
        DebugLog.shared.write("[APP] permissions: ax=\(PermissionsManager.shared.accessibilityGranted) input=\(PermissionsManager.shared.inputMonitoringGranted)")
        startMonitorTimer(interval: granted ? 30.0 : 10.0)

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

        engineThread = Thread { [weak self] in
            EventTapEngine.shared.start { success in
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
                            DispatchQueue.global(qos: .userInitiated).async {
                                DockInspector.shared.refreshFrame()
                                DockIconCache.shared.refresh()
                                EventTapEngine.shared.refreshSnapshot()
                            }
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
                                DispatchQueue.global(qos: .userInitiated).async {
                                    DockInspector.shared.refreshFrame()
                                    DockIconCache.shared.refresh()
                                }
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
            
            DispatchQueue.main.async {
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
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
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
            ConfigStore.shared.updateLaunchAtLoginStatus()
            DebugLog.shared.write("[APP] launchAtLogin=\(enabled)")
        } catch {
            ConfigStore.shared.updateLaunchAtLoginStatus()
            statusMessage = "Login item failed"
            DebugLog.shared.write("[APP] launchAtLogin failed: \(error.localizedDescription)")
        }
    }

    private func startMonitorTimer(interval: TimeInterval = 10.0) {
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
                    self.startMonitorTimer(interval: 10.0)
                    return
                }

                if granted && !self.isEngineRunning {
                    self.startEngine()
                    self.startMonitorTimer(interval: 30.0)
                } else if !granted {
                    self.statusMessage = "Permissions needed"
                    if interval != 10.0 {
                        self.startMonitorTimer(interval: 10.0)
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
    @ObservedObject var configStore = ConfigStore.shared

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

                Picker("Mode", selection: $configStore.behaviorMode) {
                    ForEach(BehaviorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Toggle("Launch at Login", isOn: Binding(
                    get: { configStore.launchAtLogin },
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
            .onAppear {
                configStore.updateLaunchAtLoginStatus()
            }
        }
    }
}
