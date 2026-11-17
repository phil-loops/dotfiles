import AppKit
import CanopyCore
import SwiftUI

/// Validate a capture plan, hydrate its source, and write completed offscreen PNG artifacts.
/// Captures refuse server writes, terminal input, external application opens and persistent edits.
@MainActor
public enum Shoot {
    public static func run(_ config: AppConfig) -> Never {
        let plan: CapturePlan
        let output: CaptureOutput
        let fixture: CaptureFixture
        do {
            plan = try CapturePlan(config)
            fixture = try CaptureFixture(directory: config.shootFixture)
            output = try CaptureOutput(config.shootDir)
        } catch { fail(error, code: 2) }
        Log.quiet = true
        Log.persists = false
        Fonts.register()
        NSApplication.shared.setActivationPolicy(.prohibited)
        CaptureFixtureProtocol.install(fixture, port: 1)
        let app = AppModel(config: config, port: 1, telemetry: false, protocolClasses: [CaptureFixtureProtocol.self])
        CaptureSession.configure(app)
        var hello = false
        var hydrated = false
        let counted = app.stream.count
        app.stream.count = { name, ms in
            counted?(name, ms)
            if name == "state" { hydrated = true }
        }
        app.stream.onFrame = { f in if f.event == "hello" { hello = true } }
        app.start()
        let size = NSSize(width: config.shootWidth, height: config.shootHeight)
        Task { @MainActor in
            do {
                let start = Date()
                while !(hello && hydrated && app.store.ready), Date().timeIntervalSince(start) < 15 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard hello, hydrated, app.store.ready else {
                    app.stream.stop()
                    fail(Refusal("initial state or stream hello unavailable after 15s; no images written"), code: 1)
                }
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: config.appearance == "light" ? .aqua : .darkAqua)
                app.open(address: plan.shots[0].address)
                let host = NSHostingView(rootView: AnyView(RootView().environment(app)
                    .preferredColorScheme(config.appearance == "light" ? .light : .dark)))
                host.frame = NSRect(origin: .zero, size: size)
                host.sizingOptions = []
                window.contentView = host
                window.orderBack(nil)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                func draw(_ name: String) throws {
                    host.layoutSubtreeIfNeeded()
                    try CaptureFixtureProtocol.requireComplete(port: 1)
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Refusal("capture bitmap allocation failed") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let url = try output.writePNG(bitmap.representation(using: .png, properties: [:]), named: name)
                    print(url.path)
                }
                for shot in plan.shots {
                    app.open(address: shot.address)
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    for action in shot.actions {
                        switch action {
                        case .key(let key): _ = app.keys.handle(key)
                        case .wait(let delay): try await Task.sleep(nanoseconds: delay)
                        case .draw(let name): try draw(name)
                        case .state:
                            let pg = ReviewPageState.of(app)
                            print("state: cursor=\(pg.here?.key ?? "nil") note=\(app.runner.note ?? "-") pop=\(CodeLookup.of(app).pop?.text ?? "-") pane=\(app.pane?.id ?? "nil") window=\(NSStringFromSize(size))")
                        case .terminalState: print("screen: terminal unavailable during capture")
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    try await Task.sleep(nanoseconds: plan.settle)
                    try draw(shot.name)
                    _ = app.keys.handle("esc")
                }
                app.stream.stop()
                exit(0)
            } catch {
                app.stream.stop()
                fail(error, code: 2)
            }
        }
        RunLoop.main.run()
        fail(Refusal("capture run loop ended before completion"), code: 2)
    }

    private static func fail(_ error: any Error, code: Int32) -> Never {
        FileHandle.standardError.write(Data("shoot: \(error)\n".utf8))
        exit(code)
    }
}
