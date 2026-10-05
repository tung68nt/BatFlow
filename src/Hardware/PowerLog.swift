import Foundation

// MARK: - Power Timeline Event
struct PowerEvent: Identifiable {
    enum Kind {
        case displayOn, displayOff, sleep, wake, plugged, unplugged
    }
    let id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
}

// MARK: - Power Log Reader (parses `pmset -g log`, available on every macOS release without extra tools)
final class PowerLog: ObservableObject {
    static let shared = PowerLog()

    @Published var events: [PowerEvent] = []
    @Published var screenSecondsToday: Int = 0
    @Published var sessionStart: Date?
    @Published var loadedAt: Date?

    // Battery session: when the charger was last pulled, and every sleep / wake since the log began
    @Published var unplugFromLog: (date: Date, pct: Int?)?
    @Published var lastACLine: Date?
    private var wakeTransitions: [(date: Date, awake: Bool)] = []

    private var isLoading = false
    private let defaults = UserDefaults.standard

    /// Called when BatFlow itself sees the charger being pulled: exact to the second, unlike the log,
    /// which only shows the new power source on its next line.
    func noteUnplug(pct: Int) {
        defaults.set(Date().timeIntervalSince1970, forKey: "power.observedUnplug")
        defaults.set(pct, forKey: "power.observedUnplugPct")
        objectWillChange.send()
    }

    /// Start of the current battery session: BatFlow's own observation when it is newer than the last
    /// log line on AC, otherwise the first battery line in the log.
    var lastUnplug: (date: Date, pct: Int?)? {
        let observedAt = defaults.double(forKey: "power.observedUnplug")
        if observedAt > 0 {
            let observed = Date(timeIntervalSince1970: observedAt)
            let coversCurrentSession = lastACLine.map { observed > $0 } ?? true
            let notOlderThanLog = unplugFromLog.map { observed <= $0.date.addingTimeInterval(120) } ?? true
            if coversCurrentSession && notOlderThanLog {
                let pct = defaults.integer(forKey: "power.observedUnplugPct")
                return (observed, pct > 0 ? pct : unplugFromLog?.pct)
            }
        }
        return unplugFromLog
    }

    /// Seconds the Mac has been awake since the charger was last pulled. Sleep is excluded; a closed lid
    /// with the system still running counts, because nothing in the log puts the system to sleep then.
    /// Background maintenance wakes (DarkWake) while asleep are not counted.
    func awakeSecondsSinceUnplug(now: Date = Date()) -> Int? {
        guard let start = lastUnplug?.date, start <= now else { return nil }
        // state in effect at the start = the last transition before it (awake when the log has none)
        var awake = wakeTransitions.last(where: { $0.date <= start })?.awake ?? true
        var cursor = start
        var total = 0.0
        for change in wakeTransitions where change.date > start && change.date <= now {
            if awake { total += change.date.timeIntervalSince(cursor) }
            awake = change.awake
            cursor = change.date
        }
        if awake { total += now.timeIntervalSince(cursor) }
        return Int(total)
    }

    /// Seconds of screen-on time so far today, extrapolated live from the last parse.
    func liveScreenSeconds(now: Date = Date()) -> Int {
        guard let loaded = loadedAt else { return 0 }
        let extra = sessionStart != nil ? Int(now.timeIntervalSince(loaded)) : 0
        return screenSecondsToday + max(0, extra)
    }

