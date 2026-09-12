import Foundation
import AppKit
import Combine
import UserNotifications

// MARK: - Update Status State Machine
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(version: String, title: String, notes: String, downloadURL: URL?, dmgSize: Int64)
    case downloading(progress: Double, bytesReceived: Int64, totalBytes: Int64)
    case readyToInstall(fileURL: URL)
    case installing
    case error(message: String)

    static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.installing, .installing):
            return true
        case (.upToDate(let a), .upToDate(let b)):
            return a == b
        case (.updateAvailable(let v1, _, _, _, _), .updateAvailable(let v2, _, _, _, _)):
            return v1 == v2
        case (.downloading(let p1, _, _), .downloading(let p2, _, _)):
            return abs(p1 - p2) < 0.001
        case (.readyToInstall(let u1), .readyToInstall(let u2)):
            return u1 == u2
        case (.error(let m1), .error(let m2)):
            return m1 == m2
        default:
            return false
        }
    }
}

// MARK: - Native App Update Manager
class UpdateManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    // Configurable GitHub Repository
    var githubRepo: String = "tung68nt/BatFlow"
    
    @Published var status: UpdateStatus = .idle
    @Published var latestVersion: String? = nil
    @Published var releaseNotes: String = ""
    @Published var releaseTitle: String = ""
    @Published var downloadURL: URL? = nil
    @Published var dmgSize: Int64 = 0
    @Published var downloadedFileURL: URL? = nil
    @Published var downloadProgress: Double = 0.0
    @Published var isShowingUpdateSheet: Bool = false
    @Published var lastCheckedDate: Date? = nil
    @Published var hasUnreadUpdateNotice: Bool = false

    private var autoScanTimer: Timer?
    private var hasNotifiedThisLaunch: Bool = false
    private let lastNotifiedTimestampKey = "LastNotifiedUpdateTimestamp"
    private var downloadTask: URLSessionDownloadTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()

    var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var currentBuild: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2026.09.04"
    }

    var isUpdateAvailable: Bool {
        if case .updateAvailable = status { return true }
        if case .downloading = status { return true }
        if case .readyToInstall = status { return true }
        return false
    }

    var lastCheckedFormatted: String {
        guard let date = lastCheckedDate else { return "Chưa kiểm tra" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "HH:mm • dd/MM/yyyy"
        return formatter.string(from: date)
    }

    override init() {
        super.init()
    }

    // MARK: - Check For Updates
    func resetAndCheck() {
        status = .checking
        checkForUpdates(userInitiated: true)
    }

    func checkForUpdates(userInitiated: Bool = false) {
        if case .downloading = status { return }

        status = .checking
        if userInitiated {
            isShowingUpdateSheet = true
        }

        // 1. First attempt: Raw Manifest version.json (Fast, no GitHub API rate limit)
        let cacheBuster = Int(Date().timeIntervalSince1970)
        let manifestURLString = "https://raw.githubusercontent.com/\(githubRepo)/main/version.json?t=\(cacheBuster)"
        guard let manifestURL = URL(string: manifestURLString) else {
            checkGitHubReleases(userInitiated: userInitiated)
            return
        }

        var req = URLRequest(url: manifestURL)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 10.0

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastCheckedDate = Date()

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let data = data {
                    if self.parseManifestResponse(data: data, userInitiated: userInitiated) {
                        return
                    }
                }

                // Fallback to GitHub Release API if manifest unavailable
                self.checkGitHubReleases(userInitiated: userInitiated)
            }
        }.resume()
    }

    private func checkGitHubReleases(userInitiated: Bool) {
        let apiURLString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: apiURLString) else {
            handleError("URL kho lưu trữ không hợp lệ.", userInitiated: userInitiated)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("BatFlow-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastCheckedDate = Date()

                if let error = error {
                    self.handleError("Không thể kết nối máy chủ: \(error.localizedDescription)", userInitiated: userInitiated)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.handleError("Phản hồi máy chủ không hợp lệ.", userInitiated: userInitiated)
                    return
                }

                if httpResponse.statusCode == 404 {
                    // No releases published yet on repo -> Current version is up to date
                    self.status = .upToDate(version: self.currentVersion)
                    return
                }

                guard (200...299).contains(httpResponse.statusCode), let data = data else {
                    self.handleError("Lỗi máy chủ HTTP (\(httpResponse.statusCode)).", userInitiated: userInitiated)
                    return
                }

                self.parseReleaseResponse(data: data, userInitiated: userInitiated)
            }
        }.resume()
    }

    @discardableResult
    private func parseManifestResponse(data: Data, userInitiated: Bool) -> Bool {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return false
            }

            guard let remoteVersion = json["version"] as? String, !remoteVersion.isEmpty else {
                return false
            }

            let cleanRemoteVersion = remoteVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let name = (json["title"] as? String) ?? "BatFlow v\(cleanRemoteVersion)"
            let body = (json["releaseNotes"] as? String) ?? "Bản cập nhật tối ưu hóa hiệu năng và sửa lỗi."

            var foundDmgURL: URL? = nil
            if let dlStr = json["downloadUrl"] as? String, let u = URL(string: dlStr) {
                foundDmgURL = u
            }

            var foundDmgSize: Int64 = 0
            if let sizeNum = json["fileSize"] as? NSNumber {
                foundDmgSize = sizeNum.int64Value
            } else if let sizeStr = json["fileSize"] as? String {
                let clean = sizeStr.replacingOccurrences(of: "MB", with: "").trimmingCharacters(in: .whitespaces)
                if let mb = Double(clean) {
                    foundDmgSize = Int64(mb * 1024 * 1024)
                }
            }

            self.latestVersion = cleanRemoteVersion
            self.releaseTitle = name
            self.releaseNotes = body
            self.downloadURL = foundDmgURL
            self.dmgSize = foundDmgSize

            if isVersion(cleanRemoteVersion, newerThan: currentVersion) {
                self.status = .updateAvailable(
                    version: cleanRemoteVersion,
                    title: name,
                    notes: body,
                    downloadURL: foundDmgURL,
                    dmgSize: foundDmgSize
                )
                self.hasUnreadUpdateNotice = true

                if userInitiated {
                    self.isShowingUpdateSheet = true
                } else {
                    notifyIfNeeded(version: cleanRemoteVersion, notes: body)
                }
            } else {
                self.hasUnreadUpdateNotice = false
                self.status = .upToDate(version: self.currentVersion)
            }
            return true
        } catch {
            return false
        }
    }

    private func notifyIfNeeded(version: String, notes: String) {
        let now = Date()
        let lastTimestamp = UserDefaults.standard.double(forKey: self.lastNotifiedTimestampKey)
        let hoursSinceLastNotified = (now.timeIntervalSince1970 - lastTimestamp) / 3600.0

        let shouldNotify = !self.hasNotifiedThisLaunch || hoursSinceLastNotified >= 24.0

        if shouldNotify {
            self.hasNotifiedThisLaunch = true
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.lastNotifiedTimestampKey)
            self.postUpdateNotification(version: version, notes: notes)
        }
    }

    private func parseReleaseResponse(data: Data, userInitiated: Bool) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                handleError("Định dạng dữ liệu không hợp lệ.", userInitiated: userInitiated)
                return
            }

            let tagName = (json["tag_name"] as? String) ?? ""
            let cleanRemoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let name = (json["name"] as? String) ?? "BatFlow v\(cleanRemoteVersion)"
            let body = (json["body"] as? String) ?? "Bản cập nhật tối ưu hóa hiệu năng và sửa lỗi."

            var foundDmgURL: URL? = nil
            var foundDmgSize: Int64 = 0

            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let assetName = asset["name"] as? String, assetName.hasSuffix(".dmg") {
                        if let dlUrlStr = asset["browser_download_url"] as? String, let u = URL(string: dlUrlStr) {
                            foundDmgURL = u
                            foundDmgSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
                            break
                        }
                    }
                }
            }

            // Fallback: if no DMG in assets, check html_url
            if foundDmgURL == nil, let htmlUrlStr = json["html_url"] as? String {
                foundDmgURL = URL(string: htmlUrlStr)
            }

            self.latestVersion = cleanRemoteVersion
            self.releaseTitle = name
            self.releaseNotes = body
            self.downloadURL = foundDmgURL
            self.dmgSize = foundDmgSize

            if isVersion(cleanRemoteVersion, newerThan: currentVersion) {
                self.status = .updateAvailable(
                    version: cleanRemoteVersion,
                    title: name,
                    notes: body,
                    downloadURL: foundDmgURL,
                    dmgSize: foundDmgSize
                )
                self.hasUnreadUpdateNotice = true

                if userInitiated {
                    self.isShowingUpdateSheet = true
                } else {
                    notifyIfNeeded(version: cleanRemoteVersion, notes: body)
                }
            } else {
                self.hasUnreadUpdateNotice = false
                self.status = .upToDate(version: self.currentVersion)
            }
        } catch {
            handleError("Không thể phân tích dữ liệu phiên bản: \(error.localizedDescription)", userInitiated: userInitiated)
        }
    }

    // MARK: - Auto Scan & User Notifications
    func startAutoScan(interval: TimeInterval = 4 * 3600) {
        requestNotificationPermission()

        // 1. Initial quick scan 3 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }

        // 2. Continuous scheduled auto-scan
        autoScanTimer?.invalidate()
        autoScanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func postUpdateNotification(version: String, notes: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚡ BatFlow: Đã có phiên bản mới v\(version)!"
        content.subtitle = "Cập nhật để có trải nghiệm tốt nhất"
        content.body = "Bản cập nhật tối ưu hóa hiệu năng, cải thiện dòng chảy năng lượng và độ chính xác của pin. Hãy nâng cấp ngay!"
        content.sound = .default

        let notificationId = "BatFlow_Update_\(version)_\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func handleError(_ message: String, userInitiated: Bool) {
        self.status = .error(message: message)
        if userInitiated {
            self.isShowingUpdateSheet = true
        }
    }

    // MARK: - Version Comparison (Semantic Versioning)
    func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Clean = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let v2Clean = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let parts1 = v1Clean.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2Clean.split(separator: ".").compactMap { Int($0) }

        let count = max(parts1.count, parts2.count)
        for i in 0..<count {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 > num2 { return true }
            if num1 < num2 { return false }
        }
        return false
    }

    // MARK: - Start Downloading DMG Asset
    func startDownload() {
        guard let url = downloadURL else {
            if let htmlStr = downloadURL?.absoluteString, let u = URL(string: htmlStr) {
                NSWorkspace.shared.open(u)
            }
            return
        }

        // If it's a direct DMG download
        if url.pathExtension.lowercased() == "dmg" {
            status = .downloading(progress: 0.0, bytesReceived: 0, totalBytes: dmgSize)
            downloadProgress = 0.0

            let request = URLRequest(url: url)
            downloadTask = urlSession.downloadTask(with: request)
            downloadTask?.resume()
        } else {
            // Open release page
            NSWorkspace.shared.open(url)
            status = .idle
            isShowingUpdateSheet = false
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = 0.0
        if let v = latestVersion {
            status = .updateAvailable(
                version: v,
                title: releaseTitle,
                notes: releaseNotes,
                downloadURL: downloadURL,
                dmgSize: dmgSize
            )
        } else {
            status = .idle
        }
    }

    // MARK: - Install & Relaunch
    func installAndRelaunch() {
        guard let dmgURL = downloadedFileURL, FileManager.default.fileExists(atPath: dmgURL.path) else {
            handleError("Không tìm thấy tệp cài đặt đã tải.", userInitiated: true)
            return
        }

        status = .installing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let mountPoint = "/Volumes/BatFlow_Update_\(UUID().uuidString.prefix(6))"
            let targetAppPath = "/Applications/BatFlow.app"

            // 1. Mount DMG silently
            let mountProc = Process()
            mountProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProc.arguments = ["attach", dmgURL.path, "-mountpoint", mountPoint, "-nobrowse", "-quiet", "-noautoopen"]
            try? mountProc.run()
            mountProc.waitUntilExit()

            let sourceAppPath = "\(mountPoint)/BatFlow.app"
            var installedSuccess = false

            if FileManager.default.fileExists(atPath: sourceAppPath) {
                let replaceScript = """
                sleep 0.8
                rm -rf "\(targetAppPath)"
                cp -R "\(sourceAppPath)" "\(targetAppPath)"
                /usr/bin/hdiutil detach "\(mountPoint)" -quiet || true
                open "\(targetAppPath)"
                """

                let updaterScriptPath = "/tmp/batflow_updater.sh"
                try? replaceScript.write(toFile: updaterScriptPath, atomically: true, encoding: .utf8)
                
                let chmodProc = Process()
                chmodProc.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmodProc.arguments = ["+x", updaterScriptPath]
                try? chmodProc.run()
                chmodProc.waitUntilExit()

                installedSuccess = true

                DispatchQueue.main.async {
                    let runProc = Process()
                    runProc.executableURL = URL(fileURLWithPath: "/bin/bash")
                    runProc.arguments = [updaterScriptPath]
                    try? runProc.run()

                    NSApplication.shared.terminate(nil)
                }
            }

            if !installedSuccess {
                // Fallback: Open DMG directly in Finder
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(dmgURL)
                    self.status = .readyToInstall(fileURL: dmgURL)
                }
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (dmgSize > 0 ? dmgSize : 1)
        let prog = max(0.0, min(1.0, Double(totalBytesWritten) / Double(expected)))
        
        DispatchQueue.main.async {
            self.downloadProgress = prog
            self.status = .downloading(progress: prog, bytesReceived: totalBytesWritten, totalBytes: expected)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("BatFlow-Latest.dmg")
        
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            DispatchQueue.main.async {
                self.downloadedFileURL = destinationURL
                self.status = .readyToInstall(fileURL: destinationURL)
            }
        } catch {
            DispatchQueue.main.async {
                self.handleError("Không thể lưu file DMG: \(error.localizedDescription)", userInitiated: true)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.handleError("Tải về thất bại: \(error.localizedDescription)", userInitiated: true)
            }
        }
    }
}
