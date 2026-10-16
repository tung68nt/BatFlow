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
    /// Transparent margin around the glass on macOS 26+, so the material's own soft shadow is not clipped.
    var panelMargin: CGFloat = 0
    var model = BatteryViewModel()
    var timer: Timer?
    var powerSourceLoopSource: CFRunLoopSource?
    var notifyPort: IONotificationPortRef?
    var batteryNotificationIterator: io_object_t = 0
    var eventMonitor: Any?
    var aboutWindow: NSWindow?
    var updateWindow: NSWindow?
    private var lastCloseTime = Date.distantPast
    var isMenuShowing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseDown])
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
            onOpenSettingsMenu: { [weak self] in
                self?.showSettingsMenu()
            },
            onCheckUpdate: { [weak self] in
                self?.closePanel()
                self?.openUpdateWindow()
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
            // The window draws no shadow of its own: a window shadow is rectangular and shows as square
            // corners around the rounded glass. The glass sits inset in a clear container instead.
            panelMargin = 24
            panel.hasShadow = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: exactSize.width + panelMargin * 2, height: exactSize.height + panelMargin * 2))
            let glass = NSGlassEffectView(frame: container.bounds.insetBy(dx: panelMargin, dy: panelMargin))
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = BatFiPopoverView.cornerRadius
            glass.contentView = hostingView
            container.addSubview(glass)
            panel.contentView = container
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

    func applicationWillTerminate(_ notification: Notification) {
        // Apps BatFlow slowed down must not stay slowed once it is gone
        ThermalGuard.shared.restoreAll()
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
            return
        }

        // Prevent accidental immediate re-opening if panel was closed by mouse down right before action
        if Date().timeIntervalSince(lastCloseTime) < 0.25 {
            return
        }

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
        let posY = menuBarBottom - exactSize.height - 6

        panel.setFrame(NSRect(x: posX - panelMargin, y: posY - panelMargin,
                              width: exactSize.width + panelMargin * 2, height: exactSize.height + panelMargin * 2), display: true)
        if panel.hasShadow { panel.invalidateShadow() }
        panel.makeKeyAndOrderFront(nil)

        EnergyMonitor.shared.start(client: "panel")
        PowerLog.shared.reload()
        rescheduleSampling()
        startClickOutsideMonitor()
    }

    func startClickOutsideMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self = self else { return }
                if self.isMenuShowing { return }
                // If user clicked inside the status bar button, let togglePanel() handle the closing cleanly
                if let button = self.statusItem?.button, let win = button.window {
                    let mouseLoc = NSEvent.mouseLocation
                    let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
                    if buttonRect.contains(mouseLoc) {
                        return
                    }
                }
                self.closePanel()
            }
        }
    }

    func closePanel() {
        guard panel.isVisible || eventMonitor != nil else { return }
        lastCloseTime = Date()
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

    func updateMenuBarButton() {
        guard let button = statusItem.button else { return }
        let smart = AppleSmartCharge.shared
        let isChg = model.isExtConnected && (model.isCharging || smart.isPushToFullActive)
        button.image = MenuBarIcon.image(
            pct: model.currentPct,
            isCharging: isChg,
            isExtConnected: model.isExtConnected,
            isLowPower: BatteryCare.shared.lowPowerMode,
            isDark: isMenuBarDark()
        )
        button.imagePosition = .imageOnly
        button.title = ""
        var tipParts = ["BatFlow", "\(model.currentPct)%", model.powerSourceStr]
        if model.isExtConnected && smart.isPushToFullActive {
            tipParts.append("Đang sạc đầy 100%")
        } else if smart.isMCLEnabled && smart.configuredLimit < 100 {
            tipParts.append("Giới hạn \(smart.configuredLimit)%")
        }
        button.toolTip = tipParts.joined(separator: " • ")
    }

    func openAboutWindow() {
        closePanel()
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 285),
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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

    // MARK: - Settings & Secondary Menu
    @objc func showSettingsMenu() {
        guard let hosting = hostingView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toolsItem = NSMenuItem(title: "Công cụ & kịch bản pin", action: #selector(menuOpenTools), keyEquivalent: "")
        toolsItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        toolsItem.target = self
        menu.addItem(toolsItem)

        let batterySettingsItem = NSMenuItem(title: "Cài đặt Pin macOS", action: #selector(menuOpenBatterySettings), keyEquivalent: "")
        batterySettingsItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        batterySettingsItem.target = self
        menu.addItem(batterySettingsItem)

        let hideIconItem = NSMenuItem(title: "Ẩn icon Pin gốc Apple", action: #selector(menuOpenControlCenterSettings), keyEquivalent: "")
        hideIconItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hideIconItem.target = self
        menu.addItem(hideIconItem)

        menu.addItem(NSMenuItem.separator())

        let updateTitle = UpdateManager.shared.isUpdateAvailable ? "Kiểm tra bản cập nhật (Có bản mới!)" : "Kiểm tra bản cập nhật"
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(menuCheckUpdate), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.target = self
        menu.addItem(updateItem)

        let aboutItem = NSMenuItem(title: "Giới thiệu BatFlow v\(UpdateManager.shared.currentVersion)", action: #selector(menuOpenAbout), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.delegate = self
        isMenuShowing = true

        let mouseLoc = NSEvent.mouseLocation
        let pointInWindow = panel.convertPoint(fromScreen: mouseLoc)
        let pointInView = hosting.convert(pointInWindow, from: nil)
        menu.popUp(positioning: nil, at: pointInView, in: hosting)
    }

    @objc func menuOpenTools() {
        closePanel()
        openDetailedDashboard(page: 1)
    }

    @objc func menuOpenBatterySettings() {
        closePanel()
        AppleSmartCharge.openBatterySettings()
    }

    @objc func menuOpenControlCenterSettings() {
        closePanel()
        AppleSmartCharge.openControlCenterSettings()
    }

    @objc func menuCheckUpdate() {
        closePanel()
        openUpdateWindow()
    }

    @objc func menuOpenAbout() {
        openAboutWindow()
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isMenuShowing = false
        }
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
