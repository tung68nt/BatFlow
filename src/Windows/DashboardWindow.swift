import AppKit
import SwiftUI

// MARK: - Dashboard Router (which page the dashboard shows; driven by the toolbar)
final class DashboardRouter: ObservableObject {
    static let shared = DashboardRouter()
    @Published var page = 0
}

private extension NSToolbarItem.Identifier {
    static let pages = NSToolbarItem.Identifier("batflow.pages")
    static let update = NSToolbarItem.Identifier("batflow.update")
}

// MARK: - Dashboard Window Controller
// A standard opaque window. Its toolbar is the only Liquid Glass layer, and the system draws it (macOS 26+).
class DashboardWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = DashboardWindowController()

    var window: NSWindow?
    private var refreshTimer: Timer?
    private weak var pagesItem: NSToolbarItemGroup?
    var onCheckUpdateRequested: (() -> Void)? = nil
    var onVisibilityChanged: (() -> Void)? = nil

    var isVisible: Bool {
        return window?.isVisible ?? false
    }

    func open(with model: BatteryViewModel, page: Int = 0) {
        DashboardRouter.shared.page = page

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "BatFlow"
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 720, height: 500)
            win.delegate = self

            let toolbar = NSToolbar(identifier: "batflow.dashboard")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            win.toolbar = toolbar
            win.toolbarStyle = .unified

            win.contentView = NSHostingView(rootView: DashboardView(model: model))
            win.center()
            window = win
        }
        pagesItem?.selectedIndex = page

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        EnergyMonitor.shared.start(client: "dashboard")
        PowerLog.shared.reload()
        BatteryCare.shared.refreshNativeLimit(force: true)

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            PowerLog.shared.reload()
        }
        onVisibilityChanged?()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        EnergyMonitor.shared.stop(client: "dashboard")
        DispatchQueue.main.async { [weak self] in
            self?.onVisibilityChanged?()
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .pages, .flexibleSpace, .update]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .pages:
            let group = NSToolbarItemGroup(itemIdentifier: .pages, titles: ["Tổng quan", "Công cụ pin"], selectionMode: .selectOne,
                                           labels: nil, target: self, action: #selector(pageChanged(_:)))
            group.selectedIndex = DashboardRouter.shared.page
            group.label = "Trang"
            pagesItem = group
            return group
        case .update:
            let item = NSToolbarItem(itemIdentifier: .update)
            item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Kiểm tra bản cập nhật")
            item.label = "Cập nhật"
            item.toolTip = "Kiểm tra bản cập nhật BatFlow"
            item.isBordered = true
            item.target = self
            item.action = #selector(checkUpdate)
            return item
        default:
            return nil
        }
    }

    @objc private func pageChanged(_ sender: NSToolbarItemGroup) {
        DashboardRouter.shared.page = sender.selectedIndex
    }

    @objc private func checkUpdate() {
        onCheckUpdateRequested?()
    }
}
