import AppKit
import SwiftUI
import IOKit
import IOKit.ps
import UserNotifications

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    var hostingView: NSHostingView<BatFiPopoverView>!
    var model = BatteryViewModel()
    var timer: Timer?
    var powerSourceLoopSource: CFRunLoopSource?
    var notifyPort: IONotificationPortRef?
    var batteryNotificationIterator: io_object_t = 0
    var eventMonitor: Any?
    var aboutWindow: NSWindow?
    var updateWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }

        let contentView = BatFiPopoverView(
            model: model,
            onOpenDashboard: { [weak self] in
                self?.closePanel()
                self?.openDetailedDashboard()
            },
            onOpenTools: { [weak self] in
                self?.closePanel()
                self?.openDetailedDashboard(page: 1)
            },
            onCheckUpdate: { [weak self] in
                self?.closePanel()
                self?.openUpdateWindow()
            },
            onOpenAbout: { [weak self] in
                self?.closePanel()
                self?.openAboutWindow()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        hostingView = NSHostingView(rootView: contentView)
        hostingView.layoutSubtreeIfNeeded()
        let exactSize = hostingView.fittingSize

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: exactSize.width, height: exactSize.height))
        if #available(macOS 26.0, *) {
            // Real Liquid Glass: the system material samples and refracts whatever sits behind the panel
            let glass = NSGlassEffectView()
            glass.cornerRadius = BatFiPopoverView.cornerRadius
            glass.contentView = hostingView
            panel.contentView = glass
        } else {
            hostingView.wantsLayer = true
            hostingView.layer?.cornerRadius = BatFiPopoverView.cornerRadius
            hostingView.layer?.masksToBounds = true
            panel.contentView = hostingView
        }

        // 1. Initial data, then adaptive sampling (fast while a BatFlow surface is visible, slow otherwise)
        model.onSample = { [weak self] in
            guard let self = self else { return }
            self.updateMenuBarButton()
            BatteryCare.shared.tick(self.model)
        }
        model.updateData()
        updateMenuBarButton()
        rescheduleSampling()

        // 2. Layer 1: CoreOS PowerSource hardware interrupt (Microsecond execution)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let loopSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            app.handleHardwarePowerChanged()
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, .commonModes)
        powerSourceLoopSource = loopSource

        // 3. Layer 2: Direct Kernel IOKit AppleSmartBattery Driver interrupt
        setupKernelBatteryInterest()

        // 4. Background continuous auto-scan for updates with native notifications
        UpdateManager.shared.startAutoScan()

        // 5. Connect Dashboard update button request
        DashboardWindowController.shared.onCheckUpdateRequested = { [weak self] in
            self?.openUpdateWindow()
        }
        DashboardWindowController.shared.onVisibilityChanged = { [weak self] in
            self?.rescheduleSampling()
        }

        // 6. Drop the HTML report cached by versions before 1.1 (it was rendered by the removed Python engine)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("BatFlow/battery_report.html"))
        }

        // 7. Support direct dashboard open flag for CLI and testing
        if CommandLine.arguments.contains("--dashboard") || CommandLine.arguments.contains("--tools") {
            let page = CommandLine.arguments.contains("--tools") ? 1 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openDetailedDashboard(page: page)
            }
        }
        if CommandLine.arguments.contains("--panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePanel()
            }
        }
    }

    /// 1s sampling while the popover or dashboard is on screen, 5s in the background to spare the battery.
    func rescheduleSampling() {
        let visible = (panel?.isVisible ?? false) || DashboardWindowController.shared.isVisible
        let interval: TimeInterval = visible ? 1.0 : 5.0
        if let current = timer, current.isValid, abs(current.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.model.updateData()
        }
        timer?.tolerance = visible ? 0.1 : 1.0
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return true
    }

    func setupKernelBatteryInterest() {
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        notifyPort = IONotificationPortCreate(mainPort)
        if let port = notifyPort {
            let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            IOServiceAddInterestNotification(
                port,
                service,
                kIOGeneralInterest,
                { (refcon, service, messageType, messageArgument) in
                    guard let refcon = refcon else { return }
                    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    app.handleHardwarePowerChanged()
                },
                selfPtr,
                &batteryNotificationIterator
            )
        }
        IOObjectRelease(service)
    }

    func handleHardwarePowerChanged() {
        // Zero latency execution directly on the main runloop
        DeviceInfo.shared.invalidatePortCache()
        model.updateData()

        // The USB-PD handshake settles a moment after the plug event; sample again once it has
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            DeviceInfo.shared.invalidatePortCache()
            self?.model.updateData()
        }
    }

    @objc func togglePanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        
        if panel.isVisible {
            closePanel()
        } else {
            model.updateData()
            model.recomputeHistoryPoints()
            
            // Force synchronous layout pass so fittingSize is 100% accurate before positioning
            hostingView.layoutSubtreeIfNeeded()
            let exactSize = hostingView.fittingSize
            let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = win.screen ?? NSScreen.main
            let screenFrame = screen?.visibleFrame ?? screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            // 1. Horizontal: Center card directly under menu bar status item button
            var posX = buttonRect.midX - (exactSize.width / 2)
            posX = max(10, min(screenFrame.maxX - exactSize.width - 10, posX))
            
            // 2. Vertical: Snug fit directly below the menu bar bottom (native macOS popover style)
            let menuBarBottom = (screenFrame.maxY > 100) ? screenFrame.maxY : buttonRect.minY
            let posY = menuBarBottom - exactSize.height - 2.5
            
            panel.setFrame(NSRect(x: posX, y: posY, width: exactSize.width, height: exactSize.height), display: true)
            panel.invalidateShadow()
            panel.makeKeyAndOrderFront(nil)

            EnergyMonitor.shared.start(client: "panel")
            rescheduleSampling()
            startClickOutsideMonitor()
        }
    }

    func startClickOutsideMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    func closePanel() {
        guard panel.isVisible || eventMonitor != nil else { return }
        panel.orderOut(nil)
        EnergyMonitor.shared.stop(client: "panel")
        rescheduleSampling()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func isMenuBarDark() -> Bool {
        guard let button = statusItem?.button else { return true }
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua
    }

    func drawMenuBarIcon(pct: Int, isCharging: Bool, isExtConnected: Bool, isDark: Bool) -> NSImage {
        let size = NSSize(width: 27, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()

        // Adaptive stroke: Crisp White on Dark, Dark Charcoal on Light
        let strokeColor: NSColor = isDark ? NSColor.white : NSColor(white: 0.12, alpha: 0.95)
        let isHolding = isExtConnected && !isCharging

        let fillColor: NSColor
        if isHolding {
            fillColor = NSColor(red: 0.15, green: 0.70, blue: 0.88, alpha: 1.0) // Apple cyan/blue for hold
        } else if pct <= 20 {
            fillColor = NSColor.systemRed
        } else if pct <= 45 {
            fillColor = NSColor.systemOrange
        } else {
            fillColor = NSColor(red: 0.15, green: 0.85, blue: 0.45, alpha: 1.0)
        }

        // Outer capsule
        let bodyRect = NSRect(x: 1, y: 1, width: 22, height: 11)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
        bodyPath.lineWidth = 1.2
        strokeColor.setStroke()
        bodyPath.stroke()

        // Nipple
        let nippleRect = NSRect(x: 23.5, y: 4, width: 2, height: 5)
        let nipplePath = NSBezierPath(roundedRect: nippleRect, xRadius: 1, yRadius: 1)
        strokeColor.setFill()
        nipplePath.fill()

        // Inner fluid fill
        let maxInnerWidth = 18.0
        let fillWidth = max(2.0, (Double(max(0, min(100, pct))) / 100.0) * maxInnerWidth)
        let fillRect = NSRect(x: 3, y: 3, width: fillWidth, height: 7)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5)
        fillColor.setFill()
        fillPath.fill()

        let symbolConfig: NSImage.SymbolConfiguration?
        if #available(macOS 12.0, *) {
            symbolConfig = NSImage.SymbolConfiguration(paletteColors: [strokeColor])
        } else {
            symbolConfig = nil
        }

        // Distinct iconography: Bolt when actively charging, Pause when on Hold / Power Bypass
        if isCharging {
            var bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
            if let config = symbolConfig {
                bolt = bolt?.withSymbolConfiguration(config)
            }
            if let bolt = bolt {
                let rect = NSRect(x: 8.5, y: 2.2, width: 7.5, height: 8.5)
                bolt.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else if isHolding {
            var pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            if let config = symbolConfig {
                pause = pause?.withSymbolConfiguration(config)
            }
            if let pause = pause {
                let rect = NSRect(x: 8.5, y: 2.8, width: 6.5, height: 7.5)
                pause.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }

        image.unlockFocus()
        return image
    }

    func updateMenuBarButton() {
        guard let button = statusItem.button else { return }
        let isDark = isMenuBarDark()
        button.image = drawMenuBarIcon(
            pct: model.currentPct,
            isCharging: model.isCharging,
            isExtConnected: model.isExtConnected,
            isDark: isDark
        )
        button.imagePosition = .imageLeft
        let textColor: NSColor = isDark ? NSColor.white : NSColor(white: 0.12, alpha: 0.95)
        let attrTitle = NSAttributedString(
            string: " \(model.currentPct)%",
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            ]
        )
        button.attributedTitle = attrTitle
    }

    func openAboutWindow() {
        closePanel()
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Giới thiệu BatFlow"
        win.center()
        win.isReleasedWhenClosed = false
        let aboutView = AboutView(onCheckUpdate: { [weak self] in
            self?.openUpdateWindow()
        })
        win.contentView = NSHostingView(rootView: aboutView)
        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openUpdateWindow() {
        closePanel()
        if let win = updateWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            UpdateManager.shared.checkForUpdates(userInitiated: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Cập nhật phần mềm"
        win.center()
        win.isReleasedWhenClosed = false
        let updateView = UpdateView(onClose: { [weak self] in
            self?.updateWindow?.close()
        })
        win.contentView = NSHostingView(rootView: updateView)
        updateWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    func openDetailedDashboard(page: Int = 0) {
        closePanel()
        DashboardWindowController.shared.open(with: model, page: page)
    }
}

// MARK: - UNUserNotificationCenterDelegate (Notification Actions)
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            if identifier.hasPrefix("care-") {
                self?.openDetailedDashboard(page: 1)
            } else {
                self?.openUpdateWindow()
            }
        }
        completionHandler()
    }
}
