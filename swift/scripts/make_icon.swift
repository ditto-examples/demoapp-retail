import AppKit

/// Generates the Zava Retail app icon master (1024×1024, opaque, full-bleed
/// square — the OS applies the squircle mask). Brand: Anvil/Ditto palette —
/// citrus field (citrus500 0xE7EE00 → citrus600 0xD0D600 diagonal), neutral950
/// (0x0A0A0A) shopping-bag glyph. Run via `make icon`.
///
/// Self-check: after rendering, samples pixels so a broken drawing fails loudly
/// (glyph points must be ink, the corner must be citrus, alpha must be 255).

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

// Bitmap reps are y-up like Cocoa. Background: diagonal citrus gradient
// (top-left lighter → bottom-right deeper).
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

// Subtle top sheen for depth (white at 8% fading out over the top third).
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: size * 2 / 3),
    options: []
)

// Glyph: shopping bag in neutral950.
ctx.setFillColor(rgb(0x0A0A0A))
ctx.setStrokeColor(rgb(0x0A0A0A))

// Body: rounded rect 440×430, horizontally centered, sitting low-center.
ctx.addPath(CGPath(
    roundedRect: CGRect(x: 292, y: 250, width: 440, height: 430),
    cornerWidth: 72,
    cornerHeight: 72,
    transform: nil
))
ctx.fillPath()

// Handle: top semicircle arching over the body, ends overlapping the body top.
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 512, y: 640), radius: 120, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.strokePath()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try png.write(to: URL(fileURLWithPath: outputPath))

// --- Self-check (PNG row 0 is the TOP row; rep is y-up, so flip y) ---
func pixelAt(_ x: Int, _ yUp: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var p = [0, 0, 0, 0]
    rep.getPixel(&p, atX: x, y: yUp) // rep bitmap is y-up already
    return (p[0], p[1], p[2], p[3])
}

let bodyCenter = pixelAt(512, 460) // inside the bag body → ink
let handleTop = pixelAt(512, 760) // on the handle stroke → ink
let corner = pixelAt(40, 984) // top-left corner → citrus

print("body center:", bodyCenter, "(expect ~(10,10,10,255))")
print("handle top:", handleTop, "(expect ~(10,10,10,255))")
print("corner:", corner, "(expect ~(231,238,0,255))")

guard bodyCenter.r < 40, bodyCenter.g < 40, bodyCenter.b < 40, bodyCenter.a == 255,
      handleTop.r < 40, handleTop.g < 40, handleTop.b < 40, handleTop.a == 255,
      corner.r > 200, corner.g > 200, corner.b < 60, corner.a == 255
else { fatalError("icon self-check FAILED — glyph/background not where expected") }
print("self-check OK: bag glyph + citrus field at expected positions, fully opaque")
