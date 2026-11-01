import Foundation

/// An address names a place, not just a page (NAV.md §4.4): a jumplist entry written out, so a link
/// from outside lands where `C-o` would. The page's own path, then where on it:
///   `?file=<path>`             a file of the review page's diff
///   `?file=<path>&line=<n>`    its line on the tip's side (beside the diff when the diff hasn't it)
///   `&sha=<commit>`            …at another commit, beside the diff
///   `?thread=<id>`             a conversation
///   `?tab=<face>`              the page's other face (the review page's commits, a forest's story)
///   `?at=<row key>`            any other row (`b:loops:x` on a forest)
extension Place {
    public init(address: String) {
        let q = Route.query(address)
        self.init(route: Route(address), tab: q["tab"])
        let repo: String
        switch route {
        case .review(let r, _, _), .forest(let r, _): repo = r
        default: repo = ""
        }
        if let f = q["file"], !f.isEmpty {
            if let n = q["line"].flatMap(Int.init) {
                loc = Loc(repo: repo, sha: q["sha"] ?? "", path: f, line: n)
            } else {
                cursorKey = "f|\(f)"
            }
        } else if let t = q["thread"], !t.isEmpty {
            cursorKey = "t|\(t)"
        } else if let a = q["at"], !a.isEmpty {
            cursorKey = a
        }
    }

    /// The place as an address `Place(address:)` reads back. A code place on the tip is its line; one
    /// at another commit says which.
    public var address: String {
        var items: [URLQueryItem] = []
        if let l = loc {
            items = [URLQueryItem(name: "file", value: l.path), URLQueryItem(name: "line", value: String(l.line))]
            if l.diffKey == nil, !l.sha.isEmpty { items.append(URLQueryItem(name: "sha", value: l.sha)) }
        } else if let k = cursorKey {
            if k.hasPrefix("f|") { items = [URLQueryItem(name: "file", value: String(k.dropFirst(2)))] }
            else if k.hasPrefix("t|") { items = [URLQueryItem(name: "thread", value: String(k.dropFirst(2)))] }
            else { items = [URLQueryItem(name: "at", value: k)] }
        }
        if let t = tab, t != Place.firstFace { items.insert(URLQueryItem(name: "tab", value: t), at: 0) }
        guard !items.isEmpty else { return route.path }
        var c = URLComponents()
        c.queryItems = items
        let q = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return route.path + (route.path.contains("?") ? "&" : "?") + q
    }

    /// The face a page opens on, which an address leaves unsaid.
    static let firstFace = "files"

    /// `canopy://…`: the address as a link other apps open canopy with.
    public var link: String { "canopy:/" + address }
}
