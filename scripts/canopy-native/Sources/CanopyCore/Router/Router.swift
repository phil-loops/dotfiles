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
    /// The query of the address that brought you here (`navigate(_ address:)`, a deep link, the
    /// launch address); any other move clears it. A page reads it on arrival with `takeQuery`.
    public private(set) var query: [String: String] = [:]
    @ObservationIgnored public var onNavigate: ((_ from: Route, _ to: Route) -> Void)?
    /// Called before a `navigate` (a new history entry) leaves `from` — the jumplist records it there.
    @ObservationIgnored public var willNavigate: ((_ from: Route, _ to: Route) -> Void)?
    /// While this says why not (esc is cancelling: NAV.md §4.5), no route change happens at all;
    /// `onBlocked` hears about the attempt.
    @ObservationIgnored public var blocked: (() -> String?)?
    @ObservationIgnored public var onBlocked: ((_ to: Route, _ why: String) -> Void)?

    public init(_ route: Route = .forests, query: [String: String] = [:]) { self.route = route; self.query = query }

    /// The arrival query, once: reading it clears it, so a re-render doesn't act on it twice.
    public func takeQuery() -> [String: String] {
        defer { if !query.isEmpty { query = [:] } }
        return query
    }

    public var surface: Surface { route.surface }

    /// Go somewhere new (history.pushState). Going where you already are does nothing.
    public func navigate(_ to: Route) {
        guard to != route, allowed(to) else { return }
        query = [:]
        let from = route
        willNavigate?(from, to)
        back.append(from)
        if back.count > 200 { back.removeFirst(back.count - 200) }
        forward = []
        route = to
        onNavigate?(from, to)
    }

    private func allowed(_ to: Route) -> Bool {
        guard let why = blocked?() else { return true }
        onBlocked?(to, why)
        return false
    }

    /// Go to an address, keeping its query for the page (`query`), even when the route is where you are.
    public func navigate(_ address: String) {
        let to = Route(address)
        navigate(to)
        if route == to { query = Route.query(address) }
    }

    /// Change the address without a history entry (history.replaceState: the review page's ?base=).
    public func replace(_ to: Route) {
        guard to != route, allowed(to) else { return }
        query = [:]
        let from = route
        route = to
        onNavigate?(from, to)
    }

    @discardableResult
    public func goBack() -> Bool {
        guard let to = back.last, allowed(to) else { return false }
        query = [:]
        back.removeLast()
        let from = route
        forward.append(from)
        route = to
        onNavigate?(from, to)
        return true
    }

    @discardableResult
    public func goForward() -> Bool {
        guard let to = forward.last, allowed(to) else { return false }
        query = [:]
        forward.removeLast()
        let from = route
        back.append(from)
        route = to
        onNavigate?(from, to)
        return true
    }
}
