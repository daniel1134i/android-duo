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
    @Published var transport: String = "none" // "usb", "wifi", "none"
    @Published var isAdbConnected: Bool = false
    @Published var isAdbReverseActive: Bool = false
    @Published var clientIp: String = ""
    @Published var fps: Int = 90
    @Published var resolution: String = "1280x800"
    @Published var tabletBattery: Int? = nil
    @Published var isTabletCharging: Bool = false
    @Published var macBattery: Int? = nil
    @Published var localIP: String = "127.0.0.1"
    @Published var hasScreenCapturePermission: Bool = CGPreflightScreenCaptureAccess()
    @Published var tabletLaunchTarget: String = UserDefaults.standard.string(forKey: "tabletLaunchTarget") ?? "native"
    
    private var serverProcess: Process?
    private var telemetryTimer: Timer?
    private let projectDir: String
    
    init() {
        // 1. First check if bundled inside the .app Resources/app directory (Standalone/DMG Mode)
        if let resPath = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: "\(resPath)/app/server/index.js") {
            self.projectDir = "\(resPath)/app"
        } else if let configuredDir = Bundle.main.infoDictionary?["ProjectDir"] as? String,
           FileManager.default.fileExists(atPath: "\(configuredDir)/server/index.js") {
            self.projectDir = configuredDir
        } else {
            let currentDir = FileManager.default.currentDirectoryPath
            let bundleParent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("android duo").path ?? ""
            
            if FileManager.default.fileExists(atPath: "\(currentDir)/server/index.js") {
                self.projectDir = currentDir
            } else if FileManager.default.fileExists(atPath: "\(bundleParent)/server/index.js") {
                self.projectDir = bundleParent
            } else if FileManager.default.fileExists(atPath: "\(documentsDir)/server/index.js") {
                self.projectDir = documentsDir
            } else {
                self.projectDir = bundleParent
            }
        }
    }
    
    func startServer() {
        guard !isRunning else { return }
        
        guard let nodePath = findNodeBinary() else {
            fputs("[Android Duo App] Error: node binary not found on this system.\n", stderr)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Требуется Node.js"
                alert.informativeText = "Для работы фонового сервера Android Duo требуется Node.js.\n\nУстановите его с официального сайта (nodejs.org) или через терминал: brew install node"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Скачать Node.js (nodejs.org)")
                alert.addButton(withTitle: "Закрыть")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "https://nodejs.org/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
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
        
        if let p = serverProcess {
            if p.isRunning {
                p.terminate() // sends SIGTERM
                
                // Allow up to 250ms for node to exit gracefully
                let start = Date()
                while p.isRunning && Date().timeIntervalSince(start) < 0.25 {
                    usleep(20_000) // 20ms
                }
                
                // If still running after 250ms, force kill with SIGKILL
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
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
        // If already granted once, do not downgrade during sleep or lock-screen transient states
        if self.hasScreenCapturePermission && !granted {
            return true
        }
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
        if self.hasScreenCapturePermission { return }
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
    
    func changeResolution(width: Int, height: Int) {
        guard let url = URL(string: "http://127.0.0.1:3000/api/resolution?width=\(width)&height=\(height)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            if error == nil {
                DispatchQueue.main.async {
                    self?.resolution = "\(width)x\(height)"
                    self?.fetchTelemetry()
                }
            }
        }.resume()
    }
    
    func setTabletLaunchTarget(_ target: String) {
        tabletLaunchTarget = target
        UserDefaults.standard.set(target, forKey: "tabletLaunchTarget")
        guard let url = URL(string: "http://127.0.0.1:3000/api/tablet/launch-target?target=\(target)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request).resume()
    }

    func launchTabletApp(targetOverride: String? = nil) {
        var urlString = "http://127.0.0.1:3000/api/launch"
        if let target = targetOverride {
            urlString += "?target=\(target)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request).resume()
    }
    
    func sendPowerState(_ state: String) {
        guard let url = URL(string: "http://127.0.0.1:3000/api/power?state=\(state)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request).resume()
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
    
    func cleanPort3000() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c",
            "pkill -9 -f 'mac_host' 2>/dev/null; " +
            "pkill -9 -f 'node.*server/index.js' 2>/dev/null; " +
            "lsof -ti:3000 2>/dev/null | xargs kill -9 2>/dev/null || true"
        ]
        try? p.run()
        let start = Date()
        while p.isRunning && Date().timeIntervalSince(start) < 0.4 {
            usleep(20_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }
    
    private func findNodeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "/opt/local/bin/node"
        ]
        
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                candidates.append("\(nvmDir)/\(v)/bin/node")
            }
        }
        
        candidates.append("\(home)/.fnm/current/bin/node")
        candidates.append("\(home)/.asdf/shims/node")
        candidates.append("\(home)/.volta/bin/node")
        
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which node"]
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let out = out, !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) {
            return out
        }
        
        return nil
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
                _ = self.checkScreenCapturePermission()
                if let serverGranted = json["screenCaptureGranted"] as? Bool {
                    if serverGranted && !self.hasScreenCapturePermission {
                        self.hasScreenCapturePermission = true
                    }
                }
                let connectedCount = (json["connectedClients"] as? Int) ?? 0
                self.isConnected = (connectedCount > 0)
                
                if let tr = json["transport"] as? String {
                    self.transport = tr
                } else {
                    self.transport = self.isConnected ? "wifi" : "none"
                }
                self.isAdbConnected = json["adbConnected"] as? Bool ?? false
                self.isAdbReverseActive = json["adbReverseActive"] as? Bool ?? false
                
                if let clients = json["clients"] as? [[String: Any]], let first = clients.first, let ip = first["ip"] as? String {
                    self.clientIp = ip
                }
                
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
                    if self.transport == "usb" {
                        self.connectionType = "⚡ USB (Прямой провод)"
                    } else {
                        self.connectionType = "📶 Wi-Fi (\(self.clientIp.isEmpty ? self.localIP : self.clientIp))"
                    }
                } else {
                    self.connectionType = self.isAdbConnected ? "Ожидание открытия браузера..." : "Ожидание планшета..."
                }
            }
        }.resume()
    }
}

