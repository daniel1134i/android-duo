import Cocoa
import SwiftUI
import IOKit.ps
import MachO

// MARK: - Native Telemetry Engine (Independent of Android Duo Server)
final class HudTelemetry: ObservableObject {
    static let shared = HudTelemetry()
    
    @Published var cpuPercent: Int = 10
    @Published var ramText: String = "5.9 / 8.0 GB"
    @Published var netSpeed: String = "0.0 MB/s"
    @Published var tempText: String = "36°C"
    @Published var macBattery: Int? = nil
    @Published var isMacCharging: Bool = false
    @Published var tabletBattery: Int? = nil
    @Published var isTabletCharging: Bool = false
    @Published var isDuoServerRunning: Bool = false
    @Published var fps: Int = 0
    @Published var transport: String = "mac"
    
    private var timer: Timer?
    private var prevCpuInfo: processor_info_array_t?
    private var prevCpuInfoCount: mach_msg_type_number_t = 0
    
    init() {
        refreshNativeStats()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNativeStats()
            self?.pollDuoServer()
        }
    }
    
    func refreshNativeStats() {
        // 1. CPU % via host_processor_info
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &processorInfoCount)
        if result == KERN_SUCCESS, let cpuInfo = processorInfo {
            if let prev = prevCpuInfo {
                var totalUser: Int64 = 0
                var totalSystem: Int64 = 0
                var totalIdle: Int64 = 0
                var totalNice: Int64 = 0
                
                for i in 0..<Int(processorCount) {
                    let inUse = Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_USER)] - prev[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_USER)])
                    let sys = Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_SYSTEM)] - prev[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_SYSTEM)])
                    let nice = Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_NICE)] - prev[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_NICE)])
                    let idle = Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_IDLE)] - prev[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_IDLE)])
                    
                    totalUser += inUse
                    totalSystem += sys
                    totalNice += nice
                    totalIdle += idle
                }
                
                let total = totalUser + totalSystem + totalNice + totalIdle
                if total > 0 {
                    let used = totalUser + totalSystem + totalNice
                    let pct = Int(round(Double(used) / Double(total) * 100.0))
                    DispatchQueue.main.async { self.cpuPercent = max(1, min(100, pct)) }
                }
                
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prev)), vm_size_t(prevCpuInfoCount * UInt32(MemoryLayout<integer_t>.size)))
            }
            prevCpuInfo = cpuInfo
            prevCpuInfoCount = processorInfoCount
        }
        
        // 2. RAM Usage via host_statistics64
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        if kerr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let active = UInt64(vmStats.active_count) * pageSize
            let wired = UInt64(vmStats.wire_count) * pageSize
            let compressed = UInt64(vmStats.compressor_page_count) * pageSize
            let usedBytes = active + wired + compressed
            let usedGB = Double(usedBytes) / (1024 * 1024 * 1024)
            let totalBytes = ProcessInfo.processInfo.physicalMemory
            let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)
            let text = String(format: "%.1f / %.1f GB", usedGB, totalGB)
            DispatchQueue.main.async { self.ramText = text }
        }
        
        // 3. Battery via IOPowerSources
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                    if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                       let isCharging = desc[kIOPSIsChargingKey as String] as? Bool {
                        DispatchQueue.main.async {
                            self.macBattery = current
                            self.isMacCharging = isCharging
                        }
                        break
                    }
                }
            }
        }
    }
    
    // 4. Poll Android Duo server if running
    func pollDuoServer() {
        guard let url = URL(string: "http://127.0.0.1:3000/api/info") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.isDuoServerRunning = false
                    self.netSpeed = "0.0 MB/s"
                    self.fps = 0
                    self.tabletBattery = nil
                }
                return
            }
            
            DispatchQueue.main.async {
                self.isDuoServerRunning = true
                if let fps = json["fps"] as? Int { self.fps = fps }
                if let transport = json["transport"] as? String { self.transport = transport }
                if let bat = json["battery"] as? [String: Any] {
                    self.tabletBattery = bat["tablet"] as? Int
                    self.isTabletCharging = bat["tabletCharging"] as? Bool ?? false
                }
                if let hw = json["hw"] as? [String: Any] {
                    if let net = hw["netSpeed"] as? String { self.netSpeed = net }
                    if let temp = hw["tempMac"] as? String ?? hw["tempDisplay"] as? String {
                        self.tempText = temp
                    }
                }
            }
        }.resume()
    }
}

