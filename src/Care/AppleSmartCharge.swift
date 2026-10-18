import Foundation
import AppKit
import ObjectiveC
import UserNotifications

// MARK: - Apple Native Smart Charging & Manual Charge Limit (MCL) Bridge
// Directly interfaces with macOS PowerUI (via PowerUISmartChargeClient XPC) to:
// 1. Set charging limits (80%, 85%, 90%, 95%, 100%) exactly like System Settings > Battery
// 2. Temporarily push / charge to 100% now (bypassing 80% limit or Optimized Charging hold)
// 3. Restore configured limits at any time
// 4. Listen to system notifications ("com.apple.powerui.mclstatuschanged") for zero-latency sync
final class AppleSmartCharge: ObservableObject {
    static let shared = AppleSmartCharge()

    // MARK: - Published State
    @Published var isSupported: Bool = false
    @Published var isMCLSupported: Bool = false
    @Published var isMCLEnabled: Bool = false
    @Published var configuredLimit: Int = 80
    @Published var availableLimits: [Int] = [80, 85, 90, 95, 100]
    @Published var isOBCEngaged: Bool = false
    @Published var isOBCSupported: Bool = false
    @Published var isOBCEnabled: Bool = false
    @Published var isPushToFullActive: Bool = false
    @Published var isBusy: Bool = false
    @Published var lastActionStatus: String?

    // Function signatures for runtime invocations
    private typealias GetLimitFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias SetLimitFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> ObjCBool
    private typealias BoolErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> ObjCBool
    private typealias OverrideMCLFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> ObjCBool
    private typealias UIntErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt
    private typealias AvailFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?

    private var client: AnyObject?
    private let defaults = UserDefaults.standard
    private var lastRefresh = Date.distantPast
    private var darwinObserverAdded = false

