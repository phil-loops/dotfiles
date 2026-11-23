#!/usr/bin/env swift
// show-icon/make.swift <out.icns> — draws Show's app icon: a forest in gold leaf on canopy's night vellum,
// one trunk forking into branches that each end in a node. Re-run after changing the drawing; the
// build copies the committed AppIcon.icns into Show.app.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let gold = color(0xE6B64E), goldDeep = color(0x6E5A2C)

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

    // the forest: a trunk from the root node, forking twice; branches are curves, nodes are discs
    let root = CGPoint(x: 512, y: 250), fork = CGPoint(x: 512, y: 470)
    let mid = [CGPoint(x: 350, y: 620), CGPoint(x: 512, y: 660), CGPoint(x: 674, y: 620)]
    let tips = [CGPoint(x: 280, y: 770), CGPoint(x: 420, y: 790), CGPoint(x: 604, y: 790), CGPoint(x: 744, y: 770)]
    func branch(_ a: CGPoint, _ b: CGPoint, width: CGFloat) {
        ctx.move(to: a)
        ctx.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + (b.y - a.y) * 0.55), control2: CGPoint(x: b.x, y: b.y - (b.y - a.y) * 0.45))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(gold)
        ctx.strokePath()
    }
    branch(root, fork, width: 30)
    for m in mid { branch(fork, m, width: 22) }
    branch(mid[0], tips[0], width: 16); branch(mid[0], tips[1], width: 16)
    branch(mid[2], tips[2], width: 16); branch(mid[2], tips[3], width: 16)
    func node(_ p: CGPoint, _ r: CGFloat, hollow: Bool = false) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        if hollow {
            ctx.setFillColor(color(0x1A1B1E)); ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(gold); ctx.setLineWidth(10); ctx.strokeEllipse(in: rect.insetBy(dx: 5, dy: 5))
        } else {
            ctx.setFillColor(gold); ctx.fillEllipse(in: rect)
        }
    }
    node(root, 40)
    node(fork, 26)
    for m in mid { node(m, 26) }
    for t in tips { node(t, 34) }
    node(mid[1], 40, hollow: true)

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
