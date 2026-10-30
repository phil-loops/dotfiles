import Foundation

/// What the server injects into the web app's page (stack-review-server.py): the repos it serves,
/// your keys.toml overrides, and the build signature. The native app reads the same script out of
/// GET /v2 so keys and repos come from one source; the asset signature also moves when keys.toml
/// is saved, which is how an open app learns to re-apply keys (the `asset` event).
public struct Bootstrap: Equatable, Sendable {
    public var repos: [String]
    public var keys: [String: [String]]
    public var keyErrors: [String]
    public var asset: String

    public init(repos: [String] = [], keys: [String: [String]] = [:], keyErrors: [String] = [], asset: String = "") {
        self.repos = repos; self.keys = keys; self.keyErrors = keyErrors; self.asset = asset
    }

    private struct Keys: Decodable { var keys: [String: [String]]?; var errors: [String]? }

    /// Parse the injected `<script>window.__VIEWER_REPOS__=…;window.__CANOPY_KEYS__=…;window.__CANOPY_ASSET__=…</script>`.
    public static func parse(html: String) -> Bootstrap? {
        func value(_ name: String) -> String? {
            guard let start = html.range(of: "window.\(name)=") else { return nil }
            let rest = html[start.upperBound...]
            let end = rest.range(of: ";window.") ?? rest.range(of: "</script>")
            return end.map { String(rest[..<$0.lowerBound]) }
        }
        guard let reposJSON = value("__VIEWER_REPOS__") else { return nil }
        let d = JSONDecoder()
        var b = Bootstrap()
        b.repos = (try? d.decode([String].self, from: Data(reposJSON.utf8))) ?? []
        if let k = value("__CANOPY_KEYS__"), let keys = try? d.decode(Keys.self, from: Data(k.utf8)) {
            b.keys = keys.keys ?? [:]
            b.keyErrors = keys.errors ?? []
        }
        if let a = value("__CANOPY_ASSET__") { b.asset = (try? d.decode(String.self, from: Data(a.utf8))) ?? "" }
        return b
    }

    public static func fetch(_ t: Transport) async throws -> Bootstrap {
        guard let html = await t.getText("/v2"), let b = parse(html: html) else {
            throw HTTPError(path: "/v2 (bootstrap script)", status: 0)
        }
        return b
    }
}

/// The keys files. `keys.toml` is shared with v2 (which keys it by command id; the server injects
/// it, and this reads it directly only when the bootstrap can't be read). `keys-native.toml` is
/// this app's own: verb → keys. v2 never reads it — the server's keymap.py loads keys.toml alone and
/// would report a `[native]` table there as "native: wants a key or a list of keys" atop v2's `?`.
/// Both have one shape — `"id" = "key"` or `"id" = ["k", …]` — the same validation as srv/keymap.py.
public enum KeysToml {
    public static let path = NSString(string: "~/.dotfiles/canopy/keys.toml").expandingTildeInPath
    public static let nativePath = NSString(string: "~/.dotfiles/canopy/keys-native.toml").expandingTildeInPath

    public static func load(path: String = path) -> (keys: [String: [String]], errors: [String]) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ([:], []) }
        return parse(text)
    }

    public static func parse(_ text: String) -> (keys: [String: [String]], errors: [String]) {
        var keys: [String: [String]] = [:]
        var errors: [String] = []
        for raw in text.split(separator: "\n") {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else { errors.append("keys.toml: can't read \(line)"); continue }
            let id = unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("[") && v.hasSuffix("]") {
                let inner = v.dropFirst().dropLast()
                let items = strings(in: String(inner))
                if items == nil { errors.append("\(id): wants a key or a list of keys"); continue }
                keys[id] = items!.filter { !$0.isEmpty }
            } else if let s = strings(in: v), s.count == 1 {
                keys[id] = s.filter { !$0.isEmpty }
            } else {
                errors.append("\(id): wants a key or a list of keys")
            }
        }
        return (keys, errors)
    }

    private static func stripComment(_ s: String) -> String {
        var inQuote = false
        for (i, c) in s.enumerated() {
            if c == "\"" { inQuote.toggle() }
            if c == "#" && !inQuote { return String(s.prefix(i)) }
        }
        return s
    }

    private static func unquote(_ s: String) -> String {
        s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 ? String(s.dropFirst().dropLast()) : s
    }

    /// The quoted strings in a comma list, or nil when something else is there.
    private static func strings(in s: String) -> [String]? {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var escaped = false
        for c in s {
            if inQuote {
                if escaped { cur.append(c); escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inQuote = false; out.append(cur); cur = "" }
                else { cur.append(c) }
            } else if c == "\"" {
                inQuote = true
            } else if c != "," && !c.isWhitespace {
                return nil
            }
        }
        return inQuote ? nil : out
    }
}