    func liveSessionSeconds(now: Date = Date()) -> Int {
        guard let start = sessionStart else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = EnergyMonitor.run("/usr/bin/pmset", ["-g", "log"], timeout: 12.0)
            let parsed = PowerLog.parse(raw)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.events = parsed.events
                self.screenSecondsToday = parsed.screenSeconds
                self.sessionStart = parsed.sessionStart
                self.unplugFromLog = parsed.unplug
                self.lastACLine = parsed.lastACLine
                self.wakeTransitions = parsed.wakeTransitions
                self.loadedAt = Date()
            }
        }
    }

    private struct Parsed {
        var events: [PowerEvent]
        var screenSeconds: Int
        var sessionStart: Date?
        var unplug: (date: Date, pct: Int?)?
        var lastACLine: Date?
        var wakeTransitions: [(date: Date, awake: Bool)]
    }

    private static func parse(_ raw: String) -> Parsed {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let horizon = now.addingTimeInterval(-36 * 3600)

        var events: [PowerEvent] = []
        var displayOnAt: Date?
        var screenSeconds = 0.0
        var lastOnAC: Bool?
        var unplug: (date: Date, pct: Int?)?
        var lastACLine: Date?
        var wakeTransitions: [(date: Date, awake: Bool)] = []

        func closeScreen(at date: Date) {
            guard let on = displayOnAt else { return }
            let from = max(on, startOfDay)
            if date > from { screenSeconds += date.timeIntervalSince(from) }
            displayOnAt = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 26, line.first?.isNumber == true else { continue }
            let interesting = line.contains("Display is turned") || line.contains("Entering Sleep") || line.contains("Wake from") || line.contains("Using ")
            guard interesting, let date = formatter.date(from: String(line.prefix(25))), date <= now else { continue }
            let text = String(line)

            func chargePct() -> String {
                guard let r = text.range(of: #"Charge:\s*(\d+)"#, options: .regularExpression) else { return "" }
                return String(text[r].filter { $0.isNumber })
            }

            if text.contains("Display is turned on") {
                if displayOnAt == nil { displayOnAt = date }
                events.append(PowerEvent(date: date, kind: .displayOn, title: "Bật sáng màn hình", detail: "Phiên làm việc bắt đầu"))
            } else if text.contains("Display is turned off") {
                closeScreen(at: date)
                events.append(PowerEvent(date: date, kind: .displayOff, title: "Tắt màn hình", detail: "Màn hình tạm tắt tiết kiệm năng lượng"))
            } else if text.contains("Entering Sleep") {
                closeScreen(at: date)
                if wakeTransitions.last?.awake != false { wakeTransitions.append((date, false)) }
                if !text.contains("Maintenance Sleep") && !text.contains("DarkWake") {
                    let reason = text.contains("Clamshell") ? "Gập nắp máy" : (text.contains("Idle") ? "Nhàn rỗi" : (text.contains("Software") ? "Người dùng chọn ngủ" : "Hệ thống"))
                    events.append(PowerEvent(date: date, kind: .sleep, title: "Chuyển sang chế độ ngủ", detail: "Lý do: \(reason)"))
                }
            } else if text.contains("Wake from") && !text.contains("DarkWake") {
                if wakeTransitions.last?.awake != true { wakeTransitions.append((date, true)) }
                events.append(PowerEvent(date: date, kind: .wake, title: "Máy thức dậy", detail: text.contains("lid") ? "Mở nắp máy" : "Tiếp tục phiên làm việc"))
            }

            // Every log line carries the power source in effect; a change between lines is a plug / unplug.
            let onAC: Bool? = text.contains("Using AC") ? true : (text.range(of: "Using Batt", options: .caseInsensitive) != nil ? false : nil)
            if let onAC = onAC {
                if let previous = lastOnAC, previous != onAC {
                    let pct = chargePct()
                    let level = pct.isEmpty ? "" : " (\(pct)%)"
                    if onAC {
                        events.append(PowerEvent(date: date, kind: .plugged, title: "Cắm nguồn sạc\(level)", detail: "Chuyển sang dùng nguồn ngoài"))
                    } else {
                        events.append(PowerEvent(date: date, kind: .unplugged, title: "Rút sạc\(level)", detail: "Chuyển sang dùng pin"))
                    }
                }
                if onAC {
                    lastACLine = date
                    unplug = nil
                } else if unplug == nil {
                    unplug = (date, Int(chargePct()))
                }
                lastOnAC = onAC
            }
        }

        let sessionStart = displayOnAt
        if let on = displayOnAt {
            let from = max(on, startOfDay)
            screenSeconds += max(0, now.timeIntervalSince(from))
        }
        return Parsed(events: Array(events.filter { $0.date >= horizon }.suffix(10).reversed()), screenSeconds: Int(screenSeconds),
                      sessionStart: sessionStart, unplug: unplug, lastACLine: lastACLine, wakeTransitions: wakeTransitions)
    }
}
