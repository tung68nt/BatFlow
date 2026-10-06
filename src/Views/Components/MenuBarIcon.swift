import AppKit

// MARK: - Menu Bar Battery Icon
// Compact, system-style: the percentage is knocked out of the battery body itself, so no text sits beside it.
enum MenuBarIcon {
    static let size = NSSize(width: 30, height: 13)
    private static let bodyRect = NSRect(x: 0.5, y: 0.5, width: 26, height: 12)
    private static let boltWidth: CGFloat = 4.6
    private static let pauseWidth: CGFloat = 3.6
    private static let boltGap: CGFloat = 0.5
    private static let pauseGap: CGFloat = 1.8
    private static let kern: CGFloat = 0.1

    /// The digits as vector outlines. Filling outlines (instead of drawing text) keeps their position exact:
    /// text drawing snaps glyphs to whole pixels, which nudged the number off-centre at screen resolution.
    private static func outline(_ text: String, size: CGFloat) -> CGPath {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .kern: kern]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let font = runAttributes[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                path.addPath(glyphPath, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        return path
    }

    /// One size for every level: the largest at which the widest case ("100" next to the bolt) still fits.
    private static let fontSize: CGFloat = {
        var size: CGFloat = 11
        while size > 7 && outline("100", size: size).boundingBoxOfPath.width + max(boltGap + boltWidth, pauseGap + pauseWidth) > bodyRect.width - 4.0 {
            size -= 0.25
        }
        return size
    }()

    static func image(pct: Int, isCharging: Bool, isExtConnected: Bool, isLowPower: Bool = false, isDark: Bool, monochrome: Bool = false) -> NSImage {
        let level = max(0, min(100, pct))
        let isHolding = isExtConnected && !isCharging

        return NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base: NSColor = isDark ? .white : NSColor(white: 0.10, alpha: 1.0)

            // Same colour code as the system indicator: yellow in Low Power Mode, green while charging, red when low
            let fill: NSColor
            if isLowPower {
                fill = isDark ? NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0) : NSColor(red: 0.86, green: 0.62, blue: 0.0, alpha: 1.0)
            } else if isCharging && !monochrome {
                fill = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
            } else if level <= 20 && !isExtConnected {
                fill = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
            } else {
                fill = base
            }

            // Proportions follow the system indicator, widened slightly so "100" fits at the same size as every other level
            let body = bodyRect
            let bodyPath = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)

            let cap = NSBezierPath()
            let capX = body.maxX + 1.1
            cap.move(to: NSPoint(x: capX, y: body.midY - 2.3))
            cap.curve(to: NSPoint(x: capX, y: body.midY + 2.3),
                      controlPoint1: NSPoint(x: capX + 2.3, y: body.midY - 2.0), controlPoint2: NSPoint(x: capX + 2.3, y: body.midY + 2.0))
            cap.close()
            base.withAlphaComponent(0.48).setFill()
            cap.fill()

            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            base.withAlphaComponent(0.48).setFill()
            bodyPath.fill()

            ctx.saveGState()
            bodyPath.addClip()
            fill.setFill()
            NSRect(x: body.minX, y: body.minY, width: max(2.5, body.width * CGFloat(level) / 100.0), height: body.height).fill()
            ctx.restoreGState()

            // State glyph right after the number: a slim bolt while charging, pause bars while held on the adapter.
            // Drawn as paths: SF Symbols carry side bearings that leave a gap next to the digits at this size.
            let glyphPath = NSBezierPath()
            var glyphWidth: CGFloat = 0
            if isCharging {
                let pts: [(CGFloat, CGFloat)] = [(3.0, 9.4), (0, 4.0), (1.9, 4.0), (1.5, 0), (4.6, 5.5), (2.6, 5.5)]
                glyphPath.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
                for p in pts.dropFirst() { glyphPath.line(to: NSPoint(x: p.0, y: p.1)) }
                glyphPath.close()
                glyphWidth = boltWidth
            } else if isHolding {
                glyphPath.appendRoundedRect(NSRect(x: 0, y: 1.6, width: 1.3, height: 6.2), xRadius: 0.45, yRadius: 0.45)
                glyphPath.appendRoundedRect(NSRect(x: 2.3, y: 1.6, width: 1.3, height: 6.2), xRadius: 0.45, yRadius: 0.45)
                glyphWidth = pauseWidth
            }
            let hasGlyph = glyphWidth > 0

            // Regular-width SF at semibold weight, set tight, same size at every level
            let gap: CGFloat = isHolding ? pauseGap : (hasGlyph ? boltGap : 0)
            let digits = outline("\(level)", size: fontSize)
            let ink = digits.boundingBoxOfPath
            let contentWidth = ink.width + gap + glyphWidth
            let startX = body.midX - contentWidth / 2

            // Knock the number and the glyph out of the body, like the system battery indicator
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(NSColor.black.cgColor)
            var place = CGAffineTransform(translationX: startX - ink.minX, y: body.midY - ink.midY)
            if let placed = digits.copy(using: &place) {
                ctx.addPath(placed)
                ctx.fillPath()
            }
            if hasGlyph {
                let moved = glyphPath.copy() as! NSBezierPath
                moved.transform(using: AffineTransform(translationByX: startX + ink.width + gap, byY: body.midY - 4.7))
                NSColor.black.setFill()
                moved.fill()
            }
            ctx.setBlendMode(.normal)

            ctx.endTransparencyLayer()
            return true
        }
    }
}
