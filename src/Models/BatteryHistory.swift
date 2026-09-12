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

    func fetchSystemBatteryLogs(cutoff: Date) -> [(Date, Double)] {
        let now = Date()
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy.MM.dd"
        
        var dates = [now]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            dates.insert(yesterday, at: 0)
        }
        
        var parsedEntries: [(Date, Double)] = []
        let parseDf = DateFormatter()
        parseDf.dateFormat = "yyyy MMM d HH:mm:ss"
        parseDf.locale = Locale(identifier: "en_US_POSIX")
        
        let year = calendar.component(.year, from: now)
        
        for d in dates {
            let fpath = "/private/var/log/powermanagement/\(df.string(from: d)).asl"
            guard FileManager.default.fileExists(atPath: fpath) else { continue }
            
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/syslog")
            proc.arguments = ["-f", fpath]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try? proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            
            guard let output = String(data: data, encoding: .utf8) else { continue }
            let lines = output.components(separatedBy: "\n")
            
            for line in lines {
                guard line.contains("Charge") && (line.contains("Using AC") || line.contains("Using Batt")) else { continue }
                guard line.count >= 15 else { continue }
                let datePrefix = String(line.prefix(15))
                
                if let chargeRange = line.range(of: "Charge:?\\s*(\\d+)", options: .regularExpression) {
                    let match = String(line[chargeRange])
                    let digits = match.filter { $0.isNumber }
                    if let pctVal = Double(digits), let logDate = parseDf.date(from: "\(year) \(datePrefix)") {
                        if logDate >= cutoff && logDate <= now {
                            parsedEntries.append((logDate, pctVal / 100.0))
                        }
                    }
                }
            }
        }
        return parsedEntries
    }
}
