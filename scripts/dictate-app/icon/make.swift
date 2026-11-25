#!/usr/bin/env swift
// dictate-app/icon/make.swift <out.icns> — draws Dictate's app icon: a gold microphone on Show's night tile, with an
// ember dot for "recording". Re-run after changing the drawing; the build copies the committed AppIcon.icns into Dictate.app.
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let gold = color(0xE6B64E), night = color(0x121315), edge = color(0x2A2B30), ember = color(0xD2732A)

/// Draws on a 1024-unit canvas; the Apple icon template keeps the tile 100 units in from each edge.
func drawIcon(in ctx: CGContext, scale s: CGFloat) {
    ctx.scaleBy(x: s, y: s)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [edge, night] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    ctx.setFillColor(gold)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 412, y: 470, width: 200, height: 300), cornerWidth: 100, cornerHeight: 100, transform: nil))
    ctx.fillPath()

    ctx.setStrokeColor(gold)
    ctx.setLineCap(.round)
    ctx.setLineWidth(46)
    ctx.move(to: CGPoint(x: 332, y: 560))
    ctx.addCurve(to: CGPoint(x: 692, y: 560), control1: CGPoint(x: 332, y: 360), control2: CGPoint(x: 692, y: 360))
    ctx.move(to: CGPoint(x: 512, y: 415))
    ctx.addLine(to: CGPoint(x: 512, y: 300))
    ctx.move(to: CGPoint(x: 410, y: 300))
    ctx.addLine(to: CGPoint(x: 614, y: 300))
    ctx.strokePath()

    ctx.setFillColor(ember)
    ctx.fillEllipse(in: CGRect(x: 730, y: 730, width: 110, height: 110))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: NSGraphicsContext.current!.cgContext, scale: CGFloat(pixels) / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
let work = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for size in sizes {
    try png(pixels: size.pixels).write(to: iconset.appendingPathComponent("\(size.name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: work)
exit(iconutil.terminationStatus)
