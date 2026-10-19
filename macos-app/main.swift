import SwiftUI
import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: - Server Process & Telemetry Manager
final class ServerManager: ObservableObject {
    static let shared = ServerManager()
    
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var connectionType = "Поиск..."
    @Published var fps: Int = 90
    @Published var resolution: String = "1280x800"
    @Published var tabletBattery: Int? = nil
    @Published var isTabletCharging: Bool = false
    @Published var macBattery: Int? = nil
    @Published var localIP: String = "127.0.0.1"
    @Published var hasScreenCapturePermission: Bool = CGPreflightScreenCaptureAccess()
    
    private var serverProcess: Process?
    private var telemetryTimer: Timer?
    private let projectDir: String
    
    init() {
        // Find project directory (either current directory or bundle directory)
        let defaultPath = "/Users/daniel/Documents/android duo"
        if FileManager.default.fileExists(atPath: "\(defaultPath)/server/index.js") {
            self.projectDir = defaultPath
        } else {
            let bundlePath = Bundle.main.bundlePath
            let parentDir = (bundlePath as NSString).deletingLastPathComponent
            self.projectDir = parentDir
        }
    }
    
    func startServer() {
        guard !isRunning else { return }
        
        let nodePath = findNodeBinary() ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            fputs("[Android Duo App] Error: node binary not found at \(nodePath)\n", stderr)
            return
        }
        
        let serverScript = "\(projectDir)/server/index.js"
        guard FileManager.default.fileExists(atPath: serverScript) else {
            fputs("[Android Duo App] Error: server/index.js not found at \(serverScript)\n", stderr)
            return
        }
        
        // Clean up any stray processes on port 3000 first
        cleanPort3000()
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath)
        p.arguments = [serverScript]
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        
        // Environment with standard PATH for adb, swiftc, etc.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isConnected = false
            }
        }
        
        do {
            try p.run()
            self.serverProcess = p
            self.isRunning = true
            fputs("[Android Duo App] Started server/index.js with PID \(p.processIdentifier)\n", stderr)
            startTelemetryPolling()
        } catch {
            fputs("[Android Duo App] Failed to launch server: \(error)\n", stderr)
        }
    }
    
    func stopServer() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
        
        if let p = serverProcess, p.isRunning {
            p.terminate()
            p.waitUntilExit()
            self.serverProcess = nil
        }
        
        cleanPort3000()
        self.isRunning = false
        self.isConnected = false
    }
    
    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startServer()
        }
    }
    
    @discardableResult
    func checkScreenCapturePermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if self.hasScreenCapturePermission != granted {
            DispatchQueue.main.async {
                let wasGranted = self.hasScreenCapturePermission
                self.hasScreenCapturePermission = granted
                if granted && !wasGranted && self.isRunning {
                    fputs("[Android Duo App] Screen recording permission granted! Restarting server...\n", stderr)
                    self.restartServer()
                }
            }
        }
        return granted
    }
    
    func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
        
        // Trigger a lightweight ScreenCaptureKit query from this active GUI application
        // so macOS WindowServer records Android Duo.app in System Settings
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        
        let modernURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        let legacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        
        if let modernURL = modernURL, NSWorkspace.shared.open(modernURL) {
            // Modern settings opened
        } else if let legacyURL = legacyURL {
            NSWorkspace.shared.open(legacyURL)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            _ = self?.checkScreenCapturePermission()
        }
    }
    
    func revealAppInFinder() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
    
    func relaunchApp() {
        stopServer()
        let appPath = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open '\(appPath)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
    
    private func cleanPort3000() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pkill -f 'mac_host' 2>/dev/null; pkill -f 'node server/index.js' 2>/dev/null; lsof -ti:3000 | xargs kill -9 2>/dev/null || true"]
        try? p.run()
        p.waitUntilExit()
    }
    
    private func findNodeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    
    private func startTelemetryPolling() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchTelemetry()
        }
    }
    
    private func fetchTelemetry() {
        guard let url = URL(string: "http://127.0.0.1:3000/api/info") else { return }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            DispatchQueue.main.async {
                let localGranted = self.checkScreenCapturePermission()
                if let serverGranted = json["screenCaptureGranted"] as? Bool {
                    if serverGranted && !self.hasScreenCapturePermission {
                        self.hasScreenCapturePermission = true
                    } else if !serverGranted && !localGranted && self.hasScreenCapturePermission {
                        self.hasScreenCapturePermission = false
                    }
                }
                let connectedCount = (json["connectedClients"] as? Int) ?? 0
                self.isConnected = (connectedCount > 0)
                
                if let ipsList = json["ips"] as? [[String: Any]], let first = ipsList.first, let addr = first["address"] as? String {
                    self.localIP = addr
                } else if let ips = json["ips"] as? [String], let first = ips.first {
                    self.localIP = first
                }
                
                if let disp = json["display"] as? [String: Any] {
                    let w = disp["width"] as? Int ?? 1280
                    let h = disp["height"] as? Int ?? 800
                    let f = disp["fps"] as? Int ?? 90
                    self.resolution = "\(w)x\(h)"
                    self.fps = f
                }
                
                if let batt = json["battery"] as? [String: Any] {
                    if let macInfo = batt["mac"] as? [String: Any] {
                        self.macBattery = macInfo["level"] as? Int
                    } else if let macInt = batt["mac"] as? Int {
                        self.macBattery = macInt
                    }
                    if let tabInfo = batt["tablet"] as? [String: Any] {
                        self.tabletBattery = tabInfo["level"] as? Int
                        self.isTabletCharging = tabInfo["charging"] as? Bool ?? false
                    } else if let tabInt = batt["tablet"] as? Int {
                        self.tabletBattery = tabInt
                        self.isTabletCharging = batt["tabletCharging"] as? Bool ?? false
                    }
                }
                
                if self.isConnected {
                    self.connectionType = "⚡ USB / Wi-Fi"
                } else {
                    self.connectionType = "Ожидание планшета..."
                }
            }
        }.resume()
    }
}

