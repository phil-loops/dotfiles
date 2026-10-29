import Foundation

/// One surface of the app — a port of router.ts SURFACES. `id` is the surface id the registry's
/// scopes, telemetry and the `nav.<id>` commands use.
public struct Surface: Hashable, Sendable {
    public var id: String
    public var path: String
    public var title: String
    /// the path is a prefix: what follows is the surface's argument
    public var arg: Bool = false
    /// with `arg`: the path alone is the surface too (the wiki's first page, the tutor's home)
    public var bare: Bool = false

    public static let base = "/v2"
    public static let all: [Surface] = [
        Surface(id: "forests", path: base, title: "Forests"),
        Surface(id: "dashboard", path: "\(base)/dashboard", title: "Dashboard"),
        Surface(id: "review", path: "\(base)/b", title: "Review", arg: true),
        Surface(id: "todo", path: "\(base)/todo", title: "Todo"),
        Surface(id: "forest", path: "\(base)/p", title: "Forest", arg: true),
        Surface(id: "machine", path: "\(base)/machine", title: "Machine"),
        Surface(id: "wiki", path: "\(base)/wiki", title: "Wiki", arg: true, bare: true),
        Surface(id: "tutor", path: "\(base)/tutor", title: "Tutor", arg: true, bare: true),
    ]

    public static func named(_ id: String) -> Surface { all.first { $0.id == id } ?? all[0] }
}

/// Every v2 address, typed. Parsing follows router.ts exactly: an unknown path is the forests home.
public enum Route: Hashable, Sendable {
    case forests
    case dashboard
    case todo
    case machine
    /// /v2/p/<repo>/<project>
    case forest(repo: String, project: String)
    /// /v2/b/<repo>/<branch> — the branch keeps its slashes; `base` is the review page's ?base=
    /// ("" parent, "main", "outgoing"), the one query param a v2 address carries.
    case review(repo: String, branch: String, base: String = "")
    /// /v2/wiki[/<slug>]
    case wiki(slug: String?)
    /// /v2/tutor[/<session>]
    case tutor(session: String?)

    public var surface: Surface {
        switch self {
        case .forests: return .named("forests")
        case .dashboard: return .named("dashboard")
        case .todo: return .named("todo")
        case .machine: return .named("machine")
        case .forest: return .named("forest")
        case .review: return .named("review")
        case .wiki: return .named("wiki")
        case .tutor: return .named("tutor")
        }
    }

    public var surfaceID: String { surface.id }

    /// router.ts routeArg(): on the review page "<repo>/<branch>", on a forest "<repo>/<project>".
    public var arg: String {
        switch self {
        case .forest(let r, let p): return "\(r)/\(p)"
        case .review(let r, let b, _): return "\(r)/\(b)"
        case .wiki(let s): return s ?? ""
        case .tutor(let s): return s ?? ""
        default: return ""
        }
    }

    /// The address, encoded as router.ts builds it (forestPath, reviewPath, wikiPath, tutorPath).
    public var path: String {
        let b = Surface.base
        switch self {
        case .forests: return b
        case .dashboard: return "\(b)/dashboard"
        case .todo: return "\(b)/todo"
        case .machine: return "\(b)/machine"
        case .forest(let r, let p): return "\(b)/p/\(r.uriComponent)/\(p.uriComponent)"
        case .review(let r, let br, let base):
            let tail = br.split(separator: "/", omittingEmptySubsequences: false).map { String($0).uriComponent }.joined(separator: "/")
            return "\(b)/b/\(r.uriComponent)/\(tail)" + (base.isEmpty ? "" : "?base=\(base.uriComponent)")
        case .wiki(let s): return s.map { "\(b)/wiki/\($0.uriComponent)" } ?? "\(b)/wiki"
        case .tutor(let s): return s.map { "\(b)/tutor/\($0.uriComponent)" } ?? "\(b)/tutor"
        }
    }

    /// Parse a v2 path ("/v2/b/loops/x?base=main"), a full http URL, or a `canopy://` deep link
    /// (`canopy://v2/b/loops/x`, `canopy:///v2/b/loops/x`, `canopy://open?path=/v2/...`).
    public init(_ address: String) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("canopy:") || s.hasPrefix("http://") || s.hasPrefix("https://"), let u = URLComponents(string: s) {
            if u.scheme == "canopy", u.host == "open", let p = u.queryItems?.first(where: { $0.name == "path" })?.value {
                s = p
            } else {
                let host = u.scheme == "canopy" ? (u.host.flatMap { $0.isEmpty ? nil : "/\($0)" } ?? "") : ""
                s = host + u.percentEncodedPath + (u.percentEncodedQuery.map { "?\($0)" } ?? "")
            }
        }
        var query = ""
        if let q = s.firstIndex(of: "?") {
            query = String(s[s.index(after: q)...])
            s = String(s[..<q])
        }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        self = Route.match(path: s, query: query)
    }

    private static func match(path pathname: String, query: String) -> Route {
        var p = pathname
        while p.hasSuffix("/") { p.removeLast() }
        let hit = Surface.all.first { s in
            s.arg ? (p.hasPrefix(s.path + "/") || (s.bare && s.path == p)) : s.path == p
        } ?? Surface.all[0]
        let arg = hit.arg && p.count > hit.path.count ? (String(p.dropFirst(hit.path.count + 1)).removingPercentEncoding ?? "") : ""
        switch hit.id {
        case "dashboard": return .dashboard
        case "todo": return .todo
        case "machine": return .machine
        case "wiki": return .wiki(slug: arg.isEmpty ? nil : arg)
        case "tutor": return .tutor(session: arg.isEmpty ? nil : arg)
        case "forest", "review":
            // decodeURIComponent of the whole tail, then cut at the first "/" (model.ts pageProject)
            guard let cut = arg.firstIndex(of: "/"), cut != arg.startIndex else { return hit.id == "forest" ? .forest(repo: "", project: "") : .review(repo: "", branch: "") }
            let repo = String(arg[..<cut]), rest = String(arg[arg.index(after: cut)...])
            if hit.id == "forest" { return .forest(repo: repo, project: rest) }
            let base = URLComponents(string: "?\(query)")?.queryItems?.first { $0.name == "base" }?.value ?? ""
            return .review(repo: repo, branch: rest, base: base == "main" || base == "outgoing" ? base : "")
        default: return .forests
        }
    }

    // ── review-page helpers (router.ts) ──

    /// A forest's whole diff against main reads like a branch on the review page.
    public static func integrationRef(_ project: String) -> String { "refs/stack/\(project)-integration" }

    /// The forest a review page's ref integrates, or nil for a real branch.
    public static func integrationOf(_ name: String) -> String? {
        guard name.hasPrefix("refs/stack/"), name.hasSuffix("-integration") else { return nil }
        let mid = name.dropFirst("refs/stack/".count).dropLast("-integration".count)
        return mid.isEmpty ? nil : String(mid)
    }

    /// The project id ("<repo>:<project>") a forest route addresses.
    public var projectID: String? {
        if case .forest(let r, let p) = self, !r.isEmpty { return "\(r):\(p)" }
        return nil
    }

    /// The branch id ("<repo>:<branch>") a review route addresses.
    public var branchID: String? {
        if case .review(let r, let b, _) = self, !r.isEmpty { return "\(r):\(b)" }
        return nil
    }
}
