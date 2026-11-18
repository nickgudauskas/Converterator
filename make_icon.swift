// Draws the app icon in light and dark variants and writes:
//   AppIcon.icon/   an Icon Composer icon (macOS 26+ light/dark/tinted), compiled by build.sh with actool
//   icon-preview.png, icon-preview-dark.png   full previews for the README
// Usage: swift make_icon.swift
import AppKit

struct Style {
    let name: String
    let background: (top: CGColor, bottom: CGColor)
    let discBase: CGColor
    let sheenScale: CGFloat      // dims the disc's iridescence in dark mode
    let grooveAlpha: CGFloat
    let rimAlpha: CGFloat
    let hole: CGColor
    let edgeHighlight: CGFloat   // faint outline so a dark icon doesn't vanish on a dark Dock
}

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

let light = Style(name: "light",
                  background: (c(0.20, 0.16, 0.42), c(0.07, 0.07, 0.16)),
                  discBase: c(0.8, 0.82, 0.86), sheenScale: 1.0, grooveAlpha: 0.10, rimAlpha: 0.55,
                  hole: c(0.11, 0.10, 0.24), edgeHighlight: 0)

let dark = Style(name: "dark",
                 background: (c(0.19, 0.19, 0.22), c(0.06, 0.06, 0.07)),
                 discBase: c(0.55, 0.57, 0.62), sheenScale: 0.78, grooveAlpha: 0.07, rimAlpha: 0.35,
                 hole: c(0.07, 0.07, 0.08), edgeHighlight: 0.10)

let cs = CGColorSpaceCreateDeviceRGB()

/// Renders `draw` into a transparent px×px PNG, with a 1024-unit coordinate space.
func png(_ px: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Full classic icon (rounded square + artwork), used for the README previews.
func renderPreview(_ st: Style) -> Data { png(1024) { ctx in

    // Rounded-square body (Apple's grid: 824pt body, 100pt inset)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(st.background.bottom); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [st.background.top, st.background.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    drawArtwork(ctx, st)
    ctx.restoreGState()   // end body clip

    if st.edgeHighlight > 0 {
        ctx.setStrokeColor(c(1, 1, 1, st.edgeHighlight)); ctx.setLineWidth(3)
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.strokePath()
    }
} }

/// Disc + CHD badge only, on a transparent canvas, drawn in the classic 824-unit body's coordinates.
func drawArtwork(_ ctx: CGContext, _ st: Style) {
    // Disc
    let center = CGPoint(x: 512, y: 560)
    let R: CGFloat = 300
    let disc = CGPath(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R), transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: c(0, 0, 0, 0.5))
    ctx.addPath(disc); ctx.setFillColor(st.discBase); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(disc); ctx.clip()
    // Iridescent sheen
    let stops: [(CGFloat, CGFloat, CGFloat)] = [
        (0.86, 0.88, 0.92), (0.62, 0.78, 1.0), (0.95, 0.96, 0.98), (1.0, 0.72, 0.86),
        (0.86, 0.88, 0.92), (0.70, 1.0, 0.86), (0.95, 0.96, 0.98), (1.0, 0.90, 0.62), (0.86, 0.88, 0.92),
    ]
    let k0 = st.sheenScale
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let f = t * CGFloat(stops.count - 1)
        let k = min(Int(f), stops.count - 2), u = f - CGFloat(k)
        let a = stops[k], b = stops[k + 1]
        ctx.setFillColor(c((a.0 + (b.0 - a.0) * u) * k0, (a.1 + (b.1 - a.1) * u) * k0, (a.2 + (b.2 - a.2) * u) * k0))
        let a0 = .pi / 5 + t * 2 * .pi, a1 = a0 + 2 * .pi / CGFloat(steps) + 0.004
        ctx.move(to: center)
        ctx.addArc(center: center, radius: R + 2, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath(); ctx.fillPath()
    }
    // Fine grooves
    ctx.setLineWidth(1.5)
    var r: CGFloat = 115
    while r < R - 6 {
        ctx.setStrokeColor(c(1, 1, 1, st.grooveAlpha))
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        r += 9
    }
    ctx.restoreGState()
    ctx.setStrokeColor(c(1, 1, 1, st.rimAlpha)); ctx.setLineWidth(4)
    ctx.addPath(disc); ctx.strokePath()

    // Hub and hole
    for (rad, col) in [(108.0, c(0.93 * k0, 0.94 * k0, 0.96 * k0, 0.85)), (78.0, c(0.72 * k0, 0.74 * k0, 0.8 * k0)), (46.0, st.hole)] {
        let rr = CGFloat(rad)
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: center.x - rr, y: center.y - rr, width: 2 * rr, height: 2 * rr))
    }

    // "CHD" badge (same in both modes: it's the accent)
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
}

/// Foreground layer for Icon Composer: the artwork scaled so the classic 824-unit body fills the
/// whole 1024 canvas (macOS applies its own rounded-square mask, shadow and margins).
func renderLayer(_ st: Style) -> Data { png(1024) { ctx in
    let k: CGFloat = 1024 / 824
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -100, y: -100)
    drawArtwork(ctx, st)
} }

let fm = FileManager.default
let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconDir = here.appendingPathComponent("AppIcon.icon")
try? fm.removeItem(at: iconDir)
try! fm.createDirectory(at: iconDir.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try! renderLayer(light).write(to: iconDir.appendingPathComponent("Assets/disc-light.png"))
try! renderLayer(dark).write(to: iconDir.appendingPathComponent("Assets/disc-dark.png"))

func srgb(_ col: CGColor) -> String {
    let p = col.components!
    return String(format: "srgb:%.5f,%.5f,%.5f,%.5f", p[0], p[1], p[2], p[3])
}
func layer(_ name: String, image: String, lightOpacity: Double, darkOpacity: Double) -> [String: Any] {
    ["name": name, "image-name": image, "glass": false, "hidden": false, "blend-mode": "normal",
     "opacity-specializations": [["value": lightOpacity], ["appearance": "dark", "value": darkOpacity]]]
}
let iconJSON: [String: Any] = [
    // Background: purple in light mode, graphite in dark mode.
    "fill-specializations": [
        ["value": ["linear-gradient": [srgb(light.background.top), srgb(light.background.bottom)]]],
        ["appearance": "dark", "value": ["linear-gradient": [srgb(dark.background.top), srgb(dark.background.bottom)]]],
    ],
    "groups": [[
        "name": "disc",
        // Only one of the two artwork layers is visible in each appearance.
        "layers": [layer("disc-dark", image: "disc-dark.png", lightOpacity: 0, darkOpacity: 1),
                   layer("disc-light", image: "disc-light.png", lightOpacity: 1, darkOpacity: 0)],
        "lighting": "combined",
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "specular": false,
        "translucency": ["enabled": false, "value": 0],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]
try! JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconDir.appendingPathComponent("icon.json"))

try! renderPreview(light).write(to: here.appendingPathComponent("icon-preview.png"))
try! renderPreview(dark).write(to: here.appendingPathComponent("icon-preview-dark.png"))
print("Wrote AppIcon.icon and previews")
