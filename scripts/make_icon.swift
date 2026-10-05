// Renders the BatFlow app icon and writes resources/applet.icns.
// Usage: swift scripts/make_icon.swift [output.icns] [palette]      (run from the repository root)
//        palette: emerald (default) | graphite | ocean | silver
import AppKit
import CoreGraphics
import SwiftUI

let canvas: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    return CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    return CGGradient(colorsSpace: space, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

// MARK: - Palettes
struct Palette {
    var tile: [UInt32]          // top, middle, bottom
    var tileShadow: UInt32
    var glow: UInt32
    var glowAlpha: CGFloat
    var liquid: [UInt32]        // top, middle, bottom
    var bolt: UInt32
    var boltShadow: UInt32
    var shell: UInt32           // glass tint of the battery body and its rims
    var shellAlpha: CGFloat     // multiplier for the frosted body
}

let palettes: [String: Palette] = [
    // Near-black graphite tile, emerald charge: the liquid is the only saturated colour
    "graphite": Palette(tile: [0x4A4D55, 0x26282D, 0x101114], tileShadow: 0x000000, glow: 0x30E8A0, glowAlpha: 0.34,
                        liquid: [0x6DFFC4, 0x30E08F, 0x12B56B], bolt: 0xFFFFFF, boltShadow: 0x035A32, shell: 0xFFFFFF, shellAlpha: 1.0),
    // System-green tile with a white charge and a green bolt
    "emerald": Palette(tile: [0x6FEB8E, 0x34C759, 0x1E9E46], tileShadow: 0x0B5A24, glow: 0xFFFFFF, glowAlpha: 0.22,
                       liquid: [0xFFFFFF, 0xF6FFF8, 0xDDF8E4], bolt: 0x22B14C, boltShadow: 0x9AD9AD, shell: 0xFFFFFF, shellAlpha: 1.15),
    // Blue tile with a cyan charge
    "ocean": Palette(tile: [0x4FA8FF, 0x1F6FEB, 0x0B3BA8], tileShadow: 0x06215F, glow: 0x7DE8FF, glowAlpha: 0.36,
                     liquid: [0xB5F6FF, 0x5ED9FF, 0x22B4F2], bolt: 0xFFFFFF, boltShadow: 0x0A5E96, shell: 0xFFFFFF, shellAlpha: 1.0),
    // Light silver tile, green charge
    "silver": Palette(tile: [0xFFFFFF, 0xEEF1F5, 0xCBD2DB], tileShadow: 0x5A6470, glow: 0x34C759, glowAlpha: 0.20,
                      liquid: [0x73F09A, 0x34C759, 0x1FA347], bolt: 0xFFFFFF, boltShadow: 0x0F6E2D, shell: 0x5C6672, shellAlpha: 0.75)
]

let paletteName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "emerald"
guard let pal = palettes[paletteName] else {
    print("Unknown palette \(paletteName). Available: \(palettes.keys.sorted().joined(separator: ", "))")
    exit(1)
}

/// Apple's continuous-curvature corner (the same curve the system uses for icons and glass shapes).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// Fills the stroke of `path` with a top-to-bottom gradient: the lit rim of a glass edge.
func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGColor, bottom: CGColor, from: CGFloat, to: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(top, 0), (bottom, 1)]), start: CGPoint(x: 512, y: from), end: CGPoint(x: 512, y: to),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: 824pt tile centred on a 1024pt canvas, continuous corners
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile, radius: 185.4)

    // Drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.36))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(pal.tile[2]))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: deep teal glass, lit from above, with the charge's glow pooling behind the battery
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(pal.tile[0]), 0), (color(pal.tile[1]), 0.5), (color(pal.tile[2]), 1)]),
                           start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.drawRadialGradient(gradient([(color(pal.glow, pal.glowAlpha), 0), (color(pal.glow, pal.glowAlpha * 0.3), 0.55), (color(pal.glow, 0), 1)]),
                           startCenter: CGPoint(x: 440, y: 500), startRadius: 0, endCenter: CGPoint(x: 440, y: 500), endRadius: 470, options: [])
    // Soft sheen fading down from the top edge
    ctx.drawLinearGradient(gradient([(color(0xFFFFFF, 0.22), 0), (color(0xFFFFFF, 0.05), 0.35), (color(0xFFFFFF, 0), 0.6)]),
                           start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()

    // Lit rim of the tile: bright along the top edge, a faint counter-light along the bottom
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    rim(ctx, squircle(tile.insetBy(dx: 3, dy: 3), radius: 182.4), width: 6, top: color(0xFFFFFF, 0.60), bottom: color(0xFFFFFF, 0), from: tile.maxY, to: tile.midY + 120)
    rim(ctx, squircle(tile.insetBy(dx: 3, dy: 3), radius: 182.4), width: 6, top: color(pal.glow, 0), bottom: color(pal.glow, 0.28), from: tile.minY + 160, to: tile.minY)
    ctx.restoreGState()

    // ---- Battery: a thick pane of glass floating above the tile ----
    let body = CGRect(x: 190, y: 356, width: 596, height: 312)
    let bodyPath = squircle(body, radius: 100)
    let inner = body.insetBy(dx: 30, dy: 30)
    let innerPath = squircle(inner, radius: 70)

    // Shadow the pane casts on the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: color(pal.tileShadow, 0.50))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(pal.shell, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // Frosted body: brighter at the top where the light enters
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(pal.shell, 0.36 * pal.shellAlpha), 0), (color(pal.shell, 0.12 * pal.shellAlpha), 0.55), (color(pal.shell, 0.20 * pal.shellAlpha), 1)]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // Liquid charge with a wave as its leading edge (the "flow")
    let edge = inner.minX + inner.width * 0.72
    let third = inner.height / 3
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: inner.minX, y: inner.minY))
    wave.addLine(to: CGPoint(x: edge, y: inner.minY))
    wave.addCurve(to: CGPoint(x: edge, y: inner.minY + third * 1.5),
                  control1: CGPoint(x: edge + 46, y: inner.minY + third * 0.5), control2: CGPoint(x: edge + 46, y: inner.minY + third * 1.0))
    wave.addCurve(to: CGPoint(x: edge, y: inner.maxY),
                  control1: CGPoint(x: edge - 46, y: inner.minY + third * 2.0), control2: CGPoint(x: edge - 46, y: inner.minY + third * 2.5))
    wave.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
    wave.closeSubpath()

    ctx.saveGState()
    ctx.addPath(innerPath)
    ctx.clip()
    ctx.addPath(wave)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(pal.liquid[0]), 0), (color(pal.liquid[1]), 0.45), (color(pal.liquid[2]), 1)]),
                           start: CGPoint(x: 512, y: inner.maxY), end: CGPoint(x: 512, y: inner.minY), options: [])
    // Gloss band inside the liquid
    ctx.addPath(squircle(CGRect(x: inner.minX + 16, y: inner.maxY - 78, width: inner.width, height: 58), radius: 29))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0xFFFFFF, 0.62), 0), (color(0xFFFFFF, 0.06), 1)]),
                           start: CGPoint(x: 512, y: inner.maxY - 20), end: CGPoint(x: 512, y: inner.maxY - 78), options: [])
    ctx.restoreGState()

    // Glass edges: outer rim catches the light on top, inner lip separates the liquid from the shell
    rim(ctx, squircle(body.insetBy(dx: 5, dy: 5), radius: 95), width: 10, top: color(pal.shell, 0.98), bottom: color(pal.shell, 0.38), from: body.maxY, to: body.minY)
    rim(ctx, innerPath, width: 3, top: color(pal.shell, 0.10), bottom: color(pal.shell, 0.42), from: inner.maxY, to: inner.minY)

    // Terminal, same glass
    let capRect = CGRect(x: body.maxX + 16, y: body.midY - 54, width: 36, height: 108)
    let capPath = squircle(capRect, radius: 16)
    ctx.saveGState()
    ctx.addPath(capPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(pal.shell, 0.95), 0), (color(pal.shell, 0.50), 1)]),
                           start: CGPoint(x: 512, y: capRect.maxY), end: CGPoint(x: 512, y: capRect.minY), options: [])
    ctx.restoreGState()

    // Bolt: solid white, rounded joints, lifted off the liquid by a soft shadow
    let bolt = CGMutablePath()
    let c = CGPoint(x: inner.minX + inner.width * 0.36, y: body.midY)
    let pts: [(CGFloat, CGFloat)] = [(34, 100), (-58, -14), (-4, -14), (-34, -100), (58, 14), (4, 14)]
    bolt.move(to: CGPoint(x: c.x + pts[0].0, y: c.y + pts[0].1))
    for p in pts.dropFirst() { bolt.addLine(to: CGPoint(x: c.x + p.0, y: c.y + p.1)) }
    bolt.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(pal.boltShadow, 0.60))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(pal.bolt))
    ctx.setStrokeColor(color(pal.bolt))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(12)
    ctx.addPath(bolt)
    ctx.fillPath(using: .winding)
    ctx.addPath(bolt)
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BatFlow-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
for base in [16, 32, 128, 256, 512] {
    writePNG(master, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(master, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent("resources/applet.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