    private init() {
        var isAC = false
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            isAC = (providing == kIOPMACPowerKey)
        }
        self.isPushToFullActive = isAC && defaults.bool(forKey: "care.pushToFullActive")
        initClient()
        setupDarwinObserver()
        refresh(force: true)
    }

    // MARK: - Effective Limit for UI & Hardware Math
    var effectiveLimit: Int {
        if isPushToFullActive { return 100 }
        if isMCLEnabled && configuredLimit > 0 && configuredLimit < 100 {
            return configuredLimit
        }
        return 100
    }

    var isHoldingAtLimit: Bool {
        return isMCLEnabled && !isPushToFullActive && configuredLimit < 100
    }

    // MARK: - Client Setup & Lifecycle
    private func initClient() {
        Bundle(path: "/System/Library/PrivateFrameworks/PowerUI.framework")?.load()
        guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            isSupported = false
            return
        }

        let instance = cls.init()
        let selInit = Selector(("initWithClientName:"))
        if instance.responds(to: selInit) {
            self.client = instance.perform(selInit, with: "BatFlow").takeUnretainedValue()
            self.isSupported = true
        } else {
            self.client = instance
            self.isSupported = true
        }

        // Query static capabilities
        if let client = self.client {
            if client.responds(to: Selector(("isMCLSupported"))) {
                self.isMCLSupported = (client.value(forKey: "isMCLSupported") as? Bool) ?? false
            }
            if client.responds(to: Selector(("isOBCSupported"))) {
                self.isOBCSupported = (client.value(forKey: "isOBCSupported") as? Bool) ?? false
            }
        }
    }

    // MARK: - Darwin Notification Observer
    private func setupDarwinObserver() {
        guard !darwinObserverAdded else { return }
        darwinObserverAdded = true
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            darwinCenter,
            selfPtr,
            { (_, observer, name, _, _) in
                guard let observer = observer else { return }
                let manager = Unmanaged<AppleSmartCharge>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.refresh(force: true)
                }
            },
            "com.apple.powerui.mclstatuschanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - State Refresh
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 2.0 else { return }
        lastRefresh = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var curLimit = self.configuredLimit
            var mclEnabled = false
            var availList = self.availableLimits
            var obcEngaged = false
            var obcEnabled = false

            if let client = self.client {
                // 1. Current configured limit
                let selGet = Selector(("getMCLLimitWithError:"))
                if client.responds(to: selGet) {
                    let fn = unsafeBitCast(client.method(for: selGet), to: GetLimitFn.self)
                    var err: NSError?
                    let raw = fn(client, selGet, &err)
                    if err == nil, raw >= 50, raw <= 100 {
                        curLimit = Int(raw)
                    }
                }

                // 2. Is MCL Enabled
                let selEnabled = Selector(("isMCLCurrentlyEnabled:"))
                if client.responds(to: selEnabled) {
                    let fn = unsafeBitCast(client.method(for: selEnabled), to: UIntErrFn.self)
                    var err: NSError?
                    let raw = fn(client, selEnabled, &err)
                    if err == nil {
                        mclEnabled = (raw != 0)
                    }
                }

                // 3. Available limits
                let selAvail = Selector(("availableChargeLimitsWithError:"))
                if client.responds(to: selAvail) {
                    let fn = unsafeBitCast(client.method(for: selAvail), to: AvailFn.self)
                    var err: NSError?
                    if let rawArr = fn(client, selAvail, &err) as? [NSNumber] {
                        let parsed = rawArr.map { $0.intValue }.filter { $0 >= 50 && $0 <= 100 }.sorted()
                        if !parsed.isEmpty {
                            availList = parsed
                        }
                    }
                }

                // 4. Optimized battery charging engagement
                let selOBC = Selector(("isOBCEngaged:"))
                if client.responds(to: selOBC) {
                    let fn = unsafeBitCast(client.method(for: selOBC), to: BoolErrFn.self)
                    var err: NSError?
                    let raw = fn(client, selOBC, &err)
                    if err == nil {
                        obcEngaged = raw.boolValue
                    }
                }

                let selOBCEnabled = Selector(("isSmartChargingCurrentlyEnabled:"))
                if client.responds(to: selOBCEnabled) {
                    let fn = unsafeBitCast(client.method(for: selOBCEnabled), to: UIntErrFn.self)
                    var err: NSError?
                    let raw = fn(client, selOBCEnabled, &err)
                    if err == nil {
                        obcEnabled = (raw != 0)
                    }
                }
            }

            // 5. Cross-check with AC power and pmset -g battlimit
            var isOnAC = false
            if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
                isOnAC = (providing == kIOPMACPowerKey)
            }

            var pushActive = self.isPushToFullActive
            if !isOnAC {
                // When running on battery, push override to 100% is cancelled
                pushActive = false
            } else {
                let pmsetOutput = EnergyMonitor.run("/usr/bin/pmset", ["-g", "battlimit"], timeout: 2.0)
                let hasLimitsSet = pmsetOutput.contains("chargeSocLimitSoc")
                if hasLimitsSet && !pmsetOutput.contains("No battery level limits set") {
                    // Limit is actively enforced right now by macOS firmware
                    pushActive = false
                }
            }

            DispatchQueue.main.async {
                self.configuredLimit = curLimit
                self.isMCLEnabled = mclEnabled
                self.availableLimits = availList
                self.isOBCEngaged = obcEngaged
                self.isOBCEnabled = obcEnabled
                if self.isPushToFullActive != pushActive {
                    self.isPushToFullActive = pushActive
                    self.defaults.set(pushActive, forKey: "care.pushToFullActive")
                }
            }
        }
    }

    // MARK: - Actions

    /// Temporarily bypass the charge limit and force charge to 100% now (identical to Apple menu "Charge to Full Now")
    func pushChargeToFull() {
        guard let client = client, !isBusy else { return }
        isBusy = true
        lastActionStatus = "Đang kích hoạt sạc đầy 100%..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = false

            // 1. Try temporarily override MCL target SoC to 100
            let selOverride = Selector(("temporarilyOverrideMCLTargetSoC:error:"))
            if client.responds(to: selOverride) {
                let fn = unsafeBitCast(client.method(for: selOverride), to: OverrideMCLFn.self)
                var err: NSError?
                let res = fn(client, selOverride, 100, &err)
                if res.boolValue { success = true }
            }

            // 2. Try temporarily disable MCL
            let selDis = Selector(("temporarilyDisableMCL:"))
            if client.responds(to: selDis) {
                let fn = unsafeBitCast(client.method(for: selDis), to: BoolErrFn.self)
                var err: NSError?
                let res = fn(client, selDis, &err)
                if res.boolValue { success = true }
            }

            // 3. Try temporarily enable charging (in case OBC hold is engaged)
            let selChg = Selector(("temporarilyEnableCharging:"))
            if client.responds(to: selChg) {
                let fn = unsafeBitCast(client.method(for: selChg), to: BoolErrFn.self)
                var err: NSError?
                let res = fn(client, selChg, &err)
                if res.boolValue { success = true }
            }

            DispatchQueue.main.async {
                self.isBusy = false
                self.isPushToFullActive = true
                self.defaults.set(true, forKey: "care.pushToFullActive")
                self.lastActionStatus = success ? "Đã bật sạc đầy 100%" : "Đã gửi lệnh sạc đầy"
                self.notify(
                    id: "apple-charge-push",
                    title: "⚡ Đang sạc đầy 100% (Tạm thời)",
                    body: "BatFlow đã bỏ qua giới hạn sạc để sạc đầy 100% cho lần cắm sạc này."
                )
                self.refresh(force: true)
            }
        }
    }

    /// Restore the previously configured charge limit (e.g. 80%)
    func restoreLimit() {
        guard let client = client, !isBusy else { return }
        isBusy = true
        lastActionStatus = "Đang khôi phục giới hạn sạc..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var success = false

            // 1. Enable MCL
            let selEn = Selector(("enableMCL:"))
            if client.responds(to: selEn) {
                let fn = unsafeBitCast(client.method(for: selEn), to: BoolErrFn.self)
                var err: NSError?
                let res = fn(client, selEn, &err)
                if res.boolValue { success = true }
            }

            // 2. Reset engagement override
            let selReset = Selector(("resetEngagementOverride"))
            if client.responds(to: selReset) {
                _ = client.perform(selReset)
                success = true
            }

            // 3. If configured limit was set, re-apply it explicitly
            let selSet = Selector(("setMCLLimit:error:"))
            if client.responds(to: selSet) && self.configuredLimit > 0 && self.configuredLimit < 100 {
                let fn = unsafeBitCast(client.method(for: selSet), to: SetLimitFn.self)
                var err: NSError?
                _ = fn(client, selSet, UInt8(self.configuredLimit), &err)
            }

            DispatchQueue.main.async {
                self.isBusy = false
                self.isPushToFullActive = false
                self.defaults.set(false, forKey: "care.pushToFullActive")
                self.lastActionStatus = success ? "Đã khôi phục giới hạn" : nil
                self.notify(
                    id: "apple-charge-restore",
                    title: "Đã khôi phục giới hạn sạc \(self.configuredLimit)%",
                    body: "Hệ thống sẽ giữ pin ở ngưỡng \(self.configuredLimit)% để bảo vệ tuổi thọ pin."
                )
                self.refresh(force: true)
            }
        }
    }

    /// Set a new charging limit (80%, 85%, 90%, 95%, 100%)
    func setLimit(_ newLimit: Int) {
        guard let client = client, !isBusy else { return }
        guard newLimit >= 50 && newLimit <= 100 else { return }
        isBusy = true
        lastActionStatus = "Đang đặt giới hạn sạc \(newLimit)%..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // enableMCL: resets the stored limit to the default 80%, so it has to run before setMCLLimit:, never after
            if newLimit < 100 {
                let selEn = Selector(("enableMCL:"))
                if client.responds(to: selEn) {
                    let fn = unsafeBitCast(client.method(for: selEn), to: BoolErrFn.self)
                    var err: NSError?
                    _ = fn(client, selEn, &err)
                }
            } else {
                let selDis = Selector(("disableMCL:"))
                if client.responds(to: selDis) {
                    let fn = unsafeBitCast(client.method(for: selDis), to: BoolErrFn.self)
                    var err: NSError?
                    _ = fn(client, selDis, &err)
                }
            }

            let selSet = Selector(("setMCLLimit:error:"))
            if client.responds(to: selSet) {
                let fn = unsafeBitCast(client.method(for: selSet), to: SetLimitFn.self)
                var err: NSError?
                _ = fn(client, selSet, UInt8(newLimit), &err)
            }

            // Also reset engagement override so the new limit takes effect immediately
            let selReset = Selector(("resetEngagementOverride"))
            if client.responds(to: selReset) {
                _ = client.perform(selReset)
            }

            // Trust only what powerd reports back, not the call's return value
            var applied = newLimit
            let selGet = Selector(("getMCLLimitWithError:"))
            if client.responds(to: selGet) {
                let fn = unsafeBitCast(client.method(for: selGet), to: GetLimitFn.self)
                var err: NSError?
                let raw = fn(client, selGet, &err)
                if err == nil, raw >= 50, raw <= 100 { applied = Int(raw) }
            }
            let success = applied == newLimit

            DispatchQueue.main.async {
                self.isBusy = false
                self.isPushToFullActive = false
                self.defaults.set(false, forKey: "care.pushToFullActive")
                self.configuredLimit = applied
                self.isMCLEnabled = newLimit < 100
                self.lastActionStatus = success ? "Đã đặt giới hạn \(newLimit)%" : "Không đặt được giới hạn \(newLimit)%"
                if success {
                    self.notify(
                        id: "apple-charge-setlimit",
                        title: newLimit < 100 ? "Đã đặt giới hạn sạc \(newLimit)%" : "Đã tắt giới hạn sạc (Sạc 100%)",
                        body: newLimit < 100
                            ? "macOS sẽ giữ pin ở ngưỡng \(newLimit)%. Cài đặt đã được đồng bộ với hệ thống."
                            : "Pin sẽ được sạc đầy 100% khi cắm sạc."
                    )
                } else {
                    self.notify(
                        id: "apple-charge-setlimit",
                        title: "Không đặt được giới hạn sạc \(newLimit)%",
                        body: "macOS vẫn đang giữ giới hạn \(applied)%. Hãy thử lại hoặc đặt trong Cài đặt › Pin."
                    )
                }
                self.refresh(force: true)
            }
        }
    }

    // MARK: - Periodic Tick Hook
    func tick(_ model: BatteryViewModel) {
        // Reset push status if user unplugs charger
        if !model.isExtConnected && isPushToFullActive {
            isPushToFullActive = false
            defaults.set(false, forKey: "care.pushToFullActive")
        }
        refresh()
    }

    // MARK: - Open System Settings Shortcuts
    static func openBatterySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openControlCenterSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        openBatterySettings()
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
