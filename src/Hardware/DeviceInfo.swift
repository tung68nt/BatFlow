import Foundation
import IOKit

// MARK: - Physical Port Model
enum PortKind: String {
    case magsafe, usbc, hdmi, sdcard, audio, usba, thunderbolt2
}

enum ChassisSide {
    case left, right
}

struct HardwarePort: Identifiable {
    let id: String
    let kind: PortKind
    let number: Int
    let title: String
    let spec: String
    let side: ChassisSide
    var isConnected: Bool
    var isPowerSource: Bool

    var canCharge: Bool { kind == .magsafe || kind == .usbc }
}

// MARK: - Device Identity & Port Topology (read live from IOKit, no model hardcoding needed on Apple Silicon)
final class DeviceInfo {
    static let shared = DeviceInfo()

    let modelIdentifier: String
    let modelName: String
    let chipName: String
    let memoryGB: Int

    var specString: String { "\(chipName) • Bộ nhớ \(memoryGB) GB" }
    var isAppleSilicon: Bool { !chipName.lowercased().contains("intel") }

    private init() {
        modelIdentifier = DeviceInfo.sysctlString("hw.model") ?? "Mac"
        chipName = DeviceInfo.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
        modelName = DeviceInfo.productName() ?? DeviceInfo.fallbackName(for: modelIdentifier)
    }

    private static var mainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Marketing name published by firmware on Apple Silicon, e.g. "MacBook Air (13-inch, M2, 2022)".
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(mainPort, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        for key in ["product-name", "product-description"] {
            guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { continue }
            var name: String?
            if let data = raw as? Data {
                name = String(data: data, encoding: .utf8)
            } else if let str = raw as? String {
                name = str
            }
            if let cleaned = name?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)), !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private static func fallbackName(for model: String) -> String {
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBook") { return "MacBook" }
        return model
    }

    // MARK: Port topology

    private struct RegistryPort {
        let typeName: String
        let number: Int
        let active: Bool
    }

    private let cacheLock = NSLock()
    private var cachedRegistry: [RegistryPort] = []
    private var cachedRegistryAt = Date.distantPast