// MARK: - App Mode & Window/Menu Bar Switcher
final class AppModeManager: ObservableObject {
    static let shared = AppModeManager()
    
    @Published var isMenuBarOnly = false
    @Published var minimizeToMenuBarOnClose: Bool {
        didSet {
            UserDefaults.standard.set(minimizeToMenuBarOnClose, forKey: "minimizeToMenuBarOnClose")
        }
    }
    
    @Published var hideFromDockInMenuBarMode: Bool {
        didSet {
            UserDefaults.standard.set(hideFromDockInMenuBarMode, forKey: "hideFromDockInMenuBarMode")
        }
    }
    
    weak var window: NSWindow?
    
    init() {
        self.minimizeToMenuBarOnClose = UserDefaults.standard.object(forKey: "minimizeToMenuBarOnClose") as? Bool ?? true
        self.hideFromDockInMenuBarMode = UserDefaults.standard.object(forKey: "hideFromDockInMenuBarMode") as? Bool ?? false
    }
    
    func switchToDockAndWindow() {
        isMenuBarOnly = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            if let mainScreen = NSScreen.screens.first {
                let screenRect = mainScreen.visibleFrame
                let x = screenRect.origin.x + (screenRect.width - 440) / 2
                let y = screenRect.origin.y + (screenRect.height - 520) / 2
                win.setFrame(NSRect(x: x, y: y, width: 440, height: 520), display: true)
            }
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }
    
