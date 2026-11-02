import AppKit
import CanopyCore
import SwiftUI

/// `--bench [--page /v2/…]… [--budget ms]`: no visible window. Walk every page (or the ones named)
/// on the live server's data, press each key in `script` through the engine like Phil's, and time
/// what holds up the next key: handling it, then laying the views out. Painting is timed apart and
/// not budgeted — offscreen it's done on the CPU, where a real window hands it to the GPU. A watchdog
/// also catches the main thread stalling between keys (work a key started that lands later). Prints
/// the slowest and exits 1 when anything is over budget.
/// Keys only move and look — never a write, never anything that leaves the app (`g h`, `g p`).
@MainActor
public enum Bench {
    /// One step: the key names pressed for it, space-separated (`g g` is one step of two keys).
    static let script = [
        "j", "j", "j", "k", "G", "g g", "C-d", "C-u", "h", "l", "l", "h", "w", "b",
        "]", "[", "}", "{", "n", "N", "tab", "tab", "v", "j", "j", "esc",
        "?", "esc", ":", "esc", "/", "x", "esc", "g w", "esc", "space", "esc",
        "space f", "esc", "space b", "esc", "space j", "esc", "space m", "esc", "space k", "esc",
        "J", "K", "-", "C-o", "C-i", "C-o",
    ]

    public static func run(_ config: AppConfig) -> Never {
        Log.quiet = true
        Fonts.register()
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let port = config.resolvedPort() else {
            print("bench: no server port")
            exit(2)
        }
        let app = AppModel(config: config, port: port, telemetry: false)
        var hello = false
        app.stream.onFrame = { f in if f.event == "hello" { hello = true } }
        app.start()
        let size = NSSize(width: config.shootWidth, height: config.shootHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(RootView().environment(app).preferredColorScheme(.dark)))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)

        func paint() {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
        }
        func draw() {
            host.layoutSubtreeIfNeeded()
            paint()
        }
        struct Hit { var page: String; var step: String; var ms: Double; var what: String }
        var hits: [Hit] = []
        var page = "", step = ""
        var last = Date()
        var watching = false
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let gap = Date().timeIntervalSince(last) * 1000
                if watching && gap > config.budget { hits.append(Hit(page: page, step: step, ms: gap, what: "stall after")) }
                last = Date()
            }
        }
        Task { @MainActor in
            let t0 = Date()
            while !hello, Date().timeIntervalSince(t0) < 15 { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let pages = config.pages.isEmpty ? defaultPages(app) : config.pages
            for route in pages {
                watching = false
                page = route
                app.router.navigate(route)
                draw()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                draw()
                last = Date()
                watching = true
                var worst = 0.0
                for s in script {
                    step = s
                    let k0 = Date()
                    for k in s.split(separator: " ") { _ = app.keys.handle(String(k)) }
                    let k1 = Date()
                    host.layoutSubtreeIfNeeded()
                    let k2 = Date()
                    paint()
                    let handle = k1.timeIntervalSince(k0) * 1000, total = k2.timeIntervalSince(k0) * 1000
                    let painted = Date().timeIntervalSince(k2) * 1000
                    worst = max(worst, total)
                    if total > config.budget {
                        hits.append(Hit(page: "\(route) → \(app.router.route.path)", step: s, ms: total,
                                        what: String(format: "key (handle %.0f, layout %.0f; paint %.0f)", handle, total - handle, painted)))
                    }
                    last = Date()
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                watching = false
                for _ in 0..<3 { _ = app.keys.handle("esc") }
                print(String(format: "%-48@ worst key %5.0fms", route as NSString, worst))
            }
            let over = hits.sorted { $0.ms > $1.ms }
            print(over.isEmpty ? "bench: every key under \(Int(config.budget))ms" : "bench: \(over.count) over \(Int(config.budget))ms")
            for h in over.prefix(40) { print(String(format: "  %6.0fms  %-10@ %-36@ %@", h.ms, h.step as NSString, h.what as NSString, h.page)) }
            exit(over.isEmpty && hello ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Every top-level page, the first focus forest, and its branches with a PR (the reviews Phil reads).
    static func defaultPages(_ app: AppModel) -> [String] {
        var out = ["/v2", "/v2/todo", "/v2/machine", "/v2/dashboard", "/v2/wiki", "/v2/tutor", "/v2/keytutor"]
        let m = app.forestModel
        if let p = m.projects().focus.first, let f = m.forest(p.id) {
            out.append("/v2/p/\(p.repo)/\(p.name)")
            out += f.branches.filter { $0.pr != nil && $0.st.ship != .landed }.prefix(3).map { "/v2/b/\(p.repo)/\($0.b.name)" }
        }
        return out
    }
}
