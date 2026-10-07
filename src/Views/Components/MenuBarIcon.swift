import AppKit

// MARK: - Menu Bar Battery Icon (Apple Native Replica)
// Pixel-perfect replica of the macOS system battery indicator with percentage knocked out.
enum MenuBarIcon {
    /// Exact Apple native menu bar battery dimensions (22.0pt body + 1.3pt gap + 1.5pt cap)
    static let size = NSSize(width: 25.8, height: 12.0)
    private static let bodyRect = NSRect(x: 0.5, y: 0.0, width: 22.0, height: 12.0)
    private static let capRect = NSRect(x: 23.8, y: 4.0, width: 1.5, height: 4.0)
    private static let bodyCornerRadius: CGFloat = 4.5
    private static let emptyAlpha: CGFloat = 0.40
    private static let kern: CGFloat = -0.2

    enum HoldSymbolStyle: String, CaseIterable {
        case pause = "pause"   // Elegant Apple-style dual pill bars
        case plug = "plug"     // Apple powerplug.fill adapter icon
        case bolt = "bolt"     // Keep lightning bolt like macOS native
    }

    // MARK: - Vector Bolt Path (Exact Apple bolt.fill mathematical bezier outline, calibrated to 1:1)
    private static let boltPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.0, y: 3.676))
        path.addCurve(to: CGPoint(x: 0.272, y: 3.418), control1: CGPoint(x: 0.0, y: 3.527), control2: CGPoint(x: 0.113, y: 3.418))
        path.addLine(to: CGPoint(x: 2.290, y: 3.418))
        path.addLine(to: CGPoint(x: 1.232, y: 0.594))
        path.addCurve(to: CGPoint(x: 1.746, y: 0.314), control1: CGPoint(x: 1.084, y: 0.206), control2: CGPoint(x: 1.487, y: 0.0))
        path.addLine(to: CGPoint(x: 4.999, y: 4.315))
        path.addCurve(to: CGPoint(x: 5.098, y: 4.555), control1: CGPoint(x: 5.065, y: 4.396), control2: CGPoint(x: 5.098, y: 4.470))
        path.addCurve(to: CGPoint(x: 4.826, y: 4.813), control1: CGPoint(x: 5.098, y: 4.703), control2: CGPoint(x: 4.982, y: 4.813))
        path.addLine(to: CGPoint(x: 2.807, y: 4.813))
        path.addLine(to: CGPoint(x: 3.863, y: 7.637))
        path.addCurve(to: CGPoint(x: 3.352, y: 7.917), control1: CGPoint(x: 4.011, y: 8.024), control2: CGPoint(x: 3.610, y: 8.231))
        path.addLine(to: CGPoint(x: 0.096, y: 3.915))
        path.addCurve(to: CGPoint(x: 0.0, y: 3.676), control1: CGPoint(x: 0.031, y: 3.835), control2: CGPoint(x: 0.0, y: 3.761))
        path.closeSubpath()
        var t = CGAffineTransform(scaleX: 0.94, y: 0.94)
        return path.copy(using: &t)!
    }()

    // MARK: - Sleek Pause Vector Path (2 elegant rounded pills, perfectly proportioned to digits)
    private static let pausePath: CGPath = {
        let path = CGMutablePath()
        let bar1 = CGRect(x: 0.0, y: 0.0, width: 1.1, height: 6.2)
        let bar2 = CGRect(x: 2.2, y: 0.0, width: 1.1, height: 6.2)
        path.addPath(CGPath(roundedRect: bar1, cornerWidth: 0.55, cornerHeight: 0.55, transform: nil))
        path.addPath(CGPath(roundedRect: bar2, cornerWidth: 0.55, cornerHeight: 0.55, transform: nil))
        return path
    }()

    // MARK: - Power Plug Vector Path (Apple powerplug adapter icon for bypass hold)
    private static let plugPath: CGPath = {
        let conf = NSImage.SymbolConfiguration(pointSize: 6.5, weight: .semibold)
        if let img = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(conf),
           let rep = img.representations.first {
            let sel = NSSelectorFromString("outlinePath")
            if rep.responds(to: sel), let bp = rep.perform(sel).takeUnretainedValue() as? NSBezierPath {
                var path = CGMutablePath()
                var points = [CGPoint](repeating: .zero, count: 3)
                for i in 0..<bp.elementCount {
                    let type = bp.element(at: i, associatedPoints: &points)
                    switch type {
                    case .moveTo: path.move(to: points[0])
                    case .lineTo: path.addLine(to: points[0])
                    case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
                    case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
                    case .closePath: path.closeSubpath()
                    @unknown default: break
                    }
                }
                let bounds = path.boundingBox
                var t = CGAffineTransform(scaleX: 0.45, y: -0.45).translatedBy(x: 0, y: -bounds.height)
                if let flipped = path.copy(using: &t) {
                    return flipped
                }
            }
        }
        return pausePath
    }()

    // MARK: - Native D-Shaped Terminal Cap (Flat against gap, smooth convex dome outward)
    private static func makeCapPath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let r: CGFloat = 0.75
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.midY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// Digits converted to vector outline for subpixel sharpness and jitter-free rendering
    private static func outline(_ text: String, size: CGFloat, kernValue: CGFloat = kern) -> CGPath {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kernValue]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttributes[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                path.addPath(glyphPath, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        return path
    }

    static func image(
        pct: Int,
        isCharging: Bool,
        isExtConnected: Bool,
        isLowPower: Bool = false,
        isDark: Bool,
        monochrome: Bool = true,
        holdStyle: HoldSymbolStyle = .pause
    ) -> NSImage {
        let level = max(0, min(100, pct))
        let isHolding = isExtConnected && !isCharging
        let isColored = isLowPower || (level <= 20 && !isExtConnected) || (isCharging && !monochrome)

        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base: NSColor = isColored ? (isDark ? .white : NSColor(white: 0.10, alpha: 1.0)) : .black

            // Apple system status item colors:
            // - Low Power Mode: System Yellow
            // - Low Battery (<= 20% on battery): System Red
            // - Charging: Pure white in monochrome mode (Apple macOS native), systemGreen if monochrome is disabled
            // - Normal: Base (White / Dark)
            let fill: NSColor
            if isLowPower {
                fill = isDark ? NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0) : NSColor(red: 0.86, green: 0.62, blue: 0.0, alpha: 1.0)
            } else if level <= 20 && !isExtConnected {
                fill = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
            } else if isCharging && !monochrome {
                fill = NSColor(red: 0.20, green: 0.83, blue: 0.39, alpha: 1.0)
            } else {
                fill = base
            }

            let body = bodyRect
            let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyCornerRadius, yRadius: bodyCornerRadius)
            let capPath = makeCapPath(in: capRect)

            // Translucent unfilled battery shell and terminal cap
            let emptyColor = base.withAlphaComponent(emptyAlpha)
            ctx.setFillColor(emptyColor.cgColor)
            ctx.addPath(capPath)
            ctx.fillPath()

            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            emptyColor.setFill()
            bodyPath.fill()

            // Dynamic battery level fill
            ctx.saveGState()
            bodyPath.addClip()
            fill.setFill()
            let fillWidth = max(2.5, body.width * CGFloat(level) / 100.0)
            NSRect(x: body.minX, y: body.minY, width: fillWidth, height: body.height).fill()
            ctx.restoreGState()

            // State Glyph Logic:
            // 1. isCharging (actively charging): Always show Apple native Lightning Bolt ⚡
            // 2. isHolding (adapter connected, but charge held at limit, e.g. 80%):
            //    Show Hold Symbol (Pause || or Plug 🔌 or Bolt ⚡ according to preference)
            // 3. On battery: Show percentage digits only
            let symbolPath: CGPath?
            if isCharging {
                symbolPath = boltPath
            } else if isHolding {
                switch holdStyle {
                case .pause:
                    symbolPath = pausePath
                case .plug:
                    symbolPath = plugPath
                case .bolt:
                    symbolPath = boltPath
                }
            } else {
                symbolPath = nil
            }
            let hasGlyph = symbolPath != nil
            let symGap: CGFloat = 0.8

            // Font sizing calibrated to Apple's native 8.0pt digit height (SF Pro Semibold)
            let fontSize: CGFloat = (level == 100 && hasGlyph) ? 8.2 : (level == 100 ? 9.2 : 10.4)
            let kernValue: CGFloat = level == 100 ? -0.25 : kern
            let digits = outline("\(level)", size: fontSize, kernValue: kernValue)
            let textBounds = digits.boundingBoxOfPath

            let symBounds = symbolPath?.boundingBoxOfPath ?? .zero
            let contentWidth = textBounds.width + (hasGlyph ? (symGap + symBounds.width) : 0)
            let startX = (body.midX - contentWidth / 2.0).rounded()

            // Knock out digits and glyph from the battery body (Apple system effect)
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(NSColor.black.cgColor)

            var place = CGAffineTransform(
                translationX: startX - textBounds.minX,
                y: (body.midY - textBounds.midY).rounded()
            )
            if let placed = digits.copy(using: &place) {
                ctx.addPath(placed)
                ctx.fillPath()
            }

            if let path = symbolPath {
                let symX = startX + textBounds.width + symGap
                let symY = (body.midY - symBounds.midY).rounded()
                var placeSym = CGAffineTransform(
                    translationX: symX - symBounds.minX,
                    y: symY - symBounds.minY
                )
                if let placedSym = path.copy(using: &placeSym) {
                    ctx.addPath(placedSym)
                    ctx.fillPath()
                }
            }

            ctx.setBlendMode(.normal)
            ctx.endTransparencyLayer()
            return true
        }
        if !isColored {
            img.isTemplate = true
        }
        return img
    }
}