    func switchToMenuBarOnly() {
        isMenuBarOnly = true
        window?.orderOut(nil)
        if hideFromDockInMenuBarMode {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        
        let notif = NSUserNotification()
        notif.title = "Android Duo"
        notif.informativeText = "Приложение свёрнуто в Menu Bar (вверху у часов). Нажмите на иконку «📱 Duo», чтобы вернуть окно."
        NSUserNotificationCenter.default.deliver(notif)
    }
    
    func toggleMode() {
        if isMenuBarOnly {
            switchToDockAndWindow()
        } else {
            switchToMenuBarOnly()
        }
    }
}

// MARK: - Window Throw / Relocation Functionality
func moveFrontmostWindowToTablet() {
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    let secondaryThreshold = Double(mainBounds.origin.x + mainBounds.width)
    
    // Find virtual display bounds
    var targetBounds = CGRect(x: secondaryThreshold, y: 156, width: 1280, height: 800)
    for id in [CGDirectDisplayID(89), CGDirectDisplayID(88), CGDirectDisplayID(87), CGDirectDisplayID(86), CGDirectDisplayID(85)] {
        let b = CGDisplayBounds(id)
        if !b.isNull && b.width > 0 && b.origin.x > 0 {
            targetBounds = b
            break
        }
    }
    
    // Find other frontmost app (not our own Android Duo app)
    guard let otherApp = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular && $0.processIdentifier != NSRunningApplication.current.processIdentifier && !$0.isHidden
    }) else { return }
    
    let appElement = AXUIElementCreateApplication(otherApp.processIdentifier)
    var focusedWinVal: AnyObject?
    var targetWin: AXUIElement?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWinVal) == .success,
       let f = focusedWinVal {
        targetWin = (f as! AXUIElement)
    } else {
        var windowsVal: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
           let windows = windowsVal as? [AXUIElement], let first = windows.first {
            targetWin = first
        }
    }
    
    guard let win = targetWin else { return }
    var sizeVal: AnyObject?
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeVal)
    var curSize = CGSize.zero
    if let sizeVal = sizeVal { AXValueGetValue(sizeVal as! AXValue, .cgSize, &curSize) }
    
    let maxW = targetBounds.width - 40.0
    let maxH = targetBounds.height - 80.0
    var targetW = curSize.width
    var targetH = curSize.height
    if targetW > maxW || targetH > maxH {
        targetW = min(targetW, maxW)
        targetH = min(targetH, maxH)
        var newSize = CGSize(width: targetW, height: targetH)
        if let s = AXValueCreate(.cgSize, &newSize) {
            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        }
    }
    
    let targetX = targetBounds.origin.x + max(20.0, (targetBounds.width - targetW) / 2.0)
    let targetY = targetBounds.origin.y + max(30.0, (targetBounds.height - targetH) / 2.0)
    var newPos = CGPoint(x: targetX, y: targetY)
    if let p = AXValueCreate(.cgPoint, &newPos) {
        _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
    }
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    otherApp.activate(options: [.activateIgnoringOtherApps])
}

