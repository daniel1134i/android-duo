import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreVideo
import ApplicationServices
import CoreMedia
import Metal

// Protocol Magic & Packet Types
let MAGIC_BYTE: UInt8 = 0xFD
let TYPE_JPEG: UInt8 = 0x01
let TYPE_JSON: UInt8 = 0x02

// MARK: - Screen Capture Streamer
@available(macOS 12.3, *)
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let stdoutHandle = FileHandle.standardOutput
    private let writeQueue = DispatchQueue(label: "com.macduo.stream.write", qos: .userInteractive)
    private let stdoutLock = NSLock()
    private let encodeLock = NSLock()
    
    var currentDisplayID: CGDirectDisplayID = 0
    var targetFPS: Int = 90
    var quality: Float = 0.90
    var targetWidth: Int = 0
    var targetHeight: Int = 0
    var lastFrameDate = Date()
    private var isCapturing = false
    var availableDisplays: [SCDisplay] = []
    
    func writePacket(_ packet: Data) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        try? stdoutHandle.write(contentsOf: packet)
    }
    
    override init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        } else {
            self.ciContext = CIContext(options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
        super.init()
    }
    
    func start(preferredDisplayID: CGDirectDisplayID? = nil, fps: Int = 60, quality: Float = 0.90) async throws {
        self.targetFPS = fps
        self.quality = quality
        
        var display: SCDisplay? = nil
        
        // Retry loop to ensure ScreenCaptureKit registers the newly created virtual display
        for attempt in 1...15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays
            let ids = content.displays.map { "\($0.displayID): \($0.width)x\($0.height)" }.joined(separator: ", ")
            fputs("[mac_host] Attempt \(attempt) displays: [\(ids)] (looking for \(preferredDisplayID ?? 0))\n", stderr)
            
            if let preferred = preferredDisplayID, let found = content.displays.first(where: { $0.displayID == preferred }) {
                fputs("[mac_host] Found preferred virtual display ID \(preferred) on attempt \(attempt)\n", stderr)
                display = found
                break
            } else if let secondary = content.displays.first(where: { $0.displayID != CGMainDisplayID() }) {
                fputs("[mac_host] Found secondary display ID \(secondary.displayID) on attempt \(attempt)\n", stderr)
                display = secondary
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        
        if display == nil {
            if let main = self.availableDisplays.first(where: { $0.displayID == CGMainDisplayID() }) {
                fputs("[mac_host] Falling back to main display ID \(main.displayID)\n", stderr)
                display = main
            } else if let first = self.availableDisplays.first {
                display = first
            } else {
                throw NSError(domain: "MacDuo", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
        }
        
        try await activateDisplay(display!)
    }
    
    func activateDisplay(_ display: SCDisplay) async throws {
        if isCapturing {
            await stop()
        }
        
        self.currentDisplayID = display.displayID
        
        let captureWidth = display.width
        let captureHeight = display.height
        
        self.targetWidth = captureWidth
        self.targetHeight = captureHeight
        
        // Notify host and web client about active display and list of all displays
        var displayList: [[String: Any]] = []
        for d in self.availableDisplays {
            let isMain = (d.displayID == CGMainDisplayID())
            let name = isMain ? "Mac Main Display" : "Xiaomi Pad SE (Dual Screen)"
            displayList.append([
                "id": d.displayID,
                "name": name,
                "width": d.width,
                "height": d.height,
                "primary": isMain,
                "active": (d.displayID == display.displayID)
            ])
        }
        
        sendJSON([
            "type": "display_info",
            "displayID": display.displayID,
            "width": captureWidth,
            "height": captureHeight,
            "screenWidth": captureWidth,
            "screenHeight": captureHeight,
            "fps": self.targetFPS,
            "displays": displayList
        ])
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.targetFPS))
        config.queueDepth = 2
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writeQueue)
        try await newStream.startCapture()
        
        self.stream = newStream
        self.isCapturing = true
        
        fputs("[mac_host] Ultra-Crisp Screen Capture active: \(captureWidth)x\(captureHeight) @ \(self.targetFPS)fps (Quality: \(self.quality))\n", stderr)
    }
    
    func switchDisplay(id: CGDirectDisplayID) async {
        guard id > 0 else { return }
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            self.availableDisplays = content.displays
        }
        guard let target = self.availableDisplays.first(where: { $0.displayID == id }) else {
            fputs("[mac_host] Display ID \(id) not found in available displays\n", stderr)
            return
        }
        do {
            try await activateDisplay(target)
        } catch {
            fputs("[mac_host] Failed to switch display: \(error.localizedDescription)\n", stderr)
        }
    }
    
    func stop() async {
        guard let s = stream, isCapturing else { return }
        do {
            try await s.stopCapture()
        } catch {
            fputs("[mac_host] Stop error: \(error.localizedDescription)\n", stderr)
        }
        self.stream = nil
        self.isCapturing = false
    }
    
    func updateConfig(fps: Int?, quality: Float?) {
        if let fps = fps, fps > 0, fps != self.targetFPS {
            self.targetFPS = fps
            if let s = stream {
                let config = SCStreamConfiguration()
                config.width = self.targetWidth
                config.height = self.targetHeight
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.queueDepth = 2
                config.showsCursor = true
                config.pixelFormat = kCVPixelFormatType_32BGRA
                s.updateConfiguration(config) { err in
                    if let err = err { fputs("[mac_host] Update config error: \(err)\n", stderr) }
                }
            }
        }
        if let q = quality, q > 0.1 && q <= 1.0 {
            self.quality = q
        }
    }
    
    func updateResolution(width: Int, height: Int) async {
        guard width > 0 && height > 0 else { return }
        let ok = set_virtual_display_mode(UInt32(width), UInt32(height), Double(self.targetFPS))
        if !ok {
            fputs("[mac_host] Warning: set_virtual_display_mode failed for \(width)x\(height)\n", stderr)
        }
        self.targetWidth = width
        self.targetHeight = height
        
        if let s = stream {
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.targetFPS))
            config.queueDepth = 2
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            s.updateConfiguration(config) { err in
                if let err = err { fputs("[mac_host] Stream update error: \(err)\n", stderr) }
            }
        }
        
        sendJSON([
            "type": "display_info",
            "displayID": self.currentDisplayID,
            "width": width,
            "height": height,
            "screenWidth": width,
            "screenHeight": height,
            "fps": self.targetFPS
        ])
        fputs("[mac_host] Stream resolution dynamically updated: \(width)x\(height)\n", stderr)
    }
    
    // MARK: - SCStreamOutput
    private var sampleCount: Int = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        guard encodeLock.try() else { return }
        defer { encodeLock.unlock() }
        
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let opts: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): self.quality
            ]
            
            guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: opts) else {
                return
            }
            
            self.lastFrameDate = Date()
            
            // Write packet: [MAGIC][TYPE_JPEG][LEN (4 bytes BE)][JPEG DATA]
            var packet = Data(capacity: 6 + jpegData.count)
            packet.append(MAGIC_BYTE)
            packet.append(TYPE_JPEG)
            var length = UInt32(jpegData.count).bigEndian
            packet.append(Data(bytes: &length, count: 4))
            packet.append(jpegData)
            
            writePacket(packet)
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[mac_host] Stream stopped with error: \(error.localizedDescription). Auto-recovering in 1s...\n", stderr)
        self.isCapturing = false
        self.stream = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await self.start(preferredDisplayID: self.currentDisplayID != 0 ? self.currentDisplayID : nil,
                                     fps: self.targetFPS,
                                     quality: self.quality)
                fputs("[mac_host] Stream successfully auto-recovered and resumed!\n", stderr)
            } catch {
                fputs("[mac_host] Stream auto-recovery failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
    
    func sendJSON(_ dict: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        let data = jsonStr.data(using: .utf8)!
        var packet = Data(capacity: 6 + data.count)
        packet.append(MAGIC_BYTE)
        packet.append(TYPE_JSON)
        var length = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(data)
        writePacket(packet)
    }
}

// MARK: - Native Input Synthesizer (with Multi-Monitor Coordinate Mapping)
final class InputSynthesizer {
    var activeDisplayID: CGDirectDisplayID = 0
    private var lastPos = CGPoint(x: 0, y: 0)
    
    func getDisplayBounds() -> CGRect {
        if activeDisplayID != 0 {
            let bounds = CGDisplayBounds(activeDisplayID)
            if !bounds.isNull && bounds.width > 0 {
                return bounds
            }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }
    
    private func mapToGlobalCoords(_ cmd: [String: Any]) -> CGPoint {
        let bounds = getDisplayBounds()
        
        // Prevent macOS Dock jumping to secondary display:
        // Clamping by 25 points (maxY - 25.0) prevents any synthetic touch/click from triggering Dock relocation
        let minX = bounds.origin.x
        let maxX = bounds.origin.x + bounds.width - 1.0
        let minY = bounds.origin.y
        let maxY = bounds.origin.y + bounds.height - 25.0
        
        if let normX = cmd["normX"] as? Double, let normY = cmd["normY"] as? Double {
            let gx = min(maxX, max(minX, bounds.origin.x + CGFloat(normX) * bounds.width))
            let gy = min(maxY, max(minY, bounds.origin.y + CGFloat(normY) * bounds.height))
            return CGPoint(x: gx, y: gy)
        }
        
        if let x = cmd["x"] as? Double, let y = cmd["y"] as? Double {
            let gx = min(maxX, max(minX, bounds.origin.x + CGFloat(x)))
            let gy = min(maxY, max(minY, bounds.origin.y + CGFloat(y)))
            return CGPoint(x: gx, y: gy)
        }
        
        return lastPos
    }
    
    func handleCommand(_ cmd: [String: Any]) {
        guard let type = cmd["type"] as? String else { return }
        
        switch type {
        case "move":
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            postMouseEvent(.mouseMoved, pt: pt, button: .left)
            
        case "move_relative":
            let dx = (cmd["dx"] as? Double) ?? 0.0
            let dy = (cmd["dy"] as? Double) ?? 0.0
            let bounds = getDisplayBounds()
            let newX = min(bounds.origin.x + bounds.width - 3.0, max(bounds.origin.x, lastPos.x + CGFloat(dx)))
            let newY = min(bounds.origin.y + bounds.height - 3.0, max(bounds.origin.y, lastPos.y + CGFloat(dy)))
            lastPos = CGPoint(x: newX, y: newY)
            postMouseEvent(.mouseMoved, pt: lastPos, button: .left)
            
        case "down", "mousedown":
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            let btn = (cmd["button"] as? String) ?? "left"
            let eventType: CGEventType = (btn == "right") ? .rightMouseDown : .leftMouseDown
            let cgBtn: CGMouseButton = (btn == "right") ? .right : .left
            postMouseEvent(eventType, pt: pt, button: cgBtn)
            
        case "up", "mouseup":
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            let btn = (cmd["button"] as? String) ?? "left"
            let eventType: CGEventType = (btn == "right") ? .rightMouseUp : .leftMouseUp
            let cgBtn: CGMouseButton = (btn == "right") ? .right : .left
            postMouseEvent(eventType, pt: pt, button: cgBtn)
            
        case "click":
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            let btn = (cmd["button"] as? String) ?? "left"
            let count = Int64((cmd["count"] as? Int) ?? 1)
            let downType: CGEventType = (btn == "right") ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = (btn == "right") ? .rightMouseUp : .leftMouseUp
            let cgBtn: CGMouseButton = (btn == "right") ? .right : .left
            postMouseEvent(downType, pt: pt, button: cgBtn, clickCount: count)
            usleep(10_000)
            postMouseEvent(upType, pt: pt, button: cgBtn, clickCount: count)
            
        case "drag":
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            postMouseEvent(.leftMouseDragged, pt: pt, button: .left)
            
        case "scroll":
            let dx = (cmd["dx"] as? Double) ?? 0.0
            let dy = (cmd["dy"] as? Double) ?? 0.0
            let pt = mapToGlobalCoords(cmd)
            lastPos = pt
            postScrollEvent(dx: dx, dy: dy, pt: pt)
            
        case "key":
            var macKeyCode: UInt16? = nil
            if let directMac = (cmd["macKeyCode"] as? NSNumber)?.uint16Value ?? (cmd["macKeyCode"] as? UInt16) {
                macKeyCode = directMac
            } else if let codeStr = cmd["code"] as? String, let code = InputSynthesizer.codeStringToMacKeyCodeMap[codeStr] {
                macKeyCode = code
            } else if let keyStr = cmd["key"] as? String, let code = InputSynthesizer.codeStringToMacKeyCodeMap[keyStr] {
                macKeyCode = code
            } else if let rawCode = (cmd["keyCode"] as? NSNumber)?.uint16Value ?? (cmd["keyCode"] as? UInt16) {
                macKeyCode = InputSynthesizer.webToMacKeyCodeMap[rawCode] ?? rawCode
            }
            if let finalCode = macKeyCode, let down = cmd["down"] as? Bool {
                postKeyEvent(keyCode: finalCode, down: down)
            }
            
        case "shortcut":
            if let name = cmd["name"] as? String {
                executeShortcut(name)
            }
            
        default:
            break
        }
    }
    
    private func postMouseEvent(_ type: CGEventType, pt: CGPoint, button: CGMouseButton, clickCount: Int64 = 1) {
        CGWarpMouseCursorPosition(pt)
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
        ev.post(tap: .cgSessionEventTap)
    }
    
    private func postScrollEvent(dx: Double, dy: Double, pt: CGPoint) {
        // Natural scrolling on macOS: dragging content down pulls viewport down
        let scrollY = Int32(dy * 2.0)
        let scrollX = Int32(dx * 2.0)
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: scrollY, wheel2: scrollX, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.location = pt
        ev.post(tap: .cgSessionEventTap)
    }
    
    private static let webToMacKeyCodeMap: [UInt16: UInt16] = [
        13: 0x24,  // Enter -> kVK_Return
        8: 0x33,   // Backspace -> kVK_Delete
        9: 0x30,   // Tab -> kVK_Tab
        32: 0x31,  // Space -> kVK_Space
        27: 0x35,  // Escape -> kVK_Escape
        37: 0x7B,  // Left Arrow -> kVK_LeftArrow
        38: 0x7E,  // Up Arrow -> kVK_UpArrow
        39: 0x7C,  // Right Arrow -> kVK_RightArrow
        40: 0x7D,  // Down Arrow -> kVK_DownArrow
        46: 0x75,  // Forward Delete -> kVK_ForwardDelete
        // Letters: A-Z (Web 65-90)
        65: 0x00, 66: 0x0B, 67: 0x08, 68: 0x02, 69: 0x0E, 70: 0x03, 71: 0x05, 72: 0x04,
        73: 0x22, 74: 0x26, 75: 0x28, 76: 0x25, 77: 0x2E, 78: 0x2D, 79: 0x1F, 80: 0x23,
        81: 0x0C, 82: 0x0F, 83: 0x01, 84: 0x11, 85: 0x20, 86: 0x09, 87: 0x0D, 88: 0x07,
        89: 0x10, 90: 0x06,
        // Digits: 0-9 (Web 48-57)
        48: 0x1D, 49: 0x12, 50: 0x13, 51: 0x14, 52: 0x15, 53: 0x17, 54: 0x16, 55: 0x1A, 56: 0x1C, 57: 0x19,
        // Punctuation
        186: 0x29, 187: 0x18, 188: 0x2B, 189: 0x1B, 190: 0x2F, 191: 0x2C, 192: 0x32,
        219: 0x21, 220: 0x2A, 221: 0x1E, 222: 0x27
    ]

    private static let codeStringToMacKeyCodeMap: [String: UInt16] = [
        "Enter": 0x24, "Return": 0x24, "NumpadEnter": 0x4C,
        "Backspace": 0x33,
        "Tab": 0x30,
        "Space": 0x31, " ": 0x31,
        "Escape": 0x35, "Esc": 0x35,
        "Delete": 0x75,
        "ArrowLeft": 0x7B, "Left": 0x7B,
        "ArrowUp": 0x7E, "Up": 0x7E,
        "ArrowRight": 0x7C, "Right": 0x7C,
        "ArrowDown": 0x7D, "Down": 0x7D,
        "KeyA": 0x00, "KeyB": 0x0B, "KeyC": 0x08, "KeyD": 0x02, "KeyE": 0x0E,
        "KeyF": 0x03, "KeyG": 0x05, "KeyH": 0x04, "KeyI": 0x22, "KeyJ": 0x26,
        "KeyK": 0x28, "KeyL": 0x25, "KeyM": 0x2E, "KeyN": 0x2D, "KeyO": 0x1F,
        "KeyP": 0x23, "KeyQ": 0x0C, "KeyR": 0x0F, "KeyS": 0x01, "KeyT": 0x11,
        "KeyU": 0x20, "KeyV": 0x09, "KeyW": 0x0D, "KeyX": 0x07, "KeyY": 0x10, "KeyZ": 0x06,
        "Digit0": 0x1D, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15,
        "Digit5": 0x17, "Digit6": 0x16, "Digit7": 0x1A, "Digit8": 0x1C, "Digit9": 0x19
    ]
    
    private func postKeyEvent(keyCode: UInt16, down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        ev.post(tap: .cgSessionEventTap)
    }
    
    private func executeShortcut(_ name: String) {
        switch name.lowercased() {
        case "mission_control":
            postKeyWithModifier(keyCode: 0x7E, modifier: .maskControl) // Control+Up
        case "show_desktop":
            postKeyEvent(keyCode: 0x67, down: true) // F11
            usleep(20_000)
            postKeyEvent(keyCode: 0x67, down: false)
        case "copy", "cmd+c":
            postKeyWithModifier(keyCode: 0x08, modifier: .maskCommand) // Cmd+C (C = 0x08)
        case "paste", "cmd+v":
            postKeyWithModifier(keyCode: 0x09, modifier: .maskCommand) // Cmd+V (V = 0x09)
        case "undo", "cmd+z":
            postKeyWithModifier(keyCode: 0x06, modifier: .maskCommand) // Cmd+Z (Z = 0x06)
        case "select_all", "cmd+a":
            postKeyWithModifier(keyCode: 0x00, modifier: .maskCommand) // Cmd+A (A = 0x00)
        case "cut", "cmd+x":
            postKeyWithModifier(keyCode: 0x07, modifier: .maskCommand) // Cmd+X (X = 0x07)
        case "save", "cmd+s":
            postKeyWithModifier(keyCode: 0x01, modifier: .maskCommand) // Cmd+S (S = 0x01)
        default:
            break
        }
    }
    
    private func postKeyWithModifier(keyCode: UInt16, modifier: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = modifier
        up.flags = modifier
        down.post(tap: .cgSessionEventTap)
        usleep(15_000)
        up.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Ambient Screen Brightness Monitor
final class BrightnessMonitor {
    private var lastBrightness: Float = -1.0
    
    func check() -> Float? {
        var brightness: Float = 0.5
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        if service != 0 {
            IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
            if abs(brightness - lastBrightness) > 0.02 {
                lastBrightness = brightness
                return brightness
            }
        }
        return nil
    }
}

// MARK: - Mac Sleep & Lock State Observer
@available(macOS 12.3, *)
final class PowerStateObserver {
    private let streamer: ScreenStreamer
    private var lastState: String = "wake"

    init(streamer: ScreenStreamer) {
        self.streamer = streamer
    }

    func start() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("sleep")
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("sleep")
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("wake")
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("wake")
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("lock")
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.notifyState("unlock")
        }
    }

    private func notifyState(_ state: String) {
        if state == lastState { return }
        lastState = state
        fputs("[mac_host] Mac power state event: \(state)\n", stderr)
        streamer.sendJSON([
            "type": "mac_state",
            "state": state
        ])
    }
}

// MARK: - Main Application Entrypoint
@available(macOS 12.3, *)
@main
struct MacHostApp {
    static var globalVirtualDisplayID: CGDirectDisplayID = 0

    static func main() {
        var fps = 90
        var quality: Float = 0.90
        var enableVirtual = true
        var virtualWidth: UInt32 = 1280
        var virtualHeight: UInt32 = 800
        
        let args = CommandLine.arguments
        for i in 0..<args.count {
            if args[i] == "--fps", i + 1 < args.count, let val = Int(args[i + 1]) { fps = val }
            if args[i] == "--quality", i + 1 < args.count, let val = Float(args[i + 1]) { quality = val }
            if args[i] == "--no-virtual" { enableVirtual = false }
            if args[i] == "--width", i + 1 < args.count, let val = UInt32(args[i + 1]) { virtualWidth = val }
            if args[i] == "--height", i + 1 < args.count, let val = UInt32(args[i + 1]) { virtualHeight = val }
        }
        
        let virtualDisplayID: CGDirectDisplayID
        if enableVirtual {
            fputs("[mac_host] Initializing native virtual display for Xiaomi Pad SE (\(virtualWidth)x\(virtualHeight) @ \(fps)Hz)...\n", stderr)
            let dID = create_virtual_display(virtualWidth, virtualHeight, Double(fps), "Xiaomi Pad SE (Android Duo)")
            virtualDisplayID = dID
            MacHostApp.globalVirtualDisplayID = dID
            if dID != 0 {
                fputs("[mac_host] Virtual Display active: ID=\(dID)\n", stderr)
            }
        } else {
            virtualDisplayID = 0
            MacHostApp.globalVirtualDisplayID = 0
        }
        
        signal(SIGINT) { _ in
            fputs("[mac_host] Caught SIGINT. Cleaning up and exiting...\n", stderr)
            if MacHostApp.globalVirtualDisplayID != 0 {
                destroy_virtual_display(MacHostApp.globalVirtualDisplayID)
            }
            exit(0)
        }
        signal(SIGTERM) { _ in
            fputs("[mac_host] Caught SIGTERM. Cleaning up and exiting...\n", stderr)
            if MacHostApp.globalVirtualDisplayID != 0 {
                destroy_virtual_display(MacHostApp.globalVirtualDisplayID)
            }
            exit(0)
        }
        
        let streamer = ScreenStreamer()
        let synthesizer = InputSynthesizer()
        let brightnessMonitor = BrightnessMonitor()
        let powerObserver = PowerStateObserver(streamer: streamer)
        powerObserver.start()
        
        Task {
            // Polling brightness changes from Mac display and streaming to tablet
            Task.detached {
                while true {
                    if let b = brightnessMonitor.check() {
                        streamer.sendJSON([
                            "type": "brightness",
                            "value": Double(b)
                        ])
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
            }
            
            // Start stdin reader thread
            DispatchQueue.global(qos: .userInteractive).async {
                let stdinHandle = FileHandle.standardInput
                var buffer = Data()
                
                while true {
                    let chunk = stdinHandle.availableData
                    if chunk.isEmpty {
                        fputs("[mac_host] Stdin EOF received. Cleaning up and exiting...\n", stderr)
                        if virtualDisplayID != 0 {
                            destroy_virtual_display(virtualDisplayID)
                        }
                        exit(0)
                    }
                    buffer.append(chunk)
                    
                    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer.subdata(in: 0..<newlineIndex)
                        buffer.removeSubrange(0...newlineIndex)
                        
                        if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            if let type = json["type"] as? String {
                                if type == "config" {
                                    let newFps = json["fps"] as? Int
                                    let newQ = (json["quality"] as? NSNumber)?.floatValue
                                    streamer.updateConfig(fps: newFps, quality: newQ)
                                } else if type == "request_frame" || type == "request_keyframe" {
                                    // ScreenCaptureKit handles active frames; server sends cached frame
                                } else if type == "select_display",
                                          let dId = (json["displayId"] as? NSNumber)?.uint32Value ?? (json["displayId"] as? UInt32) {
                                    Task {
                                        await streamer.switchDisplay(id: dId)
                                        synthesizer.activeDisplayID = dId
                                    }
                                } else if type == "set_resolution",
                                          let w = (json["width"] as? NSNumber)?.intValue ?? (json["width"] as? Int),
                                          let h = (json["height"] as? NSNumber)?.intValue ?? (json["height"] as? Int) {
                                    Task {
                                        await streamer.updateResolution(width: w, height: h)
                                    }
                                } else if type == "set_position", let pos = json["position"] as? String {
                                    let ok = set_virtual_display_position(pos)
                                    fputs("[mac_host] Set display position to \(pos): \(ok)\n", stderr)
                                } else {
                                    synthesizer.handleCommand(json)
                                }
                            }
                        }
                    }
                }
            }
            
            do {
                try await streamer.start(preferredDisplayID: virtualDisplayID != 0 ? virtualDisplayID : nil,
                                         fps: fps,
                                         quality: quality)
                synthesizer.activeDisplayID = streamer.currentDisplayID
                fputs("[mac_host] Ready and listening for events on Display ID \(streamer.currentDisplayID).\n", stderr)
            } catch {
                fputs("[mac_host] Fatal startup error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        
        RunLoop.main.run()
    }
}
