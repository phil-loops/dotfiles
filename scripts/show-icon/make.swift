#!/usr/bin/env swift
// show-icon/make.swift <out.icns> — draws Show's app icon on canopy's night vellum: a gold card, a second
// peeking out behind, with a fork drawn on it in dark ink and ember. Re-run after changing the drawing; the
// build copies the committed AppIcon.icns into Show.app.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let gold = color(0xE6B64E), goldHi = color(0xF2CD72), goldDeep = color(0x6E5A2C), night = color(0x121315), edge = color(0x2A2B30), ember = color(0xD2732A)
typealias Mark = (CGContext) -> Void
func tile(_ ctx: CGContext, _ top: CGColor = edge, _ bottom: CGColor = night) {
    let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0.4))
    ctx.addPath(shape); ctx.setFillColor(bottom); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
}
func card(_ ctx: CGContext, _ r: CGRect, _ top: CGColor, _ bottom: CGColor) {
    let p = CGPath(roundedRect: r, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.restoreGState()
}
func fork(_ ctx: CGContext, center c: CGPoint, scale s: CGFloat, ink: CGColor, accent: CGColor) {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    let a = P(-150, -110), f = P(-30, 0), up = P(150, 110), down = P(150, -80)
    func line(_ p: CGPoint, _ q: CGPoint, _ col: CGColor) {
        ctx.move(to: p); ctx.addCurve(to: q, control1: CGPoint(x: p.x + (q.x - p.x) * 0.5, y: p.y), control2: CGPoint(x: q.x - (q.x - p.x) * 0.5, y: q.y))
        ctx.setLineWidth(44 * s); ctx.setLineCap(.round); ctx.setStrokeColor(col); ctx.strokePath()
    }
    func dot(_ p: CGPoint, _ r: CGFloat, _ col: CGColor) { ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: p.x - r * s, y: p.y - r * s, width: 2 * r * s, height: 2 * r * s)) }
    line(a, f, ink); line(f, up, ink); line(f, down, accent)
    dot(a, 54, ink); dot(up, 60, ink); dot(down, 56, accent)
}
/// The icon: one gold card, straight, the fork in dark ink on it; a second card peeks out behind.
let icon: Mark = { ctx in
    tile(ctx)
    card(ctx, CGRect(x: 290, y: 330, width: 500, height: 400), color(0x8A7036), goldDeep)
    card(ctx, CGRect(x: 234, y: 274, width: 500, height: 400), goldHi, gold)
    fork(ctx, center: CGPoint(x: 484, y: 474), scale: 1, ink: night, accent: color(0x8A3E12))
}
func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    icon(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