// MARK: - Window Close Action Enum
enum WindowCloseAction: String, CaseIterable, Identifiable {
    case quitApp = "quit"
    case minimizeToMenuBar = "minimize"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .quitApp:
            return "Завершать приложение"
        case .minimizeToMenuBar:
            return "Сворачивать в Menu Bar"
        }
    }
}

// MARK: - Toast HUD Notification
final class ToastHUD {
    static func show(message: String, duration: TimeInterval = 2.5) {
        DispatchQueue.main.async {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 62),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = NSColor.clear
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.hasShadow = true
            
            let hosting = NSHostingView(rootView:
                HStack(spacing: 12) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Android Duo")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                )
            )
            panel.contentView = hosting
            
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = screenRect.origin.x + (screenRect.width - 380) / 2
                let y = screenRect.origin.y + screenRect.height - 80
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1.0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    panel.close()
                })
            }
        }
    }
}

// MARK: - App Mode & Window/Menu Bar Switcher
final class AppModeManager: ObservableObject {
    static let shared = AppModeManager()
    
    @Published var isMenuBarOnly = false
    @Published var windowCloseAction: WindowCloseAction {
        didSet {
            UserDefaults.standard.set(windowCloseAction.rawValue, forKey: "windowCloseAction")
        }
    }
    
    weak var window: NSWindow?
    
    init() {
        if let savedAction = UserDefaults.standard.string(forKey: "windowCloseAction"),
           let action = WindowCloseAction(rawValue: savedAction) {
            self.windowCloseAction = action
        } else if let oldMin = UserDefaults.standard.object(forKey: "minimizeToMenuBarOnClose") as? Bool {
            self.windowCloseAction = oldMin ? .minimizeToMenuBar : .quitApp
        } else {
            self.windowCloseAction = .quitApp
        }
    }
    
