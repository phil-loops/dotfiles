import Foundation
import Observation

/// The one way the app changes surface (router.ts), with the browser's back/forward stacks.
/// Every navigation calls `onNavigate` — telemetry's `nav` event hangs there.
@MainActor
@Observable
public final class Router {
    public private(set) var route: Route
    public private(set) var back: [Route] = []
    public private(set) var forward: [Route] = []
    @ObservationIgnored public var onNavigate: ((_ from: Route, _ to: Route) -> Void)?

    public init(_ route: Route = .forests) { self.route = route }

    public var surface: Surface { route.surface }

    /// Go somewhere new (history.pushState). Going where you already are does nothing.
    public func navigate(_ to: Route) {
        guard to != route else { return }
        let from = route
        back.append(from)
        if back.count > 200 { back.removeFirst(back.count - 200) }
        forward = []
        route = to
        onNavigate?(from, to)
    }

    public func navigate(_ address: String) { navigate(Route(address)) }

    /// Change the address without a history entry (history.replaceState: the review page's ?base=).
    public func replace(_ to: Route) {
        guard to != route else { return }
        let from = route
        route = to
        onNavigate?(from, to)
    }

    @discardableResult
    public func goBack() -> Bool {
        guard let to = back.popLast() else { return false }
        let from = route
        forward.append(from)
        route = to
        onNavigate?(from, to)
        return true
    }

    @discardableResult
    public func goForward() -> Bool {
        guard let to = forward.popLast() else { return false }
        let from = route
        back.append(from)
        route = to
        onNavigate?(from, to)
        return true
    }
}
