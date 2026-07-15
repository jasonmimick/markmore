// Rasterizes icon.svg into markmore.iconset/ (NSImage renders SVG natively on macOS 11+).
// Run: swift genicon.swift && iconutil -c icns markmore.iconset -o markmore.icns

import Cocoa

guard let svg = NSImage(contentsOfFile: "icon.svg") else {
    FileHandle.standardError.write("genicon: cannot load icon.svg\n".data(using: .utf8)!)
    exit(1)
}

func rasterize(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: "markmore.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! rasterize(pt).write(to: out.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! rasterize(pt * 2).write(to: out.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
print("wrote markmore.iconset from icon.svg")
