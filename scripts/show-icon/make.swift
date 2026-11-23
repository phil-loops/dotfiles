#!/usr/bin/env swift
// show-icon/make.swift <out.icns> — draws Show's app icon on canopy's night vellum: a deck of two cards, the
// front one carrying a fork in gold leaf and ember. Re-run after changing the drawing; the
// build copies the committed AppIcon.icns into Show.app.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let gold = color(0xE6B64E), goldDeep = color(0x6E5A2C), ember = color(0xD2732A)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // the macOS icon body: an 824-point rounded square centred on the 1024 canvas, lifted by a soft shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x121315))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [color(0x222327), color(0x121315)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(goldDeep)
    ctx.setLineWidth(6)
    ctx.strokePath()

    // a deck of two cards: the back one solid, turned and shifted so its corner shows; the front one edged
    // in gold, carrying a fork — a branch and its two children, one in ember
    func curve(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat, _ c: CGColor) {
        ctx.move(to: a)
        ctx.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + (b.y - a.y) * 0.55), control2: CGPoint(x: b.x, y: b.y - (b.y - a.y) * 0.45))
        ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setStrokeColor(c); ctx.strokePath()
    }
    func disc(_ p: CGPoint, _ r: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    func turned(_ angle: CGFloat, by shift: CGPoint, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 512 + shift.x, y: 512 + shift.y); ctx.rotate(by: angle); ctx.translateBy(x: -512, y: -512)
        draw()
        ctx.restoreGState()
    }
    let card = CGPath(roundedRect: CGRect(x: 252, y: 292, width: 520, height: 440), cornerWidth: 56, cornerHeight: 56, transform: nil)
    turned(0.16, by: CGPoint(x: 34, y: -34)) {
        ctx.addPath(card); ctx.setFillColor(goldDeep); ctx.fillPath()
    }
    turned(-0.05, by: CGPoint(x: -14, y: 18)) {
        ctx.addPath(card); ctx.setFillColor(color(0x1A1B1E)); ctx.fillPath()
        ctx.addPath(card); ctx.setStrokeColor(gold); ctx.setLineWidth(30); ctx.strokePath()
        let a = CGPoint(x: 360, y: 405), fork = CGPoint(x: 482, y: 508), up = CGPoint(x: 662, y: 626), down = CGPoint(x: 666, y: 424)
        curve(a, fork, 42, gold); curve(fork, up, 42, gold); curve(fork, down, 42, ember)
        disc(a, 52, gold); disc(fork, 36, gold); disc(up, 58, gold); disc(down, 54, ember)
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try draw(1024).write(to: set.deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
