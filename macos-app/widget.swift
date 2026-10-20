import WidgetKit
import SwiftUI
import IOKit.ps
import MachO

// MARK: - Telemetry Snapshot
struct DuoHwSnapshot {
    var cpuPercent: Int = 12
    var ramText: String = "5.9 / 8.0 GB"
    var ramPct: Int = 74
    var netSpeed: String = "0.0 MB/s"
    var tempText: String = "36°C"
    var macBattery: Int? = 50
    var isMacCharging: Bool = false
    var tabletBattery: Int? = nil
    var isTabletCharging: Bool = false
    var isDuoRunning: Bool = false
    var fps: Int = 0
    
    static func current() -> DuoHwSnapshot {
        var snap = DuoHwSnapshot()
        
        // 1. RAM Usage
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
            snap.ramText = String(format: "%.1f / %.1f GB", usedGB, totalGB)
            snap.ramPct = Int(round((usedGB / max(1.0, totalGB)) * 100.0))
        }
        
        // 2. Battery
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                    if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                       let isCharging = desc[kIOPSIsChargingKey as String] as? Bool {
                        snap.macBattery = current
                        snap.isMacCharging = isCharging
                        break
                    }
                }
            }
        }
        
        // 3. CPU estimation via host_processor_info
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &processorInfoCount)
        if result == KERN_SUCCESS, let cpuInfo = processorInfo {
            var totalUser: Int64 = 0
            var totalSystem: Int64 = 0
            var totalIdle: Int64 = 0
            for i in 0..<Int(processorCount) {
                totalUser += Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_USER)])
                totalSystem += Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_SYSTEM)])
                totalIdle += Int64(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_IDLE)])
            }
            let total = totalUser + totalSystem + totalIdle
            if total > 0 {
                let pct = Int(round(Double(totalUser + totalSystem) / Double(total) * 100.0))
                snap.cpuPercent = max(5, min(100, pct))
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), vm_size_t(processorInfoCount * UInt32(MemoryLayout<integer_t>.size)))
        }
        
        // 4. Try reading Android Duo local info if active
        if let url = URL(string: "http://127.0.0.1:3000/api/info") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 0.4
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    snap.isDuoRunning = true
                    if let fps = json["fps"] as? Int { snap.fps = fps }
                    if let bat = json["battery"] as? [String: Any] {
                        snap.tabletBattery = bat["tablet"] as? Int
                        snap.isTabletCharging = bat["tabletCharging"] as? Bool ?? false
                    }
                    if let hw = json["hw"] as? [String: Any] {
                        if let cpu = hw["cpu"] as? Int { snap.cpuPercent = cpu }
                        if let net = hw["netSpeed"] as? String { snap.netSpeed = net }
                        if let temp = hw["tempMac"] as? String ?? hw["tempDisplay"] as? String { snap.tempText = temp }
                    }
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 0.45)
        }
        
        return snap
    }
}

// MARK: - Widget Timeline Entry
struct DuoWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: DuoHwSnapshot
}

