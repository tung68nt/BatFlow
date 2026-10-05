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

    private var isLoading = false

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
                self.loadedAt = Date()
            }
        }
    }

    private static func parse(_ raw: String) -> (events: [PowerEvent], screenSeconds: Int, sessionStart: Date?) {
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
                if !text.contains("Maintenance Sleep") && !text.contains("DarkWake") {
                    let reason = text.contains("Clamshell") ? "Gập nắp máy" : (text.contains("Idle") ? "Nhàn rỗi" : (text.contains("Software") ? "Người dùng chọn ngủ" : "Hệ thống"))
                    events.append(PowerEvent(date: date, kind: .sleep, title: "Chuyển sang chế độ ngủ", detail: "Lý do: \(reason)"))
                }
            } else if text.contains("Wake from") && !text.contains("DarkWake") {
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
                lastOnAC = onAC
            }
        }

        let sessionStart = displayOnAt
        if let on = displayOnAt {
            let from = max(on, startOfDay)
            screenSeconds += max(0, now.timeIntervalSince(from))
        }
        return (Array(events.filter { $0.date >= horizon }.suffix(10).reversed()), Int(screenSeconds), sessionStart)
    }
}
