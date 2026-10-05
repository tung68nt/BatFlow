import Foundation
import AppKit

// MARK: - Thermal Guard
// Protects the battery from heat by lowering the load: it suggests which app to quit and can move apps the
// user has allowed to background priority (efficiency cores on Apple Silicon). No elevated privileges:
// it only touches the user's own apps, and every change is undone when the Mac cools down or BatFlow quits.
final class ThermalGuard: ObservableObject {
    static let shared = ThermalGuard()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "guard.enabled"); if !enabled { restoreAll() } } }
    @Published var autoThrottle: Bool { didSet { defaults.set(autoThrottle, forKey: "guard.auto") } }
    @Published var allowedApps: Set<String> { didSet { defaults.set(Array(allowedApps), forKey: "guard.allowed") } }

    @Published var isHot = false
    @Published var fans: [SMCReader.Fan] = []
    /// App name → pids currently held at background priority by BatFlow.
    @Published var throttled: [String: [pid_t]] = [:]

    private let defaults = UserDefaults.standard
    private var lastEvaluation = Date.distantPast
    private var lastFanRead = Date.distantPast
    private var suggestedThisEpisode = false

    private init() {
        enabled = defaults.bool(forKey: "guard.enabled")
        autoThrottle = defaults.bool(forKey: "guard.auto")
        allowedApps = Set(defaults.stringArray(forKey: "guard.allowed") ?? [])
    }

    /// Only regular third-party apps may be slowed down: never system components, never BatFlow itself.
    static func canManage(_ app: EnergyApp) -> Bool {
        guard let path = app.bundlePath, !path.hasPrefix("/System/") else { return false }
        return path != Bundle.main.bundlePath && app.name != "BatFlow"
    }

    func isThrottled(_ app: EnergyApp) -> Bool {
        return throttled[app.name] != nil
    }

    func throttle(_ app: EnergyApp) {
        guard ThermalGuard.canManage(app) else { return }
        var applied = throttled[app.name] ?? []
        for pid in app.pids where !applied.contains(pid) {
            if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0 {
                applied.append(pid)
            }
        }
        if !applied.isEmpty { throttled[app.name] = applied }
    }

    func restore(appNamed name: String) {
        for pid in throttled[name] ?? [] {
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
        }
        throttled[name] = nil
    }

    func restoreAll() {
        for name in Array(throttled.keys) { restore(appNamed: name) }
    }

    func refreshFans() {
        guard Date().timeIntervalSince(lastFanRead) >= 2 else { return }
        lastFanRead = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fans = SMCReader.shared.fans()
            DispatchQueue.main.async { self?.fans = fans }
        }
    }

    func tick(_ model: BatteryViewModel) {
        refreshFans()
        guard enabled, model.tempC > 0 else {
            if isHot { isHot = false }
            return
        }
        let threshold = Double(BatteryCare.shared.heatThreshold)

        if !isHot, model.tempC >= threshold {
            isHot = true
            suggestedThisEpisode = false
            lastEvaluation = Date.distantPast
            EnergyMonitor.shared.sample()
        } else if isHot, model.tempC <= threshold - 3 {
            isHot = false
            if !throttled.isEmpty {
                let names = throttled.keys.sorted().joined(separator: ", ")
                restoreAll()
                BatteryCare.shared.notify(id: "care-thermal", title: String(format: "Pin đã nguội %.1f°C", model.tempC),
                                          body: "Đã trả lại tốc độ bình thường cho \(names).")
            }
        }

        // While hot, look at the consumers every 45 seconds (the first look waits for a fresh energy sample)
        guard isHot, Date().timeIntervalSince(lastEvaluation) >= 45 else { return }
        let apps = EnergyMonitor.shared.apps
        guard let sampled = EnergyMonitor.shared.lastUpdated, Date().timeIntervalSince(sampled) < 30, !apps.isEmpty else {
            EnergyMonitor.shared.sample()
            return
        }
        lastEvaluation = Date()
        let heavy = apps.filter { ThermalGuard.canManage($0) && $0.power >= 10 }

        var newlySlowed: [String] = []
        if autoThrottle {
            for app in heavy where allowedApps.contains(app.name) {
                let before = throttled[app.name]?.count ?? 0
                throttle(app)
                if before == 0, throttled[app.name] != nil { newlySlowed.append(app.name) }
            }
        }

        if !newlySlowed.isEmpty {
            BatteryCare.shared.notify(id: "care-thermal", title: String(format: "Pin nóng %.1f°C, đã giảm tải", model.tempC),
                                      body: "Đang chạy chậm lại: \(newlySlowed.joined(separator: ", ")). Sẽ trả lại bình thường khi pin nguội.")
            suggestedThisEpisode = true
        } else if !suggestedThisEpisode, let top = heavy.first(where: { !isThrottled($0) }) {
            suggestedThisEpisode = true
            let advice = model.isCharging ? " Tạm rút sạc cũng giúp pin nguội nhanh hơn." : ""
            BatteryCare.shared.notify(id: "care-thermal", title: String(format: "Pin nóng %.1f°C", model.tempC),
                                      body: "\(top.name) đang tiêu thụ nhiều nhất (Energy Impact \(Int(top.power))). Nên thoát hoặc hạ ưu tiên ứng dụng này.\(advice)")
        }
    }
}