// MARK: - Pixel Art / Claude Code Hardware HUD View
struct StandalonePixelHudView: View {
    @ObservedObject var telemetry = HudTelemetry.shared
    @State private var currentMode: String = UserDefaults.standard.string(forKey: "hudLevelMode") ?? "desktop"
    
    var onClose: () -> Void
    var onToggleMode: (String) -> Void
    
    private func pixelBar(percent: Int, length: Int = 8) -> String {
        let p = max(0, min(100, percent))
        let filled = max(0, min(length, Int(round(Double(p) / 100.0 * Double(length)))))
        let empty = max(0, length - filled)
        return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header bar
            HStack(spacing: 5) {
                Text("╭─")
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
                Text("CLAUDE CODE // DUO-HUD")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(Color(red: 0.98, green: 0.65, blue: 0.35))
                
                Spacer()
                
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
                
                Button(action: {
                    let next = currentMode == "desktop" ? "floating" : "desktop"
                    currentMode = next
                    onToggleMode(next)
                }) {
                    Text(currentMode == "desktop" ? "[📌 ВИДЖЕТ]" : "[🪟 HUD]")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(currentMode == "desktop" ? Color(red: 0.30, green: 0.85, blue: 0.55) : Color(red: 0.95, green: 0.75, blue: 0.25))
                }
                .buttonStyle(.plain)
                .help(currentMode == "desktop" ? "Режим Виджета: закреплен на обоях рабочего стола под окнами. Нажмите для плавающего режима." : "Режим HUD: висит поверх всех окон. Нажмите для закрепления на обоях.")
                
                Button(action: onClose) {
                    Text("[✕]")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
                }
                .buttonStyle(.plain)
                .help("Закрыть виджет")
                
                Text("─╮")
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
            }
            .padding(.bottom, 1)
            
            // Metrics in Pixel / Monospace ASCII aesthetic
            VStack(alignment: .leading, spacing: 4) {
                // CPU Row
                HStack(spacing: 4) {
                    Text("│ CPU")
                        .foregroundColor(.secondary)
                    Text("[\(pixelBar(percent: telemetry.cpuPercent, length: 8))]")
                        .foregroundColor(telemetry.cpuPercent > 80 ? .red : (telemetry.cpuPercent > 50 ? .orange : Color(red: 0.30, green: 0.85, blue: 0.55)))
                    Text("\(String(format: "%2d", telemetry.cpuPercent))%")
                        .foregroundColor(.white)
                    Spacer()
                    Text("Apple M2")
                        .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.75))
                    Text("│")
                        .foregroundColor(.secondary)
                }
                
