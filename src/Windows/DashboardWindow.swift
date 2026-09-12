import AppKit
import WebKit

// MARK: - Safe Web Navigation Delegate (Hardened Security)
class SafeWebNavDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var controller: DashboardWindowController?

    init(controller: DashboardWindowController? = nil) {
        self.controller = controller
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Open external web links (http, https) safely in user's default browser
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }

        // Allow all internal, file, data, and about:blank URLs
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BatFlow WKWebView navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("BatFlow WKWebView provisional navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - Native Window Drag View for WKWebView
class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        self.window?.performDrag(with: event)
    }
}

// MARK: - BatFlow Script Handler for Two-Way WKWebView Bridge
class BatFlowScriptHandler: NSObject, WKScriptMessageHandler {
    weak var controller: DashboardWindowController?

    init(controller: DashboardWindowController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let action = body["action"] as? String {
            if action == "refresh" {
                DispatchQueue.main.async {
                    self.controller?.refresh()
                }
            } else if action == "checkUpdate" || action == "check_update" {
                DispatchQueue.main.async {
                    self.controller?.onCheckUpdateRequested?()
                }
            }
        }
    }
}

// MARK: - Dashboard Window Controller
class DashboardWindowController: NSObject {
    static let shared = DashboardWindowController()

    var window: NSWindow?
    private var webView: WKWebView?
    private lazy var webNavDelegate = SafeWebNavDelegate(controller: self)
    private var refreshTimer: Timer?
    weak var modelProvider: BatteryViewModel?
    var onCheckUpdateRequested: (() -> Void)? = nil

    static var reportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let batflowDir = appSupport.appendingPathComponent("BatFlow")
        if !FileManager.default.fileExists(atPath: batflowDir.path) {
            try? FileManager.default.createDirectory(at: batflowDir, withIntermediateDirectories: true)
        }
        return batflowDir
    }

    static var reportHTMLURL: URL {
        return reportDirectory.appendingPathComponent("battery_report.html")
    }

    static var reportScriptURL: URL? {
        // 1. Bundle Resources
        if let bundleURL = Bundle.main.url(forResource: "generate_report", withExtension: "py") {
            return bundleURL
        }
        let inBundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/generate_report.py")
        if FileManager.default.fileExists(atPath: inBundlePath.path) {
            return inBundlePath
        }
        // 2. Application Support
        let appSupportScript = reportDirectory.appendingPathComponent("generate_report.py")
        if FileManager.default.fileExists(atPath: appSupportScript.path) {
            return appSupportScript
        }
        // 3. Current Working Directory fallback for development
        let cwdScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src/generate_report.py")
        if FileManager.default.fileExists(atPath: cwdScript.path) {
            return cwdScript
        }
        return nil
    }

    static var pythonExecutableURL: URL {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    var isVisible: Bool {
        return window?.isVisible ?? false
    }

    func loadReportHTML(into wv: WKWebView) {
        let reportURL = DashboardWindowController.reportHTMLURL

        // 1. Try loading freshly generated report from Application Support
        if FileManager.default.fileExists(atPath: reportURL.path),
           let html = try? String(contentsOf: reportURL, encoding: .utf8), !html.isEmpty {
            wv.loadHTMLString(html, baseURL: reportURL)
            return
        }

        // 2. Try loading pre-bundled fallback report template from Resources
        if let bundleURL = Bundle.main.url(forResource: "battery_report", withExtension: "html"),
           let html = try? String(contentsOf: bundleURL, encoding: .utf8), !html.isEmpty {
            wv.loadHTMLString(html, baseURL: bundleURL)
            return
        }

        // 3. Loading placeholder (Clean dark-mode, eliminates blank white window)
        let loadingHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            margin: 0;
            background: #161618;
            color: #F4F4F5;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            user-select: none;
        }
        .spinner {
            width: 32px;
            height: 32px;
            border: 2.5px solid rgba(255, 255, 255, 0.15);
            border-top-color: #0A84FF;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        .title {
            margin-top: 14px;
            font-size: 13.5px;
            font-weight: 600;
            color: #FFFFFF;
        }
        .desc {
            margin-top: 5px;
            font-size: 11px;
            color: rgba(255, 255, 255, 0.55);
        }
        </style>
        </head>
        <body>
        <div class="spinner"></div>
        <div class="title">Đang kết nối dữ liệu phần cứng BatFlow...</div>
        <div class="desc">Vui lòng đợi giây lát</div>
        </body>
        </html>
        """
        wv.loadHTMLString(loadingHTML, baseURL: nil)
    }

    func open(with model: BatteryViewModel) {
        self.modelProvider = model

        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "BatFlow • Báo Cáo Phân Tích Dòng Điện & Pin"
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 500)
        win.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1.0)

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        let handler = BatFlowScriptHandler(controller: self)
        userContent.add(handler, name: "batflow")
        config.userContentController = userContent

        let wv = WKWebView(frame: win.contentView!.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = webNavDelegate
        wv.uiDelegate = webNavDelegate
        wv.setValue(false, forKey: "drawsBackground")

        // Immediately load report or placeholder so window is NEVER blank
        loadReportHTML(into: wv)

        win.contentView = wv
        self.webView = wv
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refresh()

        // Auto-refresh timer when dashboard is open (every 60 seconds)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            self.refresh()
        }
    }

    func refresh() {
        guard let wv = webView else { return }
        guard let scriptURL = DashboardWindowController.reportScriptURL else {
            NSLog("BatFlow Error: generate_report.py script could not be located.")
            loadReportHTML(into: wv)
            return
        }

        let reportURL = DashboardWindowController.reportHTMLURL
        let pythonURL = DashboardWindowController.pythonExecutableURL
        let healthArg = String(modelProvider?.appleHealthPct ?? 100)

        wv.evaluateJavaScript("if (window.setRefreshLoading) { window.setRefreshLoading(true); }", completionHandler: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak wv] in
            let proc = Process()
            proc.environment = ProcessInfo.processInfo.environment
            if pythonURL.path == "/usr/bin/env" {
                proc.executableURL = pythonURL
                proc.arguments = ["python3", scriptURL.path, reportURL.path, healthArg]
            } else {
                proc.executableURL = pythonURL
                proc.arguments = [scriptURL.path, reportURL.path, healthArg]
            }

            proc.terminationHandler = { [weak self, weak wv] _ in
                DispatchQueue.main.async {
                    if let self = self, let wv = wv {
                        self.loadReportHTML(into: wv)
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                NSLog("BatFlow Error running report process: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if let self = self, let wv = wv {
                        self.loadReportHTML(into: wv)
                    }
                }
            }
        }
    }

    func updateInstantly(isAC: Bool, isCharging: Bool, pct: Int, isMagSafe: Bool) {
        guard isVisible, let wv = webView else { return }
        let js = "if (window.applyPowerState) { window.applyPowerState({ isExtConnected: \(isAC), isCharging: \(isCharging), isMagSafe: \(isMagSafe), percent: \(pct) }); }"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }
}
