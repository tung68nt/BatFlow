import AppKit

// MARK: - Menu Bar Battery Icon
// Compact, system-style: the percentage is knocked out of the battery body itself, so no text sits beside it.
enum MenuBarIcon {
    static let size = NSSize(width: 31, height: 14)

    static func image(pct: Int, isCharging: Bool, isExtConnected: Bool, isLowPower: Bool = false, isDark: Bool) -> NSImage {
        let level = max(0, min(100, pct))
        let isHolding = isExtConnected && !isCharging

        return NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base: NSColor = isDark ? .white : NSColor(white: 0.10, alpha: 1.0)

            // Same colour code as the system indicator: yellow in Low Power Mode, green while charging, red when low
            let fill: NSColor
            if isLowPower {
                fill = isDark ? NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0) : NSColor(red: 0.86, green: 0.62, blue: 0.0, alpha: 1.0)
            } else if isCharging {
                fill = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
            } else if level <= 20 && !isExtConnected {
                fill = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
            } else {
                fill = base
            }

            let body = NSRect(x: 0.5, y: 0.5, width: 27, height: 13)
            let bodyPath = NSBezierPath(roundedRect: body, xRadius: 4.2, yRadius: 4.2)

            // Terminal
            base.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2.2, width: 1.8, height: 4.4), xRadius: 0.9, yRadius: 0.9).fill()

            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            base.withAlphaComponent(0.48).setFill()
            bodyPath.fill()

            ctx.saveGState()
            bodyPath.addClip()
            fill.setFill()
            NSRect(x: body.minX, y: body.minY, width: max(2.5, body.width * CGFloat(level) / 100.0), height: body.height).fill()
            ctx.restoreGState()

            // State glyph on the right: bolt while charging, pause while held on the adapter
            let symbolName: String? = isCharging ? "bolt.fill" : (isHolding ? "pause.fill" : nil)
            var glyph: NSImage?
            var glyphWidth: CGFloat = 0
            if let name = symbolName,
               let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: isCharging ? 7.5 : 6.5, weight: .bold)) {
                glyph = symbol
                glyphWidth = symbol.size.width
            }

            let text = "\(level)" as NSString
            let fontSize: CGFloat = (level == 100 && glyph != nil) ? 8.5 : 9.5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.black,
                .kern: -0.2
            ]
            let textSize = text.size(withAttributes: attributes)
            let gap: CGFloat = glyph == nil ? 0 : 0.8
            let contentWidth = textSize.width + gap + glyphWidth
            let startX = body.midX - contentWidth / 2

            // Knock the number and the glyph out of the body, like the system battery indicator
            ctx.setBlendMode(.destinationOut)
            text.draw(at: NSPoint(x: startX, y: body.midY - textSize.height / 2 + 0.2), withAttributes: attributes)
            if let glyph = glyph {
                let rect = NSRect(x: startX + textSize.width + gap, y: body.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1.0)
            }
            ctx.setBlendMode(.normal)

            ctx.endTransparencyLayer()
            return true
        }
    }
}
