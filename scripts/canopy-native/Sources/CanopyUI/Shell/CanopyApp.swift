import AppKit
import CanopyCore
import SwiftUI

/// The app. `Canopy` (the executable) calls `CanopyApp.launch(config)`; a `--dump` run never gets
/// here (see Dump).
public struct CanopyApp: App {
    nonisolated(unsafe) static var config = AppConfig()
    @State private var model: AppModel
    private let monitor: KeyMonitor

    @MainActor
    public static func launch(_ config: AppConfig) {
        Self.config = config
        main()
    }

    @MainActor
    public init() {
        Fonts.register()
        NSApplication.shared.setActivationPolicy(.regular)
        let c = Self.config
        let port = c.resolvedPort() ?? 0
        if port == 0 { Log.line("no server port: pass --port, or --repo with a running `stack web`") }
        let m = AppModel(config: c, port: port)
        Log.line("canopy-native up · port \(port) · route \(c.route.path) · \(m.registry.commands.count) commands · areas \(m.installed.joined(separator: ","))")
        var frames = 0
        m.stream.onFrame = { f in
            frames += 1
            if f.event == "patch", let j = f.json {
                Log.line("patch \(j["domain"]?.string ?? "?") v\(j["version"]?.int ?? 0) (\(frames) frames)")
            } else if f.event != "patch" {
                Log.line("event \(f.event) \(f.data.prefix(160))")
            }
        }
        _ = m.store.onChange { [weak m] in
            guard let m, frames == 0 else { return }
            Log.line("hydrated: \(m.store.counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))")
        }
        m.start()
        _model = State(initialValue: m)
        monitor = KeyMonitor(app: m)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public var body: some Scene {
        Window("canopy", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
                .preferredColorScheme(scheme)
                .onAppear { monitor.install() }
                .onOpenURL { url in model.router.navigate(url.absoluteString) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.telemetry.flushPage(route: model.router.route.path)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                Button("Back") { model.runner.dispatch("route.back", via: .menu) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.runner.dispatch("route.forward", via: .menu) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Command Menu") { model.menuOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Resync") { model.stream.resync() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private var scheme: ColorScheme? {
        switch Self.config.appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }
}
