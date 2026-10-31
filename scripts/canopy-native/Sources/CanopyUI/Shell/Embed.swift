import AppKit
import CanopyCore
import SwiftUI

/// Canopy inside another app's window (Show's Canopy workspace): one AppModel on a repo's server,
/// its pages in `view`, and its keys only while `isActive` says the host is showing it — the host's
/// ⌘ shortcuts are never canopy's, so they reach the host's menu as before.
@MainActor
public final class CanopyEmbed {
    public let view: NSView
    private let model: AppModel
    private let monitor: KeyMonitor

    /// nil when the repo's server isn't answering; the host starts one and asks again.
    public init?(repo: String = "~/coding/loops", route: String? = nil, isActive: @escaping () -> Bool) {
        var c = AppConfig()
        c.repo = repo
        guard let port = c.resolvedPort(), Self.answers(port) else { return nil }
        Fonts.register()
        let m = AppModel(config: c, port: port)
        m.start()
        if let route { m.router.navigate(route) }
        model = m
        let host = NSHostingView(rootView: AnyView(RootView().environment(m).preferredColorScheme(.dark)))
        view = host
        monitor = KeyMonitor(app: m) { [weak host] e in isActive() && e.window != nil && e.window === host?.window }
        monitor.install()
    }

    public func navigate(_ route: String) { model.router.navigate(route) }

    /// Whether the forest viewer answers on `port`.
    public nonisolated static func answers(_ port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/sig") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, r, _ in
            ok = (r as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 1.5)
        return ok
    }
}
