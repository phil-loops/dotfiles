import AppKit
import CanopyCore
import SwiftUI

/// `--shoot <dir> <shot>…`: no visible window. Hydrate from the server, then for each shot
/// (`name=/v2/route[:key key …]`) navigate, press the keys, settle, and draw the window offscreen
/// into `<dir>/<name>.png` — how the app's looks get checked without anyone's screen. Keys are
/// pressed through the engine like Phil's, so only pass keys that move or switch tabs, never a write.
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
                for k in parts.dropFirst() {
                    _ = app.keys.handle(k)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: UInt64(config.dumpWait * 1_000_000_000))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: config.shootDir).appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
                _ = app.keys.handle("esc")
            }
            exit(hello ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }
}

private extension Array where Element == String {
    var pair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