    /// Port objects are re-read at most every 1.5s; the battery itself is sampled faster than that.
    private func registryPorts() -> [RegistryPort] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if Date().timeIntervalSince(cachedRegistryAt) < 1.5 { return cachedRegistry }
        cachedRegistry = scanRegistryPorts()
        cachedRegistryAt = Date()
        return cachedRegistry
    }

    func invalidatePortCache() {
        cacheLock.lock()
        cachedRegistryAt = Date.distantPast
        cacheLock.unlock()
    }

    private func scanRegistryPorts() -> [RegistryPort] {
        var seen = Set<UInt64>()
        var result: [RegistryPort] = []
        // Class names changed across macOS releases; query every known ancestor and de-duplicate by entry ID.
        let classes = ["IOPort", "AppleTCController", "AppleTCControllerType10", "AppleTCControllerType11",
                       "AppleHPMInterfaceType10", "AppleHPMInterfaceType11", "AppleHPMInterfaceType12"]
        for cls in classes {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(DeviceInfo.mainPort, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &entryID)
                guard !seen.contains(entryID) else { continue }

                func prop(_ key: String) -> Any? {
                    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                let desc = (prop("PortDescription") as? String) ?? (prop("Description") as? String) ?? ""
                var typeName = (prop("PortTypeDescription") as? String) ?? ""
                if typeName.isEmpty, desc.hasPrefix("Port-") {
                    typeName = String(desc.dropFirst(5).prefix { $0 != "@" })
                }
                guard !typeName.isEmpty else { continue }
                seen.insert(entryID)

                var number = (prop("PortNumber") as? NSNumber)?.intValue ?? 0
                if number == 0, let at = desc.lastIndex(of: "@"), let n = Int(desc[desc.index(after: at)...]) {
                    number = n
                }
                let active = (prop("ConnectionActive") as? NSNumber)?.boolValue ?? false
                result.append(RegistryPort(typeName: typeName, number: max(1, number), active: active))
            }
        }
        return result
    }

    /// Index (0-based, USB-C ports first) of the port controller that currently holds a power contract.
    private func poweredControllerIndex(_ battery: [String: Any]) -> Int? {
        guard let info = battery["PortControllerInfo"] as? [[String: Any]] else { return nil }
        for (i, entry) in info.enumerated() {
            if let maxPower = (entry["PortControllerMaxPower"] as? NSNumber)?.intValue, maxPower > 0 {
                return i
            }
        }
        return nil
    }

    /// Builds the chassis port list and marks which port is feeding the Mac.
    func currentPorts(battery: [String: Any], externalConnected: Bool) -> [HardwarePort] {
        let registry = registryPorts()
        var ports = registry.isEmpty ? legacyPorts(battery: battery, externalConnected: externalConnected)
                                     : livePorts(registry, battery: battery, externalConnected: externalConnected)

        if externalConnected, !ports.contains(where: { $0.isPowerSource }) {
            // The system reports external power but no port could be attributed: fall back to the only plausible inlet.
            let candidates = ports.indices.filter { ports[$0].canCharge }
            if let pick = candidates.first(where: { ports[$0].isConnected }) ?? (candidates.count == 1 ? candidates.first : nil) {
                ports[pick].isPowerSource = true
            }
        }
        return ports
    }

    private func livePorts(_ registry: [RegistryPort], battery: [String: Any], externalConnected: Bool) -> [HardwarePort] {
        let usbc = registry.filter { $0.typeName.contains("USB-C") }.sorted { $0.number < $1.number }
        let magsafe = registry.first { $0.typeName.contains("MagSafe") }
        let hasHDMI = registry.contains { $0.typeName.contains("HDMI") }
        let hasSD = registry.contains { $0.typeName.contains("SD") }

        // Decide which inlet carries the charger.
        var sourceID: String?
        if externalConnected {
            let activeC = usbc.filter { $0.active }
            if let m = magsafe, m.active {
                sourceID = "magsafe"
            } else if activeC.count == 1 {
                sourceID = "usbc\(activeC[0].number)"
            } else if activeC.count > 1 {
                if let idx = poweredControllerIndex(battery), idx < usbc.count, usbc[idx].active {
                    sourceID = "usbc\(usbc[idx].number)"
                } else {
                    sourceID = "usbc\(activeC[0].number)"
                }
            }
        }

        // Apple's layout rule: two USB-C on the left edge, any additional ones on the right.
        let leftCount = usbc.count <= 2 ? usbc.count : (usbc.count == 3 ? 2 : usbc.count / 2)
        let tbSpec = usbc.count >= 3 ? "Thunderbolt / USB4 • Sạc USB-PD • Xuất hình" : "Thunderbolt / USB4 • Sạc USB-PD"

        var ports: [HardwarePort] = []
        if let m = magsafe {
            ports.append(HardwarePort(id: "magsafe", kind: .magsafe, number: 1, title: "Cổng \(m.typeName)",
                                      spec: "Chuẩn sạc từ tính Apple • Sát bản lề", side: .left,
                                      isConnected: m.active, isPowerSource: sourceID == "magsafe"))
        }
        for (i, p) in usbc.enumerated() {
            let id = "usbc\(p.number)"
            ports.append(HardwarePort(id: id, kind: .usbc, number: p.number, title: "Cổng USB-C \(p.number)",
                                      spec: tbSpec, side: i < leftCount ? .left : .right,
                                      isConnected: p.active, isPowerSource: sourceID == id))
        }
        if hasHDMI {
            ports.append(HardwarePort(id: "hdmi", kind: .hdmi, number: 1, title: "Cổng HDMI", spec: "Xuất hình ảnh & âm thanh",
                                      side: .right, isConnected: registry.first { $0.typeName.contains("HDMI") }?.active ?? false, isPowerSource: false))
        }
        if hasSD {
            ports.append(HardwarePort(id: "sd", kind: .sdcard, number: 1, title: "Khe thẻ nhớ SDXC", spec: "Đọc ghi thẻ nhớ tốc độ cao",
                                      side: .right, isConnected: registry.first { $0.typeName.contains("SD") }?.active ?? false, isPowerSource: false))
        }
        // Only the 14/16-inch Pro chassis (the ones with HDMI) carries the headphone jack on the left edge.
        let audioSide: ChassisSide = hasHDMI ? .left : .right
        ports.append(HardwarePort(id: "audio", kind: .audio, number: 1, title: "Jack âm thanh 3.5mm", spec: "Đầu ra âm thanh analog",
                                  side: audioSide, isConnected: false, isPowerSource: false))
        return ports
    }

    /// Intel Macs and old macOS releases do not publish port objects, so derive the layout from the model identifier.
    private func legacyPorts(battery: [String: Any], externalConnected: Bool) -> [HardwarePort] {
        let m = modelIdentifier
        func has(_ prefixes: [String]) -> Bool { prefixes.contains { m.hasPrefix($0) } }

        var adapterName = ""
        if let details = battery["AdapterDetails"] as? [String: Any] {
            adapterName = ((details["Name"] as? String) ?? "") + " " + ((details["Description"] as? String) ?? "")
        } else if let raw = (battery["AppleRawAdapterDetails"] as? [[String: Any]])?.first {
            adapterName = ((raw["Name"] as? String) ?? "") + " " + ((raw["Description"] as? String) ?? "")
        }
        let adapterIsMagSafe = adapterName.lowercased().contains("magsafe")

        let isMagSafe2Era = has(["MacBookPro11", "MacBookPro12", "MacBookAir6", "MacBookAir7"]) || adapterIsMagSafe
        if isMagSafe2Era {
            return [
                HardwarePort(id: "magsafe", kind: .magsafe, number: 1, title: "Cổng MagSafe 2", spec: "Chuẩn sạc từ tính Apple • Sát bản lề",
                             side: .left, isConnected: externalConnected, isPowerSource: externalConnected),
                HardwarePort(id: "tb2", kind: .thunderbolt2, number: 1, title: "Cổng Thunderbolt 2", spec: "Mini DisplayPort • 20 Gbps",
                             side: .left, isConnected: false, isPowerSource: false),
                HardwarePort(id: "usba1", kind: .usba, number: 1, title: "Cổng USB 3.0", spec: "USB-A 5 Gbps", side: .left, isConnected: false, isPowerSource: false),
                HardwarePort(id: "audio", kind: .audio, number: 1, title: "Jack âm thanh 3.5mm", spec: "Đầu ra âm thanh analog", side: .left, isConnected: false, isPowerSource: false),
                HardwarePort(id: "usba2", kind: .usba, number: 2, title: "Cổng USB 3.0", spec: "USB-A 5 Gbps", side: .right, isConnected: false, isPowerSource: false),
                HardwarePort(id: "sd", kind: .sdcard, number: 1, title: "Khe thẻ nhớ SDXC", spec: "Đọc ghi thẻ nhớ", side: .right, isConnected: false, isPowerSource: false)
            ]
        }

        let fourPort = has(["MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3", "MacBookPro15,1", "MacBookPro15,2",
                            "MacBookPro15,3", "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4"])
        let count = fourPort ? 4 : 2
        var ports: [HardwarePort] = []
        for n in 1...count {
            // Without per-port telemetry the charger position is unknown; the first port is only a best guess.
            ports.append(HardwarePort(id: "usbc\(n)", kind: .usbc, number: n, title: "Cổng USB-C \(n)", spec: "Thunderbolt 3 • Sạc USB-PD",
                                      side: n <= 2 ? .left : .right, isConnected: false, isPowerSource: false))
        }
        ports.append(HardwarePort(id: "audio", kind: .audio, number: 1, title: "Jack âm thanh 3.5mm", spec: "Đầu ra âm thanh analog",
                                  side: .right, isConnected: false, isPowerSource: false))
        return ports
    }
}
