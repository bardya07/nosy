// Builds Nosy's icons from Resources/Brand/nosy-source.png (square, opaque artwork):
// AppIcon.icns on Apple's macOS grid (824px squircle on a 1024px canvas, soft shadow)
// and NosyMark.png, the masked artwork without padding for use inside the app.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let source = NSImage(contentsOf: root.appendingPathComponent("Resources/Brand/nosy-source.png"))!
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Nosy-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int, padded: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let side = (padded ? 824 : 1024) * scale
    let rect = NSRect(x: (CGFloat(pixels) - side) / 2, y: (CGFloat(pixels) - side) / 2 + (padded ? 10 * scale : 0), width: side, height: side)
    // The artwork's own corners are white; a slightly larger continuous-corner mask trims them.
    let shape = NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225)
    if padded {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 18 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        NSColor(srgbRed: 0.016, green: 0.19, blue: 0.25, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    shape.addClip()
    // Inset 1.5% so the white corner pixels sit fully outside the mask.
    let bleed = side * 0.015
    source.draw(in: rect.insetBy(dx: -bleed, dy: -bleed))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size, padded: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2, padded: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run(); iconutil.waitUntilExit()
try! render(256, padded: false).write(to: root.appendingPathComponent("Resources/NosyMark.png"))
try! render(1024, padded: true).write(to: root.appendingPathComponent("Resources/Brand/nosy-icon-1024.png"))
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "ICON PASS" : "ICON FAIL")
