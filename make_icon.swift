// Draws the app icon and writes icon.icns next to this script.
// Usage: swift make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let cs = CGColorSpaceCreateDeviceRGB()
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

    // Rounded-square body (Apple's grid: 824pt body, 100pt inset)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(c(0.1, 0.1, 0.2)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [c(0.20, 0.16, 0.42), c(0.07, 0.07, 0.16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Disc
    let center = CGPoint(x: 512, y: 560)
    let R: CGFloat = 300
    let disc = CGPath(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R), transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: c(0, 0, 0, 0.5))
    ctx.addPath(disc); ctx.setFillColor(c(0.8, 0.82, 0.86)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(disc); ctx.clip()
    // Iridescent sheen
    let stops: [(CGFloat, CGFloat, CGFloat)] = [
        (0.86, 0.88, 0.92), (0.62, 0.78, 1.0), (0.95, 0.96, 0.98), (1.0, 0.72, 0.86),
        (0.86, 0.88, 0.92), (0.70, 1.0, 0.86), (0.95, 0.96, 0.98), (1.0, 0.90, 0.62), (0.86, 0.88, 0.92),
    ]
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let f = t * CGFloat(stops.count - 1)
        let k = min(Int(f), stops.count - 2), u = f - CGFloat(k)
        let a = stops[k], b = stops[k + 1]
        ctx.setFillColor(c(a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u))
        let a0 = .pi / 5 + t * 2 * .pi, a1 = a0 + 2 * .pi / CGFloat(steps) + 0.004
        ctx.move(to: center)
        ctx.addArc(center: center, radius: R + 2, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath(); ctx.fillPath()
    }
    // Fine grooves
    ctx.setLineWidth(1.5)
    var r: CGFloat = 115
    while r < R - 6 {
        ctx.setStrokeColor(c(1, 1, 1, 0.10))
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        r += 9
    }
    ctx.restoreGState()
    ctx.setStrokeColor(c(1, 1, 1, 0.55)); ctx.setLineWidth(4)
    ctx.addPath(disc); ctx.strokePath()

    // Hub and hole
    for (rad, col) in [(108.0, c(0.93, 0.94, 0.96, 0.85)), (78.0, c(0.72, 0.74, 0.8)), (46.0, c(0.11, 0.10, 0.24))] {
        let rr = CGFloat(rad)
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: center.x - rr, y: center.y - rr, width: 2 * rr, height: 2 * rr))
    }

    // "CHD" badge
    let badge = CGRect(x: 302, y: 168, width: 420, height: 150)
    let badgePath = CGPath(roundedRect: badge, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: c(0, 0, 0, 0.45))
    ctx.addPath(badgePath); ctx.clip()
    let bgrad = CGGradient(colorsSpace: cs, colors: [c(1.0, 0.55, 0.25), c(0.93, 0.25, 0.42)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgrad, start: CGPoint(x: badge.minX, y: badge.maxY), end: CGPoint(x: badge.maxX, y: badge.minY), options: [])
    ctx.restoreGState()

    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
        .kern: 6,
    ]
    let text = NSAttributedString(string: "CHD", attributes: attrs)
    let th = text.size().height
    text.draw(in: CGRect(x: badge.minX, y: badge.midY - th / 2 - 4, width: badge.width, height: th))

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let set = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: here.appendingPathComponent("icon-preview.png"))
print("iconset written")
