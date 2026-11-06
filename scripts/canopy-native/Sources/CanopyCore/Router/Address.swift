import Foundation

/// An address names a place, not just a page (NAV.md §4.4): a jumplist entry written out, so a link
/// from outside lands where `C-o` would. The page's own path, then where on it:
///   `?file=<path>`             a file of the review page's diff
///   `?file=<path>&line=<n>`    its line on the tip's side (in the focused window as the file when the diff hasn't it)
///   `&sha=<commit>`            …at another commit, as the file
///   `?thread=<id>`             a conversation
///   `?tab=<face>`              the page's other face (the review page's commits, a forest's story)
///   `&commit=<sha>`            the one commit the review page shows
///   `?at=<row key>`            any other row (`b:loops:x` on a forest)
///   `&row=<n>`                 the cursor's height on screen, in lines from the top
///   `&win=<id>,<col>[,<line>,<sha>,<path>]`  one per window of a saved window set (the diff's has no file)
///   `&in=<id>`                 with a window set: the window the keyboard is in
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
        row = q["row"].flatMap(Int.init)
        commit = q["commit"].flatMap { $0.isEmpty ? nil : $0 }
        let wins = Self.allValues("win", in: address).compactMap { Self.window($0, repo: repo) }
        if !wins.isEmpty {
            windows = wins
            window = q["in"].flatMap(Int.init)
        }
    }

    /// Every value a repeated query item carries, in order (`Route.query` keeps the last).
    private static func allValues(_ name: String, in address: String) -> [String] {
        guard let q = address.split(separator: "?", maxSplits: 1).dropFirst().first else { return [] }
        return (URLComponents(string: "?" + q)?.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
    }

    private static func window(_ v: String, repo: String) -> WindowSpec? {
        let f = v.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 2 || f.count == 5, let id = Int(f[0]), let col = Int(f[1]) else { return nil }
        guard f.count == 5 else { return WindowSpec(id: id, column: col) }
        guard let line = Int(f[2]), !f[4].isEmpty else { return nil }
        return WindowSpec(id: id, column: col, file: Loc(repo: repo, sha: f[3], path: f[4], line: line, asFile: true))
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
        if let c = commit { items.append(URLQueryItem(name: "commit", value: c)) }
        if let r = row { items.append(URLQueryItem(name: "row", value: String(r))) }
        for w in windows ?? [] {
            let v = w.file.map { "\(w.id),\(w.column),\($0.line),\($0.sha),\($0.path)" } ?? "\(w.id),\(w.column)"
            items.append(URLQueryItem(name: "win", value: v))
        }
        if windows != nil, let w = window { items.append(URLQueryItem(name: "in", value: String(w))) }
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
