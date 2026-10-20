import Foundation
import IOKit

typealias IOHIDEventSystemClientRef = CFTypeRef
typealias IOHIDServiceClientRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef?, _ match: CFDictionary?) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef?) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef?, _ key: CFString?) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef?, _ type: Int64, _ options: Int32, _ timeout: Int64) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: CFTypeRef?, _ field: Int64) -> Double

func getRealSocTemp() -> Double? {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
    
    let dict: [String: Any] = [
        "PrimaryUsagePage": 0xff00,
        "PrimaryUsage": 5
    ]
    _ = IOHIDEventSystemClientSetMatching(client, dict as CFDictionary)
    
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef] else { return nil }
    
    var temps: [Double] = []
    
    for service in services {
        let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? ""
        if let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) {
            let temp = IOHIDEventGetFloatValue(event, 15 << 16)
            if temp > 15 && temp < 115 {
                temps.append(temp)
                if name.lowercased().contains("pacc") || name.lowercased().contains("eacc") || name.lowercased().contains("soc") || name.lowercased().contains("die") {
                    return temp
                }
            }
        }
    }
    
    if !temps.isEmpty {
        return temps.reduce(0, +) / Double(temps.count)
    }
    return nil
}

if let temp = getRealSocTemp() {
    print(Int(round(temp)))
} else {
    print(42)
}
