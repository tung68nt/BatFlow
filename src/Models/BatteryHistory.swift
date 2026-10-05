import Foundation

// MARK: - Battery History Persistence Record
struct HistoryCacheItem: Codable {
    let t: Double
    let p: Double
}

// MARK: - Battery History Manager
final class BatteryHistoryManager {
    static let shared = BatteryHistoryManager()
    
    private var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("battery_history.json")
    }

    func loadCachedHistory() -> [(Date, Double)] {
        guard let data = try? Data(contentsOf: historyFileURL),
              let items = try? JSONDecoder().decode([HistoryCacheItem].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        return items
            .filter { $0.t >= cutoff }
            .map { (Date(timeIntervalSince1970: $0.t), $0.p) }
    }

    func saveCachedHistory(_ entries: [(Date, Double)]) {
        let items = entries.map { HistoryCacheItem(t: $0.0.timeIntervalSince1970, p: $0.1) }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: historyFileURL, options: .atomic)
            // Ensure restrictive permissions (read/write only for user)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFileURL.path)
        }
    }

    /// Charge levels macOS itself logged (also while BatFlow was not running or the Mac was asleep).
    func fetchSystemBatteryLogs(cutoff: Date) -> [(Date, Double)] {
        let raw = EnergyMonitor.run("/usr/bin/pmset", ["-g", "log"], timeout: 12.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let now = Date()

        var parsedEntries: [(Date, Double)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 26, line.first?.isNumber == true, line.contains("Charge") else { continue }
            guard let range = line.range(of: #"Using (AC|BATT|Batt)\s*\(Charge:\s*\d+"#, options: .regularExpression),
                  let colon = line[range].lastIndex(of: ":"),
                  let pct = Double(line[range][line.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
                  let date = formatter.date(from: String(line.prefix(25))),
                  date >= cutoff, date <= now, pct >= 0, pct <= 100 else { continue }
            parsedEntries.append((date, pct / 100.0))
        }
        return parsedEntries
    }
}
