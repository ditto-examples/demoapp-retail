import AppKit

// Generates the Zava Retail app icon master (1024×1024, opaque, full-bleed
// square — the OS applies the squircle mask). Brand: Anvil/Ditto palette —
// citrus field (citrus500 0xE7EE00 → citrus600 0xD0D600 diagonal), neutral950
// (0x0A0A0A) Ditto mark (exact geometry from assets/ditto_mark-dark.svg).
// Run via `make icon`.
//
// Self-check: after rendering, samples pixels so a broken drawing fails loudly
// (glyph points must be ink, the corner must be citrus, alpha must be 255).

let size = 1024
let outputPath = CommandLine.arguments[1]

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

/// Bitmap reps are y-up like Cocoa. Background: diagonal citrus gradient
/// (top-left lighter → bottom-right deeper).
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xE7EE00), rgb(0xD0D600)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

/// Subtle top sheen for depth (white at 8% fading out over the top third).
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: size * 2 / 3),
    options: []
)

// Glyph: the Ditto mark in neutral950 (exact geometry from
// assets/ditto_mark-dark.svg — three blocks + chevron, viewBox 376×416).
// SVG y-down → this canvas is y-up, so the mapping flips y; the mark is
// scaled to ~47% of the canvas height and centered.
let markScale: CGFloat = 1.45
func mapX(_ x: CGFloat) -> CGFloat {
    512 + (x - 188) * markScale
}

func mapY(_ y: CGFloat) -> CGFloat {
    512 + (208 - y) * markScale
}

func addPolygon(_ points: [(CGFloat, CGFloat)]) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: mapX(points[0].0), y: mapY(points[0].1)))
    for p in points.dropFirst() {
        path.addLine(to: CGPoint(x: mapX(p.0), y: mapY(p.1)))
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
}

ctx.setFillColor(rgb(0x0A0A0A))
addPolygon([(170, 240), (170, 176), (166, 172), (102, 172), (98, 176), (98, 240), (102, 244), (166, 244)]) // block-center
addPolygon([(50, 260), (46, 264), (46, 302), (50, 306), (88, 306), (92, 302), (92, 264), (88, 260)]) // block-small-bottom
addPolygon([(50, 110), (46, 114), (46, 152), (50, 156), (88, 156), (92, 152), (92, 114), (88, 110)]) // block-small-top
addPolygon([
    (326, 162),
    (254, 162),
    (250, 158),
    (250, 96),
    (246, 92),
    (182, 92),
    (178, 88),
    (178, 50),
    (174, 46),
    (130, 46),
    (126, 50),
    (126, 96),
    (130, 100),
    (178, 100),
    (182, 104),
    (182, 166),
    (186, 170),
    (254, 170),
    (258, 174),
    (258, 242),
    (254, 246),
    (186, 246),
    (182, 250),
    (182, 312),
    (178, 316),
    (130, 316),
    (126, 320),
    (126, 366),
    (130, 370),
    (174, 370),
    (178, 366),
    (178, 328),
    (182, 324),
    (246, 324),
    (250, 320),
    (250, 258),
    (254, 254),
    (326, 254),
    (330, 250),
    (330, 166)
]) // chevron

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}

try png.write(to: URL(fileURLWithPath: outputPath))

/// --- Self-check (PNG row 0 is the TOP row; rep is y-up, so flip y) ---
func pixelAt(_ x: Int, _ yUp: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var p = [0, 0, 0, 0]
    rep.getPixel(&p, atX: x, y: yUp) // rep bitmap is y-up already
    return (p[0], p[1], p[2], p[3])
}

let blockCenter = pixelAt(Int(mapX(134)), Int(mapY(208))) // block-center → ink
let chevronTip = pixelAt(Int(mapX(328)), Int(mapY(208))) // chevron point → ink
let corner = pixelAt(40, 984) // top-left corner → citrus

print("block center:", blockCenter, "(expect ~(10,10,10,255))")
print("chevron tip:", chevronTip, "(expect ~(10,10,10,255))")
print("corner:", corner, "(expect ~(231,238,0,255))")

guard blockCenter.r < 40, blockCenter.g < 40, blockCenter.b < 40, blockCenter.a == 255,
      chevronTip.r < 40, chevronTip.g < 40, chevronTip.b < 40, chevronTip.a == 255,
      corner.r > 200, corner.g > 200, corner.b < 60, corner.a == 255 else { fatalError("icon self-check FAILED — glyph/background not where expected") }
print("self-check OK: Ditto mark + citrus field at expected positions, fully opaque")
