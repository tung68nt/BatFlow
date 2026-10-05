import Foundation
import AppKit
import UserNotifications

// MARK: - Guided Scenario Model
// A scenario is a list of steps; each step waits for a battery condition the user brings about (plug / unplug).
enum CareScenarioKind: String {
    case calibration, drainToLimit, storage

    var title: String {
        switch self {
        case .calibration: return "Hiệu chuẩn pin"
        case .drainToLimit: return "Xả về ngưỡng"
        case .storage: return "Chuẩn bị cất máy"
        }
    }
}

struct CareStep {
    enum Goal {
        case reachAtLeast(Int)
        case reachAtMost(Int)
        case holdMinutes(Int)
    }
    let title: String
    let instruction: String
    let goal: Goal
    let needsPower: Bool?
}

// MARK: - Battery Care Engine (no elevated privileges: observes, reminds, and guides)
final class BatteryCare: ObservableObject {
    static let shared = BatteryCare()

    // Settings (persisted)
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "care.alertsEnabled") } }
    @Published var alertHigh: Int { didSet { defaults.set(alertHigh, forKey: "care.alertHigh") } }
    @Published var alertLow: Int { didSet { defaults.set(alertLow, forKey: "care.alertLow") } }
    @Published var heatAlertEnabled: Bool { didSet { defaults.set(heatAlertEnabled, forKey: "care.heatAlert") } }
    @Published var heatThreshold: Int { didSet { defaults.set(heatThreshold, forKey: "care.heatThreshold") } }

    // System state
    @Published var nativeLimit: Int?
    @Published var nativeLimitSupported = false
    @Published var lowPowerMode = false

    // Scenario state
    @Published var scenario: CareScenarioKind?
    @Published var steps: [CareStep] = []
    @Published var stepIndex = 0
    @Published var holdUntil: Date?

    private let defaults = UserDefaults.standard
    private var highAlertArmed = true
    private var lowAlertArmed = true
    private var heatAlertArmed = true
    private var lastLimitRead = Date.distantPast
    private var isReadingLimit = false
    private var lastPowerNudge = Date.distantPast

    private init() {
        defaults.register(defaults: [
            "care.alertsEnabled": false, "care.alertHigh": 80, "care.alertLow": 20,
            "care.heatAlert": true, "care.heatThreshold": 38
        ])
        alertsEnabled = defaults.bool(forKey: "care.alertsEnabled")
        alertHigh = defaults.integer(forKey: "care.alertHigh")
        alertLow = defaults.integer(forKey: "care.alertLow")
        heatAlertEnabled = defaults.bool(forKey: "care.heatAlert")
        heatThreshold = defaults.integer(forKey: "care.heatThreshold")

        refreshLowPower()
        if #available(macOS 12.0, *) {
            NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshLowPower()
            }
        }
        restoreScenario()
    }

    var currentStep: CareStep? {
        return steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    /// The level macOS itself stops charging at, or 100 when no limit is set.
    var effectiveLimit: Int { nativeLimit ?? 100 }

    private func refreshLowPower() {
        if #available(macOS 12.0, *) {
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: Native macOS charge limit (read-only; changing it requires an Apple-private entitlement)

    func refreshNativeLimit(force: Bool = false) {
        guard !isReadingLimit, force || Date().timeIntervalSince(lastLimitRead) > 60 else { return }
        isReadingLimit = true
        lastLimitRead = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = EnergyMonitor.run("/usr/bin/pmset", ["-g", "battlimit"], timeout: 4.0)
            var limit: Int?
            if let r = out.range(of: #"chargeSocLimitSoc\s*=\s*(\d+)"#, options: .regularExpression) {
                let digits = out[r].split(separator: "=").last.map { $0.filter { $0.isNumber } } ?? ""
                if let value = Int(digits), value > 0, value < 100 { limit = value }
            }
            let supported = out.contains("Battery level limits") || out.contains("No battery level limits")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isReadingLimit = false
                self.nativeLimit = limit
                self.nativeLimitSupported = supported
            }
        }
    }

    static func openBatterySettings() {
        let candidates = ["x-apple.systempreferences:com.apple.Battery-Settings.extension", "x-apple.systempreferences:com.apple.preference.battery"]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Sampling hook

    func tick(_ model: BatteryViewModel) {
        guard model.hasBattery, model.currentPct > 0 else { return }
        refreshNativeLimit()
        evaluateAlerts(model)
        advanceScenario(model)
    }

    private func evaluateAlerts(_ model: BatteryViewModel) {
        let pct = model.currentPct

        if alertsEnabled, scenario == nil {
            if model.isExtConnected && model.isCharging {
                if pct >= alertHigh && highAlertArmed {
                    highAlertArmed = false
                    notify(id: "care-high", title: "Pin đã đạt \(pct)%", body: "Rút sạc lúc này để giảm thời gian pin nằm ở mức điện áp cao.")
                }
            }
            if pct < alertHigh - 2 || !model.isExtConnected { highAlertArmed = true }

            if !model.isExtConnected {
                if pct <= alertLow && lowAlertArmed {
                    lowAlertArmed = false
                    notify(id: "care-low", title: "Pin còn \(pct)%", body: "Cắm sạc để tránh xả sâu, pin lithium bền hơn khi không xuống dưới 20%.")
                }
            }
            if pct > alertLow + 2 || model.isExtConnected { lowAlertArmed = true }
        }

        if heatAlertEnabled, model.tempC > 0 {
            if model.tempC >= Double(heatThreshold) && heatAlertArmed {
                heatAlertArmed = false
                let advice = model.isCharging ? "Nên tạm rút sạc hoặc giảm tải cho tới khi máy nguội." : "Nên giảm tải hoặc để máy ở nơi thoáng."
                notify(id: "care-heat", title: String(format: "Pin đang nóng %.1f°C", model.tempC), body: advice)
            }
            if model.tempC <= Double(heatThreshold) - 3 { heatAlertArmed = true }
        }
    }

    // MARK: Scenarios

    private func buildSteps(_ kind: CareScenarioKind, model: BatteryViewModel?) -> [CareStep] {
        let limit = effectiveLimit
        switch kind {
        case .calibration:
            let fullHint = limit < 100
                ? "macOS đang giới hạn sạc ở \(limit)%. Mở Cài đặt › Pin và đặt giới hạn 100% trong lúc hiệu chuẩn, sau đó cắm sạc."
                : "Cắm sạc và để máy sạc liền mạch tới 100%."
            return [
                CareStep(title: "Sạc đầy 100%", instruction: fullHint, goal: .reachAtLeast(100), needsPower: true),
                CareStep(title: "Giữ sạc thêm 60 phút", instruction: "Vẫn cắm sạc để các cell cân bằng điện áp ở mức đầy.", goal: .holdMinutes(60), needsPower: true),
                CareStep(title: "Xả xuống 15%", instruction: "Rút sạc và dùng máy bình thường. BatFlow sẽ báo khi pin về 15%.", goal: .reachAtMost(15), needsPower: false),
                CareStep(title: "Sạc lại 100%", instruction: "Cắm sạc và để sạc liền mạch tới 100%, không rút giữa chừng.", goal: .reachAtLeast(100), needsPower: true)
            ]
        case .drainToLimit:
            let target = limit < 100 ? limit : 80
            return [
                CareStep(title: "Xả xuống \(target)%", instruction: "Rút sạc và dùng máy. BatFlow sẽ báo khi pin về \(target)% để bạn cắm lại.", goal: .reachAtMost(target), needsPower: false)
            ]
        case .storage:
            let pct = model?.currentPct ?? 50
            if pct > 52 {
                return [CareStep(title: "Xả xuống 50%", instruction: "Rút sạc và dùng máy tới khi pin về 50%.", goal: .reachAtMost(50), needsPower: false)]
            }
            return [CareStep(title: "Sạc lên 50%", instruction: "Cắm sạc tới khi pin lên 50% rồi rút ra.", goal: .reachAtLeast(50), needsPower: true)]
        }
    }

    func start(_ kind: CareScenarioKind, model: BatteryViewModel) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scenario = kind
        steps = buildSteps(kind, model: model)
        stepIndex = 0
        holdUntil = nil
        persistScenario()
        advanceScenario(model)
    }

    func cancelScenario() {
        scenario = nil
        steps = []
        stepIndex = 0
        holdUntil = nil
        persistScenario()
    }

    private func persistScenario() {
        defaults.set(scenario?.rawValue, forKey: "care.scenario")
        defaults.set(stepIndex, forKey: "care.stepIndex")
        defaults.set(holdUntil?.timeIntervalSince1970 ?? 0, forKey: "care.holdUntil")
    }

    private func restoreScenario() {
        guard let raw = defaults.string(forKey: "care.scenario"), let kind = CareScenarioKind(rawValue: raw) else { return }
        scenario = kind
        steps = buildSteps(kind, model: nil)
        stepIndex = min(defaults.integer(forKey: "care.stepIndex"), max(0, steps.count - 1))
        let hold = defaults.double(forKey: "care.holdUntil")
        holdUntil = hold > 0 ? Date(timeIntervalSince1970: hold) : nil
    }

    /// Progress of the current step in 0...1, for the UI.
    func stepProgress(_ model: BatteryViewModel) -> Double {
        guard let step = currentStep else { return 0 }
        switch step.goal {
        case .reachAtLeast(let target):
            return max(0, min(1, Double(model.currentPct) / Double(max(1, target))))
        case .reachAtMost(let target):
            let span = Double(max(1, 100 - target))
            return max(0, min(1, Double(100 - model.currentPct) / span))
        case .holdMinutes(let minutes):
            guard let until = holdUntil else { return 0 }
            let total = Double(minutes * 60)
            return max(0, min(1, 1 - until.timeIntervalSinceNow / total))
        }
    }

    private func advanceScenario(_ model: BatteryViewModel) {
        guard let kind = scenario, let step = currentStep else { return }
        let pct = model.currentPct
        var done = false

        switch step.goal {
        case .reachAtLeast(let target):
            done = pct >= target || (target >= 100 && model.isFullyCharged)
        case .reachAtMost(let target):
            done = pct <= target
        case .holdMinutes(let minutes):
            if !model.isExtConnected {
                holdUntil = nil
            } else if holdUntil == nil {
                holdUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
                persistScenario()
            } else if let until = holdUntil, Date() >= until {
                done = true
            }
        }

        if done {
            holdUntil = nil
            if stepIndex + 1 < steps.count {
                stepIndex += 1
                persistScenario()
                if let next = currentStep {
                    notify(id: "care-step", title: "\(kind.title): \(next.title)", body: next.instruction)
                }
            } else {
                let closing: String
                switch kind {
                case .calibration: closing = "Dung lượng đã được đo lại. Hãy đặt lại giới hạn sạc thường dùng trong Cài đặt › Pin."
                case .drainToLimit: closing = "Pin đã về ngưỡng. Bạn có thể cắm sạc lại."
                case .storage: closing = "Pin đang ở 50%. Tắt máy và cất nơi khô mát, kiểm tra lại sau mỗi 6 tháng."
                }
                notify(id: "care-step", title: "\(kind.title) hoàn tất", body: closing)
                cancelScenario()
            }
            return
        }

        // Nudge at most every 30 minutes when the charger state contradicts the current step.
        if let needsPower = step.needsPower, needsPower != model.isExtConnected, Date().timeIntervalSince(lastPowerNudge) > 1800 {
            lastPowerNudge = Date()
            notify(id: "care-nudge", title: "\(kind.title): \(step.title)", body: needsPower ? "Hãy cắm sạc để tiếp tục." : "Hãy rút sạc để tiếp tục.")
        }
    }

    // MARK: Notifications

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
