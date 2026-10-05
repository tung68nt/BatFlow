import Cocoa
import SwiftUI
import Foundation
import IOKit
import IOKit.ps

@_silgen_name("IOPSDrawingUnlimitedPower")
func IOPSDrawingUnlimitedPower() -> DarwinBoolean

// MARK: - History Point Type
typealias HistoryPoint = (time: String, pct: Double)

// MARK: - Battery Data Model (Realtime Automatic Polling)
class BatteryViewModel: ObservableObject {
    @Published var hasBattery: Bool = true
    @Published var currentPct: Int = 0
    @Published var isCharging: Bool = false
    @Published var isExtConnected: Bool = false
    @Published var isFullyCharged: Bool = false
    @Published var voltage: Double = 0.0
    @Published var amperage: Int = 0
    @Published var netWatts: Double = 0.0
    @Published var sysLoadW: Double = 0.0
    @Published var chargerWatts: Double = 0.0
    @Published var adapterVoltage: Double = 0.0
    @Published var adapterCurrent: Double = 0.0
    @Published var tempC: Double = 0.0
    @Published var cycleCount: Int = 0
    @Published var designCycleCount: Int = 1000
    @Published var fullCap: Int = 0
    @Published var designCap: Int = 0
    @Published var nominalCap: Int = 0
    @Published var remainingCap: Int = 0
    @Published var timeRemainingMinutes: Int = 0
    @Published var timeToFullMinutes: Int = 0
    @Published var powerSourceStr: String = "Đang đọc dữ liệu..."
    @Published var appleHealthPct: Int = 0
    @Published var rawHealthPct: Double = 0.0
    @Published var ports: [HardwarePort] = []

    /// Invoked on the main thread after every hardware sample.
    var onSample: (() -> Void)?

    var powerPort: HardwarePort? { ports.first { $0.isPowerSource } }
    var isHolding: Bool { isExtConnected && !isCharging }

    // Dynamic 12-hour chart points (normalized 0.0 - 1.0) and time labels
    @Published var historyPoints: [HistoryPoint] = []
    @Published var chartLabels: [String] = ["--:--", "--:--", "--:--", "--:--"]
    
    private(set) var recordedHistory: [(Date, Double)] = []
    private(set) var lastChartRecomputeTime: Date = Date.distantPast
    private var isFetchingHealth = false
    private var isFetchingSystemLogs = false
    
    init() {
        self.recordedHistory = BatteryHistoryManager.shared.loadCachedHistory()
        fetchAppleOfficialHealth()
        updateData()
        recomputeHistoryPoints()
        fetchHistoricalLogsIfNeeded()
    }