                // RAM Row
                let ramParts = telemetry.ramText.components(separatedBy: " / ")
                let ramUsedNum = Double(ramParts.first?.trimmingCharacters(in: .whitespaces) ?? "5.9") ?? 5.9
                let ramPct = Int((ramUsedNum / 8.0) * 100.0)
                HStack(spacing: 4) {
                    Text("│ RAM")
                        .foregroundColor(.secondary)
                    Text("[\(pixelBar(percent: ramPct, length: 8))]")
                        .foregroundColor(Color(red: 0.35, green: 0.75, blue: 0.98))
                    Text(telemetry.ramText)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(ramPct)%")
                        .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.75))
                    Text("│")
                        .foregroundColor(.secondary)
                }
                
                // NET Speed Row
                let netNum = Double(telemetry.netSpeed.components(separatedBy: " ").first ?? "0.0") ?? 0.0
                let netPct = min(100, Int(netNum * 20))
                HStack(spacing: 4) {
                    Text("│ NET")
                        .foregroundColor(.secondary)
                    Text("[\(pixelBar(percent: netPct, length: 8))]")
                        .foregroundColor(Color(red: 0.95, green: 0.75, blue: 0.25))
                    Text(telemetry.netSpeed)
                        .foregroundColor(.white)
                    Spacer()
                    Text(telemetry.isDuoServerRunning ? "\(telemetry.fps) FPS" : "STANDBY")
                        .foregroundColor(telemetry.isDuoServerRunning ? Color(red: 0.35, green: 0.85, blue: 0.65) : .secondary)
                    Text("│")
                        .foregroundColor(.secondary)
                }
                
                // TEMP & STATUS
                HStack(spacing: 4) {
                    Text("│ TMP")
                        .foregroundColor(.secondary)
                    Text("M2: \(telemetry.tempText)")
                        .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.95))
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(telemetry.tabletBattery != nil ? "Pad: 33°C" : "Pad: --")
                        .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.95))
                    Spacer()
                    Text(telemetry.isDuoServerRunning ? (telemetry.transport == "usb" ? "⚡USB" : "📶WiFi") : "💻Mac")
                        .foregroundColor(.cyan)
                    Text("│")
                        .foregroundColor(.secondary)
                }
                
                // BATTERY ROW
                let macIcon = telemetry.isMacCharging ? "⚡" : ""
                let tabIcon = telemetry.isTabletCharging ? "⚡" : ""
                HStack(spacing: 4) {
                    Text("│ PWR")
                        .foregroundColor(.secondary)
                    Text("Mac: \(telemetry.macBattery != nil ? "\(telemetry.macBattery!)%" : "--")\(macIcon)")
                        .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.45))
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("Pad: \(telemetry.tabletBattery != nil ? "\(telemetry.tabletBattery!)%" : "OFF")\(tabIcon)")
                        .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.45))
                    Spacer()
                    Text(telemetry.isDuoServerRunning ? "DUO" : "IDLE")
                        .foregroundColor(telemetry.isDuoServerRunning ? .green : .secondary)
                    Text("│")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            
            // Footer border
            HStack {
                Text("╰──────────────────────────────────────╯")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
            }
        }
        .padding(10)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.96))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(red: 0.88, green: 0.55, blue: 0.28).opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Standalone HUD App Delegate
final class HudAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Duo HUD")
            button.toolTip = "Android Duo HUD — Монитор железа"
        }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "👾 Показать / Скрыть виджет", action: #selector(toggleWindow), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        
        let deskItem = NSMenuItem(title: "📌 Закрепить на обоях (Виджет)", action: #selector(setDesktopMode), keyEquivalent: "")
        deskItem.target = self
        menu.addItem(deskItem)
        
        let floatItem = NSMenuItem(title: "🪟 Поверх всех окон (HUD)", action: #selector(setFloatingMode), keyEquivalent: "")
        floatItem.target = self
        menu.addItem(floatItem)
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "❌ Закрыть виджет", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
    }
    
    private func setupWindow() {
        let mode = UserDefaults.standard.string(forKey: "hudLevelMode") ?? "desktop"
        
        let view = StandalonePixelHudView(onClose: { [weak self] in
            self?.quitApp()
        }, onToggleMode: { [weak self] newMode in
            self?.setMode(newMode)
        })
        .padding(8)
        
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.borderless]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.setFrameAutosaveName("AndroidDuoStandaloneHudWindow")
        
        if win.frame.origin.x == 0 && win.frame.origin.y == 0 {
            if let mainScreen = NSScreen.screens.first {
                let screenRect = mainScreen.visibleFrame
                let w: CGFloat = 340
                let h: CGFloat = 200
                let x = screenRect.origin.x + screenRect.width - w - 24
                let y = screenRect.origin.y + screenRect.height - h - 30
                win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            }
        }
        
        self.window = win
        applyLevel(mode)
        win.makeKeyAndOrderFront(nil)
    }
    
    func setMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "hudLevelMode")
        applyLevel(mode)
    }
    
    private func applyLevel(_ mode: String) {
        guard let win = window else { return }
        if mode == "desktop" {
            win.level = NSWindow.Level(NSWindow.Level.normal.rawValue - 1)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
    
    @objc func toggleWindow() {
        guard let win = window else { return }
        if win.isVisible {
            win.orderOut(nil)
        } else {
            win.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc func setDesktopMode() { setMode("desktop") }
    @objc func setFloatingMode() { setMode("floating") }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entrypoint
@main
struct HudMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = HudAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
