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


    /// AppKit otherwise pushes the window down so that it clears the menu bar. The panel has a transparent
    /// margin around its glass, so it has to overlap the menu bar for the glass itself to sit right under it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}
