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
    @Published var currentPct: Int = 80
    @Published var isCharging: Bool = false
    @Published var isExtConnected: Bool = true
    @Published var voltage: Double = 12.07
    @Published var amperage: Int = 0
    @Published var netWatts: Double = 0.0
    @Published var sysLoadW: Double = 13.7
    @Published var chargerWatts: Double = 60.0
    @Published var tempC: Double = 30.0
    @Published var cycleCount: Int = 780
    @Published var fullCap: Int = 4687
    @Published var designCap: Int = 6075
    @Published var nominalCap: Int = 4867
    @Published var timeRemainingMinutes: Int = 0
    @Published var timeToFullMinutes: Int = 0
    @Published var powerSourceStr: String = "Nguồn ngoài (Type-C 60W)"
    @Published var appleHealthPct: Int = 80
    @Published var rawHealthPct: Double = 77.1
    
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
            
            var targetPct: Int = 80
            var targetCharging: Bool = false
            var targetExtConnected: Bool = true
            var targetV: Double = 12.0
            var targetA: Int = 0
            var targetTemp: Double = 30.0
            var targetCycles: Int = 0
            var targetFullCap: Int = 0
            var targetNominalCap: Int = 0
            var targetDesignCap: Int = 6075
            var targetTimeToFull: Int = 0
            var targetTimeRemaining: Int = 0
            var targetRawHealth: Double = 100.0
            var targetWatts: Double = 60.0
            var targetAppleHealth: Int = 0
            var telemetrySysLoad: Double = 0.0

            // 1. CoreOS IOPS layer
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
            if let sources = sources {
                for s in sources {
                    if let desc = IOPSGetPowerSourceDescription(snapshot, s)?.takeUnretainedValue() as? [String: Any] {
                        if let pct = self.intVal(desc[kIOPSCurrentCapacityKey]) { targetPct = pct }
                        if let chg = self.boolVal(desc[kIOPSIsChargingKey]) { targetCharging = chg }
                        if let timeFull = self.intVal(desc[kIOPSTimeToFullChargeKey]) { targetTimeToFull = timeFull }
                        if let timeEmpty = self.intVal(desc[kIOPSTimeToEmptyKey]) { targetTimeRemaining = timeEmpty }
                    }
                }
            }

            let unlimited = IOPSDrawingUnlimitedPower().boolValue
            targetExtConnected = unlimited

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
                    
                    if let bData = dict["BatteryData"] as? [String: Any] {
                        if let dCap = self.intVal(bData["DesignCapacity"]) { targetDesignCap = dCap }
                        if let fCap = self.intVal(bData["FullChargeCapacity"]) { targetFullCap = fCap }
                        if let nCap = self.intVal(bData["NominalChargeCapacity"]) { targetNominalCap = nCap }
                    } else {
                        if let fCap = self.intVal(dict["MaxCapacity"]) { targetFullCap = fCap }
                        if let dCap = self.intVal(dict["DesignCapacity"]) { targetDesignCap = dCap }
                    }

                    if let cur = self.intVal(dict["CurrentCapacity"]) {
                        targetPct = cur
                    }

                    if let cycles = self.intVal(dict["CycleCount"]) { targetCycles = cycles }
                    if let temp = self.doubleVal(dict["Temperature"]) { targetTemp = temp / 100.0 }
                    if let v = self.doubleVal(dict["AppleRawBatteryVoltage"]) ?? self.doubleVal(dict["Voltage"]) { targetV = v / 1000.0 }
                    if let a = self.intVal(dict["InstantAmperage"]) ?? self.intVal(dict["Amperage"]) { targetA = a }
                    if let isChg = self.boolVal(dict["IsCharging"]) { targetCharging = isChg }
                    if let ext = self.boolVal(dict["ExternalConnected"]) { targetExtConnected = ext }
                    if let tFull = self.intVal(dict["AvgTimeToFull"]) { targetTimeToFull = tFull }
                    if let tEmpty = self.intVal(dict["AvgTimeToEmpty"]) { targetTimeRemaining = tEmpty }

                    if let pt = dict["PowerTelemetryData"] as? [String: Any] {
                        if let sLoad = self.doubleVal(pt["SystemLoad"]), sLoad > 0 {
                            telemetrySysLoad = sLoad / 1000.0
                        } else if let sPowerIn = self.doubleVal(pt["SystemPowerIn"]), sPowerIn > 0 {
                            telemetrySysLoad = sPowerIn / 1000.0
                        }
                    }

                    if let cData = dict["ChargerData"] as? [String: Any] {
                        if let w = self.doubleVal(cData["Watts"]) { targetWatts = w }
                        if let chg = self.boolVal(cData["IsCharging"]) { targetCharging = chg }
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

            // High Precision Thermal & Power Math
            let vCalc = max(10.0, targetV)
            let netWattsVal = (Double(targetA) * vCalc) / 1000.0
            let targetNetWatts = round(netWattsVal * 10.0) / 10.0

            let sysLoadRaw: Double
            if !targetExtConnected {
                // When running on battery alone, total system load strictly equals the discharge power from battery
                sysLoadRaw = abs(targetNetWatts)
            } else if telemetrySysLoad > 0.5 {
                sysLoadRaw = telemetrySysLoad
            } else {
                sysLoadRaw = targetCharging ? max(2.0, targetWatts - targetNetWatts) : (abs(targetNetWatts) > 0.5 ? abs(targetNetWatts) : 7.5)
            }
            let targetSysLoad = round(sysLoadRaw * 10.0) / 10.0

            var targetPowerStr = "Dùng pin"
            if targetExtConnected {
                let isMagSafe = self.isMagSafeActive()
                let portName = isMagSafe ? "MagSafe 3" : "Type-C"
                let wInt = Int(round(targetWatts))
                if targetCharging {
                    targetPowerStr = "Cổng \(portName) (\(wInt)W)"
                } else {
                    targetPowerStr = "Nguồn ngoài (\(portName) \(wInt)W)"
                }
            }

            // Apply all updates on main thread
            let apply = {
                self.currentPct = targetPct
                self.isExtConnected = targetExtConnected
                self.isCharging = targetCharging
                self.voltage = targetV
                self.amperage = targetA
                self.netWatts = targetNetWatts
                self.tempC = targetTemp
                self.sysLoadW = targetSysLoad
                self.cycleCount = targetCycles
                self.fullCap = targetFullCap
                self.nominalCap = targetNominalCap
                self.designCap = targetDesignCap
                self.timeToFullMinutes = targetTimeToFull
                self.timeRemainingMinutes = targetTimeRemaining
                self.rawHealthPct = targetRawHealth
                if targetAppleHealth > 0 { self.appleHealthPct = targetAppleHealth }
                self.chargerWatts = targetWatts
                self.powerSourceStr = targetPowerStr
                
                // Keep 12h chart dynamically refreshed as time passes
                if abs((self.recordedHistory.last?.1 ?? 0) - (Double(targetPct) / 100.0)) >= 0.005 || Date().timeIntervalSince(self.lastChartRecomputeTime) >= 30 {
                    self.recomputeHistoryPoints()
                }
            }

            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    func isMagSafeActive() -> Bool {
        var iterator: io_iterator_t = 0
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        guard IOServiceGetMatchingServices(mainPort, IOServiceMatching("AppleTCControllerType11"), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                if let desc = dict["PortDescription"] as? String, desc.contains("MagSafe") {
                    if let active = dict["ConnectionActive"] as? Bool, active {
                        return true
                    }
                    if let activeInt = dict["ConnectionActive"] as? Int, activeInt == 1 {
                        return true
                    }
                }
            }
        }
        return false
    }
}
