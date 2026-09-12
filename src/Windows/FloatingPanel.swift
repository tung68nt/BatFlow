import AppKit

// MARK: - Dedicated Floating Panel (BatFi Style)
class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovable = false
        self.becomesKeyOnlyIfNeeded = false
    }

    override var hasShadow: Bool {
        get { return true }
        set { super.hasShadow = newValue }
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}