// MARK: - Timeline Provider
struct DuoTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> DuoWidgetEntry {
        DuoWidgetEntry(date: Date(), snapshot: DuoHwSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (DuoWidgetEntry) -> Void) {
        let entry = DuoWidgetEntry(date: Date(), snapshot: DuoHwSnapshot.current())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DuoWidgetEntry>) -> Void) {
        let currentEntry = DuoWidgetEntry(date: Date(), snapshot: DuoHwSnapshot.current())
        // Refresh every minute as allowed by macOS WidgetKit policy
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date().addingTimeInterval(60)
        let timeline = Timeline(entries: [currentEntry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Pixel Progress Bar Helper
private func pixelBar(percent: Int, length: Int = 8) -> String {
    let p = max(0, min(100, percent))
    let filled = max(0, min(length, Int(round(Double(p) / 100.0 * Double(length)))))
    let empty = max(0, length - filled)
    return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
}

// MARK: - Widget Views
struct DuoWidgetMediumView: View {
    let s: DuoHwSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
                Text("─╮")
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
            }
            
            // CPU
            HStack(spacing: 4) {
                Text("│ CPU")
                    .foregroundColor(.secondary)
                Text("[\(pixelBar(percent: s.cpuPercent, length: 7))]")
                    .foregroundColor(s.cpuPercent > 80 ? .red : (s.cpuPercent > 50 ? .orange : Color(red: 0.30, green: 0.85, blue: 0.55)))
                Text("\(s.cpuPercent)%")
                    .foregroundColor(.white)
                Spacer()
                Text("Apple M2")
                    .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.75))
                Text("│")
                    .foregroundColor(.secondary)
            }
            
            // RAM
            HStack(spacing: 4) {
                Text("│ RAM")
                    .foregroundColor(.secondary)
                Text("[\(pixelBar(percent: s.ramPct, length: 7))]")
                    .foregroundColor(Color(red: 0.35, green: 0.75, blue: 0.98))
                Text(s.ramText)
                    .foregroundColor(.white)
                Spacer()
                Text("\(s.ramPct)%")
                    .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.75))
                Text("│")
                    .foregroundColor(.secondary)
            }
            
            // NET / STREAM
            HStack(spacing: 4) {
                Text("│ NET")
                    .foregroundColor(.secondary)
                Text(s.netSpeed)
                    .foregroundColor(.white)
                Spacer()
                Text(s.isDuoRunning ? "\(s.fps) FPS" : "STANDBY")
                    .foregroundColor(s.isDuoRunning ? Color(red: 0.35, green: 0.85, blue: 0.65) : .secondary)
                Text("│")
                    .foregroundColor(.secondary)
            }
            
            // POWER
            let macIcon = s.isMacCharging ? "⚡" : ""
            let tabIcon = s.isTabletCharging ? "⚡" : ""
            HStack(spacing: 4) {
                Text("│ PWR")
                    .foregroundColor(.secondary)
                Text("Mac: \(s.macBattery != nil ? "\(s.macBattery!)%" : "--")\(macIcon)")
                    .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.45))
                Text("·")
                    .foregroundColor(.secondary)
                Text("Pad: \(s.tabletBattery != nil ? "\(s.tabletBattery!)%" : "OFF")\(tabIcon)")
                    .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.45))
                Spacer()
                Text(s.isDuoRunning ? "DUO" : "IDLE")
                    .foregroundColor(s.isDuoRunning ? .green : .secondary)
                Text("│")
                    .foregroundColor(.secondary)
            }
            
            // Footer border
            HStack {
                Text("╰────────────────────────────────────╯")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
            }
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .padding(8)
    }
}

struct DuoWidgetSmallView: View {
    let s: DuoHwSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("╭ DUO // HUD ╮")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(Color(red: 0.98, green: 0.65, blue: 0.35))
            }
            
            Text("CPU \(s.cpuPercent)% [\(pixelBar(percent: s.cpuPercent, length: 4))]")
                .foregroundColor(s.cpuPercent > 80 ? .red : Color(red: 0.30, green: 0.85, blue: 0.55))
            
            Text("RAM \(s.ramPct)% [\(pixelBar(percent: s.ramPct, length: 4))]")
                .foregroundColor(Color(red: 0.35, green: 0.75, blue: 0.98))
            
            Text("TMP \(s.tempText)")
                .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.95))
            
            Text("MAC \(s.macBattery != nil ? "\(s.macBattery!)%" : "--")\(s.isMacCharging ? "⚡" : "")")
                .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.45))
            
            HStack {
                Text("╰────────────╯")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.88, green: 0.55, blue: 0.28))
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        .padding(6)
    }
}

struct DuoWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: DuoTimelineProvider.Entry

    var body: some View {
        Group {
            if family == .systemSmall {
                DuoWidgetSmallView(s: entry.snapshot)
            } else {
                DuoWidgetMediumView(s: entry.snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12))
    }
}

// MARK: - Main Widget Declaration
@main
struct AndroidDuoWidget: Widget {
    let kind: String = "com.androidduo.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DuoTimelineProvider()) { entry in
            DuoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Android Duo // HUD")
        .description("Пиксельный монитор железа Mac M2 и планшета в стиле Claude Code.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
