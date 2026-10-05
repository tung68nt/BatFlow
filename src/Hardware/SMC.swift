import Foundation
import IOKit

// MARK: - AppleSMC Reader (read-only sensor access, no privileges required)
// Recent macOS releases no longer publish the battery temperature in the IORegistry; the SMC still does.
final class SMCReader {
    static let shared = SMCReader()

    // Mirrors the kernel's 80-byte SMCParamStruct
    private struct Param {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess {
            connection = 0
        }
    }

    private static func fourCC(_ text: String) -> UInt32 {
        return text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout Param) -> Param? {
        guard MemoryLayout<Param>.stride == 80 else { return nil }
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let kr = IOConnectCallStructMethod(connection, SMCReader.kernelIndex, &input, MemoryLayout<Param>.stride, &output, &outputSize)
        return (kr == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    private func read(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        guard connection != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        var info = Param()
        info.key = SMCReader.fourCC(key)
        info.data8 = SMCReader.cmdReadKeyInfo
        guard let meta = call(&info), meta.dataSize > 0, meta.dataSize <= 32 else { return nil }

        var request = Param()
        request.key = info.key
        request.dataSize = meta.dataSize
        request.data8 = SMCReader.cmdReadBytes
        guard let out = call(&request) else { return nil }
        let all = withUnsafeBytes(of: out.bytes) { Array($0) }
        return (meta.dataType, Array(all.prefix(Int(meta.dataSize))))
    }

    private func floatValue(_ key: String) -> Double? {
        guard let value = read(key), value.type == SMCReader.fourCC("flt "), value.bytes.count == 4 else { return nil }
        let raw = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Double(Float(bitPattern: UInt32(littleEndian: raw)))
    }

    struct Fan {
        let rpm: Double
        let minRPM: Double
        let maxRPM: Double

        /// Share of the fan's usable range currently in use, 0...1.
        var load: Double {
            guard maxRPM > minRPM else { return 0 }
            return max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM)))
        }
    }

    /// Current speed of every fan; empty on fanless Macs such as MacBook Air.
    func fans() -> [Fan] {
        guard let count = read("FNum")?.bytes.first, count > 0, count <= 8 else { return [] }
        var result: [Fan] = []
        for i in 0..<Int(count) {
            guard let rpm = floatValue("F\(i)Ac") else { continue }
            result.append(Fan(rpm: rpm, minRPM: floatValue("F\(i)Mn") ?? 0, maxRPM: floatValue("F\(i)Mx") ?? 0))
        }
        return result
    }

    /// Battery pack temperature in °C, or nil when the sensor is unavailable.
    func batteryTemperature() -> Double? {
        for key in ["TB0T", "TB1T", "TB2T"] {
            guard let value = read(key) else { continue }
            var celsius: Double?
            if value.type == SMCReader.fourCC("flt "), value.bytes.count == 4 {
                let raw = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                celsius = Double(Float(bitPattern: UInt32(littleEndian: raw)))
            } else if value.type == SMCReader.fourCC("sp78"), value.bytes.count == 2 {
                celsius = Double(Int16(bitPattern: (UInt16(value.bytes[0]) << 8) | UInt16(value.bytes[1]))) / 256.0
            }
            if let c = celsius, c > 0, c < 90 { return c }
        }
        return nil
    }
}