    func switchToDockAndWindow() {
        isMenuBarOnly = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            win.level = .normal
            win.collectionBehavior = [.managed, .participatesInCycle]
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
    
    func switchToMenuBarOnly(notify: Bool = true) {
        isMenuBarOnly = true
        window?.orderOut(nil)
        // When in Menu Bar mode, ALWAYS hide from Dock so no ghost icon remains
        NSApp.setActivationPolicy(.accessory)
        
        if notify {
            ToastHUD.show(message: "Свёрнуто в строку меню (вверху у часов). Нажмите на иконку «📱 Duo», чтобы вернуть окно.")
        }
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
                            StatusMetricBox(
                                title: "Канал",
                                value: server.isConnected ? (server.transport == "usb" ? "⚡ USB" : "📶 Wi-Fi") : (server.isAdbConnected ? "USB готов" : "Нет связи"),
                                icon: server.transport == "usb" ? "bolt.fill" : (server.isConnected ? "wifi" : "cable.connector")
                            )
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
                    
                    // Window Close Behavior Settings
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("При нажатии на ✕ (закрытие окна):")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        
                        Picker("", selection: $mode.windowCloseAction) {
                            Text("Завершать приложение").tag(WindowCloseAction.quitApp)
                            Text("Сворачивать в Menu Bar").tag(WindowCloseAction.minimizeToMenuBar)
                        }
                        .pickerStyle(.segmented)
                        
                        Text(mode.windowCloseAction == .quitApp
                            ? "💡 Нажатие на ✕ полностью завершит работу Android Duo и остановит сервер."
                            : "💡 Нажатие на ✕ скроет окно и значок из Dock, оставив приложение в строке меню.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                    
                    // Tablet Launch Target Settings
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "ipad.and.iphone")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("Открывать на планшете по умолчанию:")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        
                        Picker("", selection: Binding(
                            get: { server.tabletLaunchTarget },
                            set: { server.setTabletLaunchTarget($0) }
                        )) {
                            Text("⚡ Android Duo App (Рекомендуется)").tag("native")
                            Text("🖥 Fully Kiosk Browser").tag("fully")
                            Text("🌐 Chrome WebAPK / Браузер").tag("webapk")
                        }
                        .pickerStyle(.menu)
                        
                        Text(server.tabletLaunchTarget == "native"
                            ? "💡 Запускает официальный нативный клиент Android Duo без рамок, водяных знаков и рекламы."
                            : (server.tabletLaunchTarget == "fully"
                                ? "💡 Запускает стрим через полноэкранный браузер Fully Kiosk."
                                : "💡 Открывает веб-версию через Chrome WebAPK или стандартный браузер."))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
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
                    AppDelegate.shared?.quitApplication()
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
    static weak var shared: AppDelegate?
    
    private var statusItem: NSStatusItem?
    private var window: NSWindow!
    private let server = ServerManager.shared
    private let mode = AppModeManager.shared
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    private var isTerminating = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupSignalHandlers()
        
        // 1. Setup Standard macOS Main Menu (Cmd+Q, Cmd+W, Cmd+H)
        setupMainMenu()
        
        // 2. Setup Menu Bar Status Item
        setupStatusItem()
        
        // 3. Setup Main Dashboard Window
        setupMainWindow()
        
        // Check and request screen capture permission if not granted
        if !server.checkScreenCapturePermission() {
            fputs("[Android Duo App] Screen recording permission not granted yet, requesting access...\n", stderr)
            server.requestScreenCapturePermission()
        }
        
        // Start server automatically
        server.startServer()
        
        // 4. Register Keyboard Shortcuts: Cmd+Q to quit, Opt+Cmd+Right Arrow to throw window
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && (event.keyCode == 12 || event.charactersIgnoringModifiers == "q") {
                self?.quitApplication()
                return nil
            }
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 124 { // Right Arrow
                moveFrontmostWindowToTablet()
                return nil
            }
            return event
        }
        
        // 5. Register System Power & Sleep Observers
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            fputs("[Android Duo App] System will sleep. Notifying server...\n", stderr)
            self?.notifyServerPowerState("sleep")
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            fputs("[Android Duo App] Screens did sleep. Notifying server...\n", stderr)
            self?.notifyServerPowerState("sleep")
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            fputs("[Android Duo App] System woke up. Notifying server...\n", stderr)
            self?.notifyServerPowerState("wake")
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            fputs("[Android Duo App] Screens did wake. Notifying server...\n", stderr)
            self?.notifyServerPowerState("wake")
        }
    }
    
    private func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        if let property = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return property
        }
        return false
    }

    private func notifyServerPowerState(_ state: String) {
        if state == "wake" {
            // Check immediately, and also retry after 400ms in case clamshell sensor lags
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, !self.isLidClosed() else { return }
                self.sendPowerStateRequest("wake")
            }
        }
        if state == "wake" && isLidClosed() {
            fputs("[Android Duo App] Immediate wake suppressed: laptop lid is closed. Scheduled delayed check.\n", stderr)
            return
        }
        sendPowerStateRequest(state)
    }

    private func sendPowerStateRequest(_ state: String) {
        guard let url = URL(string: "http://127.0.0.1:3000/api/power?state=\(state)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0
        URLSession.shared.dataTask(with: request).resume()
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        let appName = "Android Duo"
        appMenu.addItem(withTitle: "О программе \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let hideItem = NSMenuItem(title: "Скрыть \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        
        let hideOthersItem = NSMenuItem(title: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        
        appMenu.addItem(withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Завершить \(appName)", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        
        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Окно")
        windowMenuItem.submenu = windowMenu
        
        let minItem = NSMenuItem(title: "Свернуть", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minItem)
        let closeItem = NSMenuItem(title: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    private func setupSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.quitApplication()
        }
        term.resume()
        self.sigtermSource = term
        
        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler { [weak self] in
            self?.quitApplication()
        }
        intr.resume()
        self.sigintSource = intr
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
        
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AndroidDuoStatusItem"
        item.behavior = [.removalAllowed]
        
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: "Android Duo")
            button.image?.isTemplate = true
            button.title = " Duo"
            button.imagePosition = .imageLeading
            button.toolTip = "Android Duo — нажмите, чтобы открыть меню или вернуть окно дашборда"
        }
        
        let menu = NSMenu()
        updateMenu(menu)
        item.menu = menu
        self.statusItem = item
        
        // Update menu dynamically before it displays
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self, weak menu] _ in
            guard let menu = menu else { return }
            self?.updateMenu(menu)
        }
    }
    
    private func updateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        
        // Update Status Item Button badge in Menu Bar
        if let button = statusItem?.button {
            button.title = " Duo"
            button.toolTip = "Android Duo — \(server.connectionType) • \(server.resolution) • \(server.fps) FPS"
        }
        
        // Header Status
        let statusTitle = server.isConnected ? (server.transport == "usb" ? "🟢 Xiaomi Pad SE: USB ⚡" : "🟢 Xiaomi Pad SE: Wi-Fi 📶") : (server.isRunning ? "🟡 Ожидание планшета..." : "🔴 Сервер остановлен")
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        // Link Quality & Telemetry
        if server.isConnected {
            let channelDetail = server.transport == "usb" 
                ? "⚡ Прямой USB-кабель (127.0.0.1) • Задержка < 1 мс" 
                : "📶 Сеть Wi-Fi (\(server.clientIp.isEmpty ? server.localIP : server.clientIp))"
            let channelItem = NSMenuItem(title: channelDetail, action: nil, keyEquivalent: "")
            channelItem.isEnabled = false
            menu.addItem(channelItem)
            
            let statsTitle = "⚡ \(server.fps) FPS • \(server.resolution) • Поток 90 Гц"
            let statsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
            statsItem.isEnabled = false
            menu.addItem(statsItem)
            
            // Battery Telemetry
            if let batt = server.tabletBattery {
                let battTitle = "🔋 Батарея планшета: \(batt)%" + (server.isTabletCharging ? " ⚡ (Зарядка)" : "")
                let battItem = NSMenuItem(title: battTitle, action: nil, keyEquivalent: "")
                battItem.isEnabled = false
                menu.addItem(battItem)
            }
            if let macBatt = server.macBattery {
                let macTitle = "💻 Батарея MacBook: \(macBatt)%"
                let macItem = NSMenuItem(title: macTitle, action: nil, keyEquivalent: "")
                macItem.isEnabled = false
                menu.addItem(macItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Quick Actions
        let moveWinItem = NSMenuItem(title: "🚀 Перенести активное окно на планшет", action: #selector(moveWindowAction), keyEquivalent: "")
        moveWinItem.target = self
        menu.addItem(moveWinItem)
        
        if server.isAdbConnected {
            let launchItem = NSMenuItem(title: "📱 Запустить приложение на планшете (ADB)", action: #selector(launchTabletAppAction), keyEquivalent: "")
            launchItem.target = self
            menu.addItem(launchItem)
            
            let defaultSubmenu = NSMenu()
            let nativeItem = NSMenuItem(title: "⚡ Android Duo App (Собственный)", action: #selector(setLaunchNativeAction), keyEquivalent: "")
            nativeItem.target = self
            nativeItem.state = server.tabletLaunchTarget == "native" ? .on : .off
            defaultSubmenu.addItem(nativeItem)
            
            let fullyItem = NSMenuItem(title: "🖥 Fully Kiosk Browser", action: #selector(setLaunchFullyAction), keyEquivalent: "")
            fullyItem.target = self
            fullyItem.state = server.tabletLaunchTarget == "fully" ? .on : .off
            defaultSubmenu.addItem(fullyItem)
            
            let webapkItem = NSMenuItem(title: "🌐 Chrome WebAPK / Браузер", action: #selector(setLaunchWebapkAction), keyEquivalent: "")
            webapkItem.target = self
            webapkItem.state = (server.tabletLaunchTarget == "webapk" || server.tabletLaunchTarget == "browser") ? .on : .off
            defaultSubmenu.addItem(webapkItem)
            
            let defaultTargetItem = NSMenuItem(title: "⚙️ Запуск на планшете по умолчанию", action: nil, keyEquivalent: "")
            defaultTargetItem.submenu = defaultSubmenu
            menu.addItem(defaultTargetItem)
            
            let sleepItem = NSMenuItem(title: "🌙 Погасить экран планшета", action: #selector(sleepTabletAction), keyEquivalent: "")
            sleepItem.target = self
            menu.addItem(sleepItem)
            
            let wakeItem = NSMenuItem(title: "☀️ Пробудить экран планшета", action: #selector(wakeTabletAction), keyEquivalent: "")
            wakeItem.target = self
            menu.addItem(wakeItem)
        }
        
        let webItem = NSMenuItem(title: "🌐 Открыть веб-трансляцию в браузере Mac", action: #selector(openWebAction), keyEquivalent: "")
        webItem.target = self
        menu.addItem(webItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Window & Server Management
        let windowToggleItem = NSMenuItem(title: "🪟 Открыть дашборд (Вернуть в Dock)", action: #selector(showWindowFromMenu), keyEquivalent: "o")
        windowToggleItem.target = self
        menu.addItem(windowToggleItem)
        
        let restartItem = NSMenuItem(title: "🔄 Перезапустить видеопоток", action: #selector(restartAction), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)
        
        if !server.hasScreenCapturePermission {
            let permItem = NSMenuItem(title: "⚠️ Требуется «Запись экрана» (Нажмите)", action: #selector(openPermissionsAction), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
        }
        
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
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
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
    // User clicked red 'X': check user's preference
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch mode.windowCloseAction {
        case .quitApp:
            quitApplication()
            return true
        case .minimizeToMenuBar:
            mode.switchToMenuBarOnly()
            return false // don't destroy, just hide and switch to accessory
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitApplication()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        quitApplication()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "🪟 Открыть дашборд", action: #selector(showWindowFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "❌ Завершить Android Duo", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
    
    func quitApplication() {
        guard !isTerminating else { return }
        isTerminating = true
        fputs("[Android Duo App] Quitting Android Duo cleanly...\n", stderr)
        
        // 1. Immediately remove Menu Bar status item
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            self.statusItem = nil
        }
        
        // 2. Hide window and remove from Dock
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        
        // 3. Stop server and clean child processes
        server.stopServer()
        
        // 4. Force exit process cleanly
        exit(0)
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
    
    @objc private func setRes1280x800() { server.changeResolution(width: 1280, height: 800) }
    @objc private func setRes1440x900() { server.changeResolution(width: 1440, height: 900) }
    @objc private func setRes1920x1200() { server.changeResolution(width: 1920, height: 1200) }
    @objc private func setRes2560x1600() { server.changeResolution(width: 2560, height: 1600) }
    @objc private func setRes1024x640() { server.changeResolution(width: 1024, height: 640) }
    
    private func refreshStatusMenu() {
        if let menu = statusItem?.menu {
            updateMenu(menu)
        }
    }

    @objc private func launchTabletAppAction() { server.launchTabletApp() }
    @objc private func setLaunchNativeAction() { server.setTabletLaunchTarget("native"); refreshStatusMenu() }
    @objc private func setLaunchFullyAction() { server.setTabletLaunchTarget("fully"); refreshStatusMenu() }
    @objc private func setLaunchWebapkAction() { server.setTabletLaunchTarget("webapk"); refreshStatusMenu() }
    @objc private func sleepTabletAction() { server.sendPowerState("sleep") }
    @objc private func wakeTabletAction() { server.sendPowerState("wake") }
    
    @objc private func restartAction() {
        server.restartServer()
    }
    
    @objc private func quitAction() {
        quitApplication()
    }
}

// MARK: - Entrypoint
@main
struct AndroidDuoAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}