    func recomputeHistoryPoints() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-12 * 3600)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let l0 = timeFormatter.string(from: cutoff)
        let l1 = timeFormatter.string(from: now.addingTimeInterval(-8 * 3600))
        let l2 = timeFormatter.string(from: now.addingTimeInterval(-4 * 3600))
        let l3 = timeFormatter.string(from: now)
        self.chartLabels = [l0, l1, l2, l3]
        
        let curPctNormalized = max(0.0, min(1.0, Double(self.currentPct) / 100.0))
        if self.recordedHistory.isEmpty || abs((self.recordedHistory.last?.1 ?? 0) - curPctNormalized) >= 0.005 || now.timeIntervalSince(self.recordedHistory.last?.0 ?? Date.distantPast) >= 60 {
            self.recordedHistory.append((now, curPctNormalized))
            BatteryHistoryManager.shared.saveCachedHistory(self.recordedHistory)
        }
        
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        self.recordedHistory = self.recordedHistory.filter { $0.0 >= dayAgo }
        let sorted = self.recordedHistory.sorted(by: { $0.0 < $1.0 })
        
        let numSteps = 13
        let stepSeconds = (12.0 * 3600.0) / Double(numSteps - 1)
        var newPoints: [(time: String, pct: Double)] = []
        
        for i in 0..<numSteps {
            let t = cutoff.addingTimeInterval(Double(i) * stepSeconds)
            let timeStr = timeFormatter.string(from: t)
            
            if i == numSteps - 1 {
                newPoints.append((time: timeStr, pct: curPctNormalized))
            } else {
                let candidates = sorted.filter { $0.0 <= t }
                if let latestBefore = candidates.last {
                    newPoints.append((time: timeStr, pct: latestBefore.1))
                } else if let firstEver = sorted.first {
                    newPoints.append((time: timeStr, pct: firstEver.1))
                } else {
                    newPoints.append((time: timeStr, pct: curPctNormalized))
                }
            }
        }
        
        self.historyPoints = newPoints
        self.lastChartRecomputeTime = now
    }

    func fetchHistoricalLogsIfNeeded() {
        guard !isFetchingSystemLogs else { return }
        isFetchingSystemLogs = true
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cutoff = Date().addingTimeInterval(-12 * 3600)
            let parsed = BatteryHistoryManager.shared.fetchSystemBatteryLogs(cutoff: cutoff)
            
            DispatchQueue.main.async {
                self.isFetchingSystemLogs = false
                if !parsed.isEmpty {
                    self.recordedHistory.append(contentsOf: parsed)
                    BatteryHistoryManager.shared.saveCachedHistory(self.recordedHistory)
                    self.recomputeHistoryPoints()
                }
            }
        }
    }

    func fetchAppleOfficialHealth() {
        guard !isFetchingHealth else { return }
        isFetchingHealth = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.isFetchingHealth = false }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            proc.arguments = ["SPPowerDataType"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let str = String(data: data, encoding: .utf8) {
                    if let range = str.range(of: "Maximum Capacity:\\s*(\\d+)%", options: .regularExpression) {
                        let match = String(str[range])
                        let digits = match.filter { $0.isNumber }
                        if let val = Int(digits), val > 0 && val <= 100 {
                            DispatchQueue.main.async {
                                self?.appleHealthPct = val
                            }
                        }
                    }
                }
            } catch {}
        }
    }

    func getEstimatedFullString() -> String {
        guard timeToFullMinutes > 0 && timeToFullMinutes < 65535 else { return "Đang tính toán..." }
        let h = timeToFullMinutes / 60
        let m = timeToFullMinutes % 60
        let durationStr = h > 0 ? "\(h)h \(m)m" : "\(m) phút"
        let fullDate = Date().addingTimeInterval(TimeInterval(timeToFullMinutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(durationStr) nữa (lúc \(formatter.string(from: fullDate)))"
    }

    func getEstimatedEmptyString() -> String {
        guard timeRemainingMinutes > 0 && timeRemainingMinutes < 65535 else { return "Đang tính toán..." }
        let h = timeRemainingMinutes / 60
        let m = timeRemainingMinutes % 60
        let durationStr = h > 0 ? "\(h)h \(m)m" : "\(m) phút"
        let emptyDate = Date().addingTimeInterval(TimeInterval(timeRemainingMinutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(durationStr) nữa (lúc \(formatter.string(from: emptyDate)))"
    }

    // MARK: - Safe Type-Unboxing Helpers for IOKit Plists
    private func intVal(_ val: Any?) -> Int? {
        if let i = val as? Int { return i }
        if let n = val as? NSNumber { return n.intValue }
        if let s = val as? String, let i = Int(s) { return i }
        return nil
    }

    private func doubleVal(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let n = val as? NSNumber { return n.doubleValue }
        if let s = val as? String, let d = Double(s) { return d }
        return nil
    }

    private func boolVal(_ val: Any?) -> Bool? {
        if let b = val as? Bool { return b }
        if let n = val as? NSNumber { return n.boolValue }
        return nil
    }

    func updateData() {
        // Fast asynchronous extraction on high-priority concurrent queue
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            var targetPct: Int = 0
            var targetCharging: Bool = false
            var targetExtConnected: Bool = false
            var targetFull: Bool = false
            var targetV: Double = 0.0
            var targetA: Int = 0
            var targetTemp: Double = 0.0
            var targetCycles: Int = 0
            var targetDesignCycles: Int = 1000
            var targetFullCap: Int = 0
            var targetNominalCap: Int = 0
            var targetDesignCap: Int = 0
            var targetRemainingCap: Int = 0
            var targetTimeToFull: Int = 0
            var targetTimeRemaining: Int = 0
            var targetRawHealth: Double = 0.0
            var targetWatts: Double = 0.0
            var targetAdapterV: Double = 0.0
            var targetAdapterA: Double = 0.0
            var targetAppleHealth: Int = 0
            var telemetrySysLoad: Double = 0.0
            var batteryDict: [String: Any] = [:]
            var foundBattery = false

            // 1. CoreOS IOPS layer
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
            if let sources = sources {
                for s in sources {
                    if let desc = IOPSGetPowerSourceDescription(snapshot, s)?.takeUnretainedValue() as? [String: Any] {
                        foundBattery = true
                        if let pct = self.intVal(desc[kIOPSCurrentCapacityKey]) { targetPct = pct }
                        if let chg = self.boolVal(desc[kIOPSIsChargingKey]) { targetCharging = chg }
                        if let timeFull = self.intVal(desc[kIOPSTimeToFullChargeKey]) { targetTimeToFull = timeFull }
                        if let timeEmpty = self.intVal(desc[kIOPSTimeToEmptyKey]) { targetTimeRemaining = timeEmpty }
                    }
                }
            }

            targetExtConnected = IOPSDrawingUnlimitedPower().boolValue

            // 2. Direct Hardware Layer via IOKit AppleSmartBattery
            let mainPort: mach_port_t
            if #available(macOS 12.0, *) {
                mainPort = kIOMainPortDefault
            } else {
                mainPort = kIOMasterPortDefault
            }
            let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    foundBattery = true
                    batteryDict = dict

                    if let bData = dict["BatteryData"] as? [String: Any] {
                        if let dCap = self.intVal(bData["DesignCapacity"]) { targetDesignCap = dCap }
                        if let fCap = self.intVal(bData["FullChargeCapacity"]) { targetFullCap = fCap }
                        if let nCap = self.intVal(bData["NominalChargeCapacity"]) { targetNominalCap = nCap }
                        if let rCap = self.intVal(bData["RemainingCapacity"]) { targetRemainingCap = rCap }
                    }
                    // Intel Macs publish raw mAh at the top level instead of inside BatteryData
                    if targetDesignCap == 0, let dCap = self.intVal(dict["DesignCapacity"]) { targetDesignCap = dCap }
                    if targetFullCap == 0 {
                        if let fCap = self.intVal(dict["AppleRawMaxCapacity"]) {
                            targetFullCap = fCap
                        } else if let fCap = self.intVal(dict["MaxCapacity"]), fCap > 100 {
                            targetFullCap = fCap
                        }
                    }
                    if targetRemainingCap == 0, let rCap = self.intVal(dict["AppleRawCurrentCapacity"]) { targetRemainingCap = rCap }

                    // "CurrentCapacity" is a percentage on Apple Silicon but raw mAh on Intel
                    if let cur = self.intVal(dict["CurrentCapacity"]) {
                        let maxCap = self.intVal(dict["MaxCapacity"]) ?? 100
                        if maxCap > 0 && maxCap != 100 {
                            targetPct = Int((Double(cur) / Double(maxCap) * 100.0).rounded())
                        } else {
                            targetPct = cur
                        }
                    }
                    targetPct = max(0, min(100, targetPct))

                    if let cycles = self.intVal(dict["CycleCount"]) { targetCycles = cycles }
                    if let dc = self.intVal(dict["DesignCycleCount9C"]), dc > 0 { targetDesignCycles = dc }
                    if let temp = self.doubleVal(dict["Temperature"]) { targetTemp = temp / 100.0 }
                    if let v = self.doubleVal(dict["AppleRawBatteryVoltage"]) ?? self.doubleVal(dict["Voltage"]) { targetV = v / 1000.0 }
                    if let a = self.intVal(dict["InstantAmperage"]) ?? self.intVal(dict["Amperage"]) { targetA = a }
                    if let isChg = self.boolVal(dict["IsCharging"]) { targetCharging = isChg }
                    if let ext = self.boolVal(dict["ExternalConnected"]) { targetExtConnected = ext }
                    if let full = self.boolVal(dict["FullyCharged"]) { targetFull = full }
                    if let tFull = self.intVal(dict["AvgTimeToFull"]) { targetTimeToFull = tFull }
                    if let tEmpty = self.intVal(dict["AvgTimeToEmpty"]) { targetTimeRemaining = tEmpty }

                    if let pt = dict["PowerTelemetryData"] as? [String: Any] {
                        if let sLoad = self.doubleVal(pt["SystemLoad"]), sLoad > 0 {
                            telemetrySysLoad = sLoad / 1000.0
                        } else if let sPowerIn = self.doubleVal(pt["SystemPowerIn"]), sPowerIn > 0 {
                            telemetrySysLoad = sPowerIn / 1000.0
                        }
                    }

                    var adapter: [String: Any]?
                    if let aDetails = dict["AdapterDetails"] as? [String: Any], !aDetails.isEmpty {
                        adapter = aDetails
                    } else if let rawDetails = dict["AppleRawAdapterDetails"] as? [[String: Any]], let first = rawDetails.first {
                        adapter = first
                    } else if let rawDetailsDict = dict["AppleRawAdapterDetails"] as? [String: Any] {
                        adapter = rawDetailsDict
                    }
                    if let adapter = adapter {
                        if let w = self.doubleVal(adapter["Watts"]), w > 0 { targetWatts = w }
                        if let v = self.doubleVal(adapter["AdapterVoltage"]), v > 0 { targetAdapterV = v / 1000.0 }
                        if let c = self.doubleVal(adapter["Current"]), c > 0 { targetAdapterA = c / 1000.0 }
                    }

                    if let aHealth = self.intVal(dict["AppleHealthMetric"]) {
                        if aHealth > 0 && aHealth <= 100 { targetAppleHealth = aHealth }
                    }

                    if targetDesignCap > 0 {
                        let activeCap = targetNominalCap > 0 ? targetNominalCap : targetFullCap
                        targetRawHealth = min(100.0, max(1.0, (Double(activeCap) / Double(targetDesignCap)) * 100.0))
                    }
                }
            }

            // The registry stopped exposing the pack temperature on recent macOS; the SMC sensor still reports it
            if targetTemp <= 0, foundBattery, let smcTemp = SMCReader.shared.batteryTemperature() {
                targetTemp = (smcTemp * 10.0).rounded() / 10.0
            }

            // High Precision Thermal & Power Math
            let netWattsVal = (Double(targetA) * targetV) / 1000.0
            let targetNetWatts = round(netWattsVal * 10.0) / 10.0

            let sysLoadRaw: Double
            if !targetExtConnected {
                // When running on battery alone, total system load strictly equals the discharge power from battery
                sysLoadRaw = abs(targetNetWatts)
            } else if telemetrySysLoad > 0.5 {
                sysLoadRaw = telemetrySysLoad
            } else if targetWatts > 0 && targetCharging {
                sysLoadRaw = max(0.0, targetWatts - targetNetWatts)
            } else {
                sysLoadRaw = abs(targetNetWatts)
            }
            let targetSysLoad = round(sysLoadRaw * 10.0) / 10.0

            if !targetExtConnected {
                targetWatts = 0
                targetAdapterV = 0
                targetAdapterA = 0
            }

            let targetPorts = DeviceInfo.shared.currentPorts(battery: batteryDict, externalConnected: targetExtConnected)

            var targetPowerStr = foundBattery ? "Dùng pin" : "Không có pin"
            if targetExtConnected {
                let portName = targetPorts.first(where: { $0.isPowerSource })?.title.replacingOccurrences(of: "Cổng ", with: "") ?? "Nguồn ngoài"
                let wInt = Int(round(targetWatts))
                targetPowerStr = wInt > 0 ? "\(portName) • \(wInt)W" : portName
            }

            // Apply all updates on main thread
            let apply = {
                self.hasBattery = foundBattery
                self.currentPct = targetPct
                self.isExtConnected = targetExtConnected
                self.isCharging = targetCharging
                self.isFullyCharged = targetFull
                self.voltage = targetV
                self.amperage = targetA
                self.netWatts = targetNetWatts
                self.tempC = targetTemp
                self.sysLoadW = targetSysLoad
                self.cycleCount = targetCycles
                self.designCycleCount = targetDesignCycles
                self.fullCap = targetFullCap
                self.nominalCap = targetNominalCap
                self.designCap = targetDesignCap
                self.remainingCap = targetRemainingCap
                self.timeToFullMinutes = targetTimeToFull
                self.timeRemainingMinutes = targetTimeRemaining
                self.rawHealthPct = targetRawHealth
                if targetAppleHealth > 0 { self.appleHealthPct = targetAppleHealth }
                self.chargerWatts = targetWatts
                self.adapterVoltage = targetAdapterV
                self.adapterCurrent = targetAdapterA
                self.powerSourceStr = targetPowerStr
                self.ports = targetPorts

                // Keep 12h chart dynamically refreshed as time passes
                if foundBattery, abs((self.recordedHistory.last?.1 ?? 0) - (Double(targetPct) / 100.0)) >= 0.005 || Date().timeIntervalSince(self.lastChartRecomputeTime) >= 30 {
                    self.recomputeHistoryPoints()
                }
                self.onSample?()
            }

            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }
}
