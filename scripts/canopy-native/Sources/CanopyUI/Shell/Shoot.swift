import AppKit
import CanopyCore
import SwiftUI

/// `--shoot <dir> <shot>…`: no visible window. Hydrate from the server, then for each shot
/// (`name=/v2/route[:key key …]`) navigate, press the keys, settle, and draw the window offscreen
/// into `<dir>/<name>.png` — how the app's looks get checked without anyone's screen. Keys are
/// pressed through the engine like Phil's, so only pass keys that move or switch tabs, never a write.
/// Inside a shot: `>text` types into the open Helix terminal (`\\r` is enter, `\\e` escape), `~N` waits N
/// seconds, `!name` draws a mid-sequence `<name>.png`, `=k` presses k as a key (`=?` the sheet), and `?` prints the review page's cursor and Helix's last place.
@MainActor
public enum Shoot {
    public static func run(_ config: AppConfig) -> Never {
        Log.quiet = true
        Fonts.register()
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let port = config.resolvedPort() else {
            print("shoot: no server port")
            exit(2)
        }
        let app = AppModel(config: config, port: port, telemetry: false)
        var hello = false
        app.stream.onFrame = { f in if f.event == "hello" { hello = true } }
        app.start()
        let size = NSSize(width: config.shootWidth, height: config.shootHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: config.appearance == "light" ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: AnyView(RootView().environment(app)
                .preferredColorScheme(config.appearance == "light" ? .light : .dark)))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []   // a real window is the size its person made it; content never grows it
        window.contentView = host
        window.orderBack(nil)
        Task { @MainActor in
            let t0 = Date()
            while !hello, Date().timeIntervalSince(t0) < 15 { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for spec in config.shots {
                let (name, rest) = spec.split(separator: "=", maxSplits: 1).map(String.init).pair
                let parts = rest.split(separator: " ").map(String.init)
                guard let route = parts.first else { continue }
                app.router.navigate(route)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                func draw(_ shot: String) {
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: config.shootDir).appendingPathComponent("\(shot).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print(url.path)
                }
                for k in parts.dropFirst() {
                    if k.hasPrefix(">"), k.count > 1 {
                        let text = String(k.dropFirst()).replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}")
                        if let t = terminal(in: host) { t.send(txt: text) } else { print("shoot: no terminal to type \(k) into") }
                    } else if k.hasPrefix("~"), let secs = Double(k.dropFirst()) {
                        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    } else if k.hasPrefix("!"), k.count > 1 {
                        draw(String(k.dropFirst()))
                    } else if k == "#" {
                        if let t = terminal(in: host) {
                            let term = t.getTerminal()
                            print("screen: \(term.cols)x\(term.rows) view=\(NSStringFromSize(t.bounds.size))")
                            for r in 0..<term.rows { print("  |" + (term.getLine(row: r)?.translateToString(trimRight: true) ?? "")) }
                        } else { print("screen: no terminal") }
                    } else if k.hasPrefix("="), k.count > 1 {
                        _ = app.keys.handle(String(k.dropFirst()))
                    } else if k == "?" {
                        let pg = ReviewPageState.of(app)
                        print("state: cursor=\(pg.here?.key ?? "nil") pane=\(app.pane?.id ?? "nil") helix=\(pg.helix.map { "\($0.path):\($0.line) whole=\($0.whole)" } ?? "closed") helixAt=\(pg.helixAt.map { "\($0.path):\($0.line)" } ?? "nil") terminalFrame=\(terminal(in: host).map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "none") window=\(NSStringFromSize(size))")
                    } else {
                        _ = app.keys.handle(k)
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: UInt64(config.dumpWait * 1_000_000_000))
                draw(name)
                _ = app.keys.handle("esc")
            }
            exit(hello ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }
}

@MainActor private func terminal(in view: NSView) -> HelixTerminal? {
    if let t = view as? HelixTerminal { return t }
    for v in view.subviews { if let t = terminal(in: v) { return t } }
    return nil
}

private extension Array where Element == String {
    var pair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
