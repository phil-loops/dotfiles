import AppKit
import CanopyCore
import SwiftUI

/// `--bench [--page /v2/…]… [--budget ms] [--quick]`: no visible window. Walk every page (or the ones named)
/// on the live server's data and time what holds up the next key — handling it, then laying the
/// views out — in four passes: the `script` keys; typing into every filter one character at a time;
/// the same keys again while server patches pour in; and every write the page offers. Painting is
/// timed apart and not budgeted — offscreen it's done on the CPU, where a real window hands it to
/// the GPU. A watchdog also catches the main thread stalling between keys (work a key started that
/// lands later). Prints the slowest and exits 1 when anything is over budget. `--quick` runs the
/// first and third passes only (what `canopy-benchwatch` runs after each commit).
/// Keys only move and look — never `space o g`, `space o p` or anything that leaves the app. Writes run, but
/// every request that isn't a GET is answered here (`Blackhole`) and never reaches the server.
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
    /// Open a field, then `'text` types it one character (one timed step) at a time.
    static let typing = [
        ":", "'go forest", "esc", "/", "'hank", "esc", "space b", "'hankles", "esc",
        "space f", "'model", "esc", "@menu.open", "'branch", "esc",
    ]
    /// Patches a second while `pressure` runs the script again.
    static let patchesPerSecond = 10.0

    public static func run(_ config: AppConfig) -> Never {
        Log.quiet = true
        Fonts.register()
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let port = config.resolvedPort() else {
            print("bench: no server port")
            exit(2)
        }
        let app = AppModel(config: config, port: port, telemetry: false, protocolClasses: [Blackhole.self])
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
        struct Hit { var page: String; var pass: String; var step: String; var ms: Double; var what: String }
        var hits: [Hit] = []
        var page = "", pass = "", step = ""
        var last = Date()
        var watching = false
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000)
                let gap = Date().timeIntervalSince(last) * 1000
                if watching && gap > config.budget { hits.append(Hit(page: page, pass: pass, step: step, ms: gap, what: "stall after")) }
                last = Date()
            }
        }

        /// Type one character into whatever field the live mode is typing into; false when none is.
        func type(_ c: Character) -> Bool {
            let s = String(c)
            switch app.keys.active {
            case .picker: app.nav.typed(app.nav.filter + s)
            case .command: app.cmdline += s
            case .menu where app.menuOpen: app.state { MenuState() }.query += s
            default:
                let search = PageSearch.of(app)
                guard search.typing else { return false }
                search.typed(app, search.query + s)
            }
            return true
        }
        /// Run one step and time it (a step that did nothing — typing where the page has no such field — is 0).
        @discardableResult
        func timed(_ s: String, _ act: () -> Bool) -> Double {
            step = s
            let k0 = Date()
            guard act() else { return 0 }
            let k1 = Date()
            host.layoutSubtreeIfNeeded()
            let k2 = Date()
            paint()
            let handle = k1.timeIntervalSince(k0) * 1000, total = k2.timeIntervalSince(k0) * 1000
            let painted = Date().timeIntervalSince(k2) * 1000
            if total > config.budget {
                hits.append(Hit(page: "\(page) → \(app.router.route.path)", pass: pass, step: s, ms: total,
                                what: String(format: "handle %.0f, layout %.0f; paint %.0f", handle, total - handle, painted)))
            }
            last = Date()
            return total
        }
        func press(_ steps: [String]) async -> Double {
            var worst = 0.0
            for s in steps {
                if s.hasPrefix("'") {
                    for c in s.dropFirst() {
                        worst = max(worst, timed("'\(c)") { type(c) })
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                } else if s.hasPrefix("@") {
                    worst = max(worst, timed(s) { app.runner.dispatch(String(s.dropFirst()), via: .key); return true })
                } else {
                    worst = max(worst, timed(s) { for k in s.split(separator: " ") { _ = app.keys.handle(String(k)) }; return true })
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            return worst
        }
        /// Every write the page offers right now, each against what it would act on.
        func writes() -> [String] {
            let live = app.liveScopes()
            return app.registry.order.compactMap { id in
                guard let c = app.registry.command(id), c.write != nil, c.modes.contains(.normal), live.contains(c.scope),
                      let t = app.target(for: c.scope), c.available?(t) ?? true else { return nil }
                return id
            }
        }
        func settle() {
            for _ in 0..<4 { _ = app.keys.handle("esc") }
            app.keys.setMode(.normal)
        }

        Task { @MainActor in
            let t0 = Date()
            while !hello, Date().timeIntervalSince(t0) < 15 { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let pages = config.pages.isEmpty ? defaultPages(app) : config.pages
            for route in pages {
                var worst: [String: Double] = [:]
                @MainActor func open() async {
                    watching = false
                    page = route
                    app.router.navigate(route)
                    draw()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    draw()
                    last = Date()
                    watching = true
                }
                await open()
                pass = "keys"; worst[pass] = await press(script)
                settle()
                if !config.quick {
                    pass = "typing"; worst[pass] = await press(typing)
                    settle()
                }

                pass = "pressure"
                var pouring = true
                let pour = Task { @MainActor in
                    let ids = Array((app.store.raw["branch"] ?? [:]).keys)
                    while pouring, !ids.isEmpty {
                        let id = ids.randomElement()!
                        if let obj = app.store.raw["branch"]?[id],
                           let p = try? Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1, upserts: ["branch": [id: obj]]) {
                            app.store.applyPatch(p)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / patchesPerSecond))
                    }
                }
                worst[pass] = await press(script)
                pouring = false
                _ = await pour.value
                settle()

                pass = "writes"
                var w = 0.0, n = 0
                for id in config.quick ? [] : writes() {
                    await open()
                    w = max(w, timed("@\(id)") { app.runner.dispatch(id, via: .key); return true })
                    n += 1
                    // the blackhole's answer lands and the overlay reconciles: the watchdog times it
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    settle()
                }
                worst[pass] = w
                watching = false
                settle()
                print(String(format: "%-44@ keys %4.0f  typing %4.0f  pressure %4.0f  writes %4.0f (%d)", route as NSString,
                             worst["keys"] ?? 0, worst["typing"] ?? 0, worst["pressure"] ?? 0, w, n))
            }
            print("bench: \(Blackhole.answered) writes answered here, none sent")
            let over = hits.sorted { $0.ms > $1.ms }
            print(over.isEmpty ? "bench: every key under \(Int(config.budget))ms" : "bench: \(over.count) over \(Int(config.budget))ms")
            for h in over.prefix(60) {
                print(String(format: "  %6.0fms  %-8@ %-28@ %-34@ %@", h.ms, h.pass as NSString, h.step as NSString, h.what as NSString, h.page))
            }
            exit(over.isEmpty && hello ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Every top-level page, the first focus forest, and three focus branches with a PR (the reviews Phil reads).
    static func defaultPages(_ app: AppModel) -> [String] {
        var out = ["/v2", "/v2/todo", "/v2/machine", "/v2/dashboard", "/v2/wiki", "/v2/tutor", "/v2/keytutor"]
        let m = app.forestModel
        let focus = m.projects().focus
        if let p = focus.first { out.append("/v2/p/\(p.repo)/\(p.name)") }
        let reviews = focus.lazy.compactMap { p in m.forest(p.id).map { (p, $0) } }.flatMap { p, f in
            f.branches.lazy.filter { $0.pr != nil && $0.st.ship != .landed }.map { "/v2/b/\(p.repo)/\($0.b.name)" }
        }
        out += reviews.prefix(3)
        return out
    }
}

/// The bench's server for everything but reads: any request that isn't a GET is answered
/// `{"ok": true}` after a moment, here, so a write the bench presses changes nothing real.
final class Blackhole: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answered = 0

    override class func canInit(with request: URLRequest) -> Bool { (request.httpMethod ?? "GET") != "GET" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.answered += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok": true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