// MARK: - SwiftUI Dashboard View
struct DashboardView: View {
    @ObservedObject var server = ServerManager.shared
    @ObservedObject var mode = AppModeManager.shared
    @State private var showingCopiedAlert = false
    let permTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "ipad.and.iphone")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Android Duo")
                            .font(.system(size: 18, weight: .bold))
                        
                        // Status Badge
                        HStack(spacing: 5) {
                            Circle()
                                .fill(server.isConnected ? Color.green : (server.isRunning ? Color.orange : Color.red))
                                .frame(width: 8, height: 8)
                            Text(server.isConnected ? "Подключен" : (server.isRunning ? "Ожидание" : "Остановлен"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(server.isConnected ? .green : (server.isRunning ? .orange : .red))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(12)
                    }
                    
                    Text("Второй монитор для Xiaomi Pad SE")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Switch to Menu Bar button
                Button(action: {
                    mode.switchToMenuBarOnly()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "menubar.arrow.up.rectangle")
                        Text("В Menu Bar")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .help("Скрыть из нижнего Dock и оставить только в строке меню macOS")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            
            Divider()
            
            // Screen Recording Permission Banner
            if !server.hasScreenCapturePermission {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 22))
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Требуется разрешение «Запись экрана»")
                                .font(.system(size: 13, weight: .bold))
                            Text("Для трансляции экрана включите тумблер для Android Duo в Настройках Mac.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    Text("💡 Если Android Duo нет в списке: нажмите «Показать в Finder» и перетащите иконку Android Duo в окно настроек (или нажмите «+» в настройках).")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button("Настройки...") {
                            server.requestScreenCapturePermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 11, weight: .semibold))
                        
                        Button("Показать в Finder") {
                            server.revealAppInFinder()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                        
                        Button("Перезапустить") {
                            server.relaunchApp()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            
            // Content Body
            ScrollView {
                VStack(spacing: 16) {
                    // Device Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Xiaomi Pad SE (11\")", systemImage: "tablet")
                                .font(.system(size: 14, weight: .semibold))
                            
                            Spacer()
                            
                            if let batt = server.tabletBattery {
                                HStack(spacing: 4) {
                                    Image(systemName: server.isTabletCharging ? "battery.100.bolt" : "battery.75")
                                        .foregroundColor(server.isTabletCharging ? .green : .primary)
                                    Text("\(batt)%")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        
                        HStack(spacing: 10) {
                            StatusMetricBox(title: "Частота", value: "\(server.fps) FPS", icon: "speedometer")
                            StatusMetricBox(title: "Разрешение", value: server.resolution, icon: "aspectratio")
                            StatusMetricBox(title: "Канал", value: server.isConnected ? "USB / 90Hz" : "Wi-Fi", icon: "bolt.fill")
                        }
                    }
                    .padding(14)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    
                    // Quick Action Buttons
                    VStack(spacing: 10) {
                        Button(action: {
                            moveFrontmostWindowToTablet()
                        }) {
                            HStack {
                                Image(systemName: "arrow.up.right.video")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Перенести активное окно на планшет")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("⌥⌘→")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        HStack(spacing: 10) {
                            Button(action: {
                                if let url = URL(string: "http://localhost:3000") {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "safari")
                                    Text("Веб-экран")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered)
                            
                            Button(action: {
                                server.restartServer()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Перезапустить")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    // Connection URLs & Help
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Адрес подключения по Wi-Fi:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("http://\(server.localIP):3000")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Копировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://\(server.localIP):3000", forType: .string)
                                showingCopiedAlert = true
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                        }
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                    
                    // Settings Toggles
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("При закрытии окна сворачивать в Menu Bar", isOn: $mode.minimizeToMenuBarOnClose)
                            .font(.system(size: 12))
                        Toggle("Скрывать значок из Dock при переносе в Menu Bar", isOn: $mode.hideFromDockInMenuBarMode)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer
            HStack {
                Text(server.isRunning ? "Сервер активен (порт 3000)" : "Сервер не запущен")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    if server.isRunning {
                        server.stopServer()
                    } else {
                        server.startServer()
                    }
                }) {
                    Text(server.isRunning ? "Остановить" : "Запустить")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                
                Button("Выйти") {
                    server.stopServer()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 440, height: 520)
        .onReceive(permTimer) { _ in
            _ = server.checkScreenCapturePermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = server.checkScreenCapturePermission()
        }
        .onAppear {
            _ = server.checkScreenCapturePermission()
        }
    }
}

struct StatusMetricBox: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - App Delegate & Menu Bar Setup
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let server = ServerManager.shared
    private let mode = AppModeManager.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Setup Menu Bar Status Item
        setupStatusItem()
        
        // 2. Setup Main Dashboard Window
        setupMainWindow()
        
        // Check and request screen capture permission if not granted
        if !server.checkScreenCapturePermission() {
            fputs("[Android Duo App] Screen recording permission not granted yet, requesting access...\n", stderr)
            server.requestScreenCapturePermission()
        }
        
        // Start server automatically
        server.startServer()
        
        // 3. Register Global Keyboard Shortcut (Opt+Cmd+Right Arrow) to throw window to tablet
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 124 { // Right Arrow
                moveFrontmostWindowToTablet()
                return nil
            }
            return event
        }
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        _ = server.checkScreenCapturePermission()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mode.switchToDockAndWindow()
        return true
    }
    
    private func setupStatusItem() {
        let prefKey = "NSStatusItem Preferred Position AndroidDuoStatusItem"
        CFPreferencesSetValue(prefKey as CFString, 180.0 as CFPropertyList, "com.apple.controlcenter" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize("com.apple.controlcenter" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        UserDefaults.standard.set(180.0, forKey: prefKey)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "AndroidDuoStatusItem"
        statusItem.behavior = [.removalAllowed]
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: "Android Duo")
            button.image?.isTemplate = true
            button.title = " Duo"
            button.imagePosition = .imageLeading
            button.toolTip = "Android Duo — нажмите, чтобы открыть меню или вернуть окно дашборда"
        }
        
        let menu = NSMenu()
        updateMenu(menu)
        statusItem.menu = menu
        
        // Update menu dynamically before it displays
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self, weak menu] _ in
            guard let menu = menu else { return }
            self?.updateMenu(menu)
        }
    }
    
    private func updateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        
        // Header Status
        let statusTitle = server.isConnected ? "🟢 Xiaomi Pad SE: Подключен" : (server.isRunning ? "🟡 Ожидание планшета..." : "🔴 Сервер остановлен")
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        // Window & Dock switcher placed prominently at the top
        let windowToggleItem = NSMenuItem(title: "🪟 Открыть дашборд (Вернуть в Dock)", action: #selector(showWindowFromMenu), keyEquivalent: "o")
        windowToggleItem.target = self
        menu.addItem(windowToggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Screen Recording Permission Notice in menu
        if !server.hasScreenCapturePermission {
            let permItem = NSMenuItem(title: "⚠️ Требуется «Запись экрана» (Нажмите)", action: #selector(openPermissionsAction), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
        }
        
        // Stats
        if server.isConnected {
            let statsTitle = "⚡ 90 FPS • \(server.resolution) • USB/Wi-Fi"
            let statsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
            statsItem.isEnabled = false
            menu.addItem(statsItem)
            
            if let batt = server.tabletBattery {
                let battTitle = "🔋 Батарея планшета: \(batt)%" + (server.isTabletCharging ? " ⚡" : "")
                let battItem = NSMenuItem(title: battTitle, action: nil, keyEquivalent: "")
                battItem.isEnabled = false
                menu.addItem(battItem)
            }
        }
        
        // Quick Action
        let moveWinItem = NSMenuItem(title: "🚀 Перенести активное окно на планшет", action: #selector(moveWindowAction), keyEquivalent: "")
        moveWinItem.target = self
        menu.addItem(moveWinItem)
        
        let webItem = NSMenuItem(title: "🌐 Открыть веб-трансляцию в браузере", action: #selector(openWebAction), keyEquivalent: "")
        webItem.target = self
        menu.addItem(webItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let restartItem = NSMenuItem(title: "🔄 Перезапустить стрим", action: #selector(restartAction), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "❌ Завершить Android Duo", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func setupMainWindow() {
        let contentView = DashboardView()
        let hostingController = NSHostingController(rootView: contentView)
        
        window = NSWindow(contentViewController: hostingController)
        window.title = "Android Duo"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        if let mainScreen = NSScreen.screens.first {
            let screenRect = mainScreen.visibleFrame
            let x = screenRect.origin.x + (screenRect.width - 440) / 2
            let y = screenRect.origin.y + (screenRect.height - 520) / 2
            window.setFrame(NSRect(x: x, y: y, width: 440, height: 520), display: true)
        } else {
            window.center()
        }
        window.delegate = self
        
        mode.window = window
        
        // Show by default as regular Dock app
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // Window Close Behavior:
    // If user clicks red 'X', check if minimizeToMenuBarOnClose is active
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if mode.minimizeToMenuBarOnClose {
            mode.switchToMenuBarOnly()
            return false // don't close/destroy, just hide and switch to accessory
        }
        return true
    }
    
    @objc private func showWindowFromMenu() {
        mode.switchToDockAndWindow()
    }
    
    @objc private func moveWindowAction() {
        moveFrontmostWindowToTablet()
    }
    
    @objc private func openWebAction() {
        if let url = URL(string: "http://localhost:3000") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func openPermissionsAction() {
        server.requestScreenCapturePermission()
    }
    
    @objc private func restartAction() {
        server.restartServer()
    }
    
    @objc private func quitAction() {
        server.stopServer()
        NSApp.terminate(nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        server.stopServer()
    }
}

// MARK: - Entrypoint
@main
struct AndroidDuoAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
