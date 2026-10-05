import AppKit
import Darwin

// MARK: - Energy Consumer Record
struct EnergyApp: Identifiable {
    let id: String
    let name: String
    let category: String
    let cpu: Double
    let power: Double
    let processCount: Int
    let bundlePath: String?
    let pids: [pid_t]

    var icon: NSImage? {
        guard let path = bundlePath else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// Only regular foreground apps may be quit from the UI.
    var runningApp: NSRunningApplication? {
        guard let path = bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path && $0.activationPolicy == .regular }
    }
}

struct SleepBlocker: Identifiable {
    let id: String
    let processName: String
    let kind: String
    let reason: String
}

// MARK: - Energy Monitor (samples `top` only while a BatFlow surface is visible)
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()

    @Published var apps: [EnergyApp] = []
    @Published var sleepBlockers: [SleepBlocker] = []
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private var isSampling = false
    private var activeClients = Set<String>()

    func start(client: String) {
        activeClients.insert(client)
        sample()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop(client: String) {
        activeClients.remove(client)
        if activeClients.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func sample() {
        guard !isSampling else { return }
        isSampling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = EnergyMonitor.readTopConsumers()
            let blockers = EnergyMonitor.readSleepBlockers()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSampling = false
                if !apps.isEmpty { self.apps = apps }
                self.sleepBlockers = blockers
                self.lastUpdated = Date()
            }
        }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8.0) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return ""
        }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return len > 0 ? String(cString: buffer) : nil
    }

    /// Resolves a pid to its outermost .app bundle so helpers are grouped under the parent app.
    private static func identity(pid: pid_t, command: String) -> (name: String, category: String, bundle: String?) {
        if let path = executablePath(of: pid) {
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                let isSystem = bundle.hasPrefix("/System/")
                return (name, isSystem ? "Ứng dụng hệ thống" : "Ứng dụng", bundle)
            }
            let base = (path as NSString).lastPathComponent
            return (base, "Tiến trình hệ thống", nil)
        }
        return (command, "Tiến trình hệ thống", nil)
    }

    static func readTopConsumers() -> [EnergyApp] {
        // Two samples: the first one from `top` has no delta, only the second is meaningful.
        let out = run("/usr/bin/top", ["-l", "2", "-n", "40", "-o", "power", "-stats", "pid,cpu,power,command", "-s", "1"])
        let blocks = out.components(separatedBy: "PID ")
        guard blocks.count >= 3, let last = blocks.last else { return [] }

        struct Bucket {
            var category: String
            var cpu = 0.0
            var power = 0.0
            var count = 0
            var bundle: String?
            var pids: [pid_t] = []
        }
        var buckets: [String: Bucket] = [:]

        for line in last.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let cpu = Double(parts[1]), let power = Double(parts[2]) else { continue }
            let command = String(parts[3]).trimmingCharacters(in: .whitespaces)
            if command == "top" { continue }
            let who = identity(pid: pid, command: command)
            var bucket = buckets[who.name] ?? Bucket(category: who.category, bundle: who.bundle)
            bucket.cpu += cpu
            bucket.power += power
            bucket.count += 1
            bucket.pids.append(pid)
            if bucket.bundle == nil { bucket.bundle = who.bundle }
            buckets[who.name] = bucket
        }

        return buckets
            .map { EnergyApp(id: $0.key, name: $0.key, category: $0.value.category, cpu: $0.value.cpu, power: $0.value.power,
                             processCount: $0.value.count, bundlePath: $0.value.bundle, pids: $0.value.pids) }
            .filter { $0.power >= 0.5 }
            .sorted { $0.power > $1.power }
            .prefix(8)
            .map { $0 }
    }

    static func readSleepBlockers() -> [SleepBlocker] {
        let out = run("/usr/bin/pmset", ["-g", "assertions"], timeout: 4.0)
        var result: [SleepBlocker] = []
        var seen = Set<String>()
        for line in out.components(separatedBy: "\n") {
            // "   pid 69077(AuraTube): [0x...] 03:16:06 PreventUserIdleSystemSleep named: "AuraTube Video Playback""
            guard let pidRange = line.range(of: #"pid \d+\(([^)]+)\)"#, options: .regularExpression) else { continue }
            let kinds = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]
            guard let kind = kinds.first(where: { line.contains($0) }) else { continue }
            let pidText = String(line[pidRange])
            guard let open = pidText.firstIndex(of: "("), let close = pidText.lastIndex(of: ")") else { continue }
            let name = String(pidText[pidText.index(after: open)..<close])
            if ["powerd", "BatFlow"].contains(name) { continue }
            var reason = ""
            if let namedRange = line.range(of: "named: \"") {
                reason = String(line[namedRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            let blocksDisplay = kind.contains("Display")
            let key = name + (blocksDisplay ? "#d" : "#s")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(SleepBlocker(id: key, processName: name, kind: blocksDisplay ? "Giữ màn hình sáng" : "Chặn máy ngủ", reason: reason))
        }
        return result
    }
}
