import Foundation

/// A command as the key rules see it, in one mode.
public struct Bound: Equatable, Sendable {
    public var id: String
    public var scope: String
    public var keys: [String]
    public var modes: [String]
    /// the verbs it implements
    public var verbs: [String]
    /// its keys that sit under the page's leader
    public var local: [String]
    public init(id: String, scope: String, keys: [String], modes: [String] = ["normal"], verbs: [String] = [], local: [String] = []) {
        self.id = id; self.scope = scope; self.keys = keys; self.modes = modes; self.verbs = verbs; self.local = local
    }
}

/// The key rules (bindings.ts, rebuilt around verbs). A key means one thing everywhere because the
/// verb table gives each key one verb; what's left to check is the table itself (after keys.toml),
/// each page's leader namespace, and that nothing is bound twice in one place. Pure.
public enum Bindings {
    private static let named: Set<String> = ["space", "esc", "ret", "tab", "up", "down", "left", "right"]

    public static func validKey(_ k: String) -> Bool {
        k.split(separator: " ", omittingEmptySubsequences: false).allSatisfy { tok in
            var t = Substring(tok)
            if t.count > 2, t.hasPrefix("C-") || t.hasPrefix("A-") { t = t.dropFirst(2) }
            return t.count == 1 || named.contains(String(t))
        }
    }

    /// keys.toml over the verb table: an entry names a verb (`mark = "v"`). v2's command-id entries
    /// (`"review.viewed" = "v"`) are read past with a warning naming the verb to set instead.
    public static func applyVerbKeys(_ overrides: [String: [String]], commands: [String: [Verb]])
        -> (keys: VerbKeys, customized: Set<Verb>, problems: [String], warnings: [String])
    {
        var vk = VerbKeys.defaults
        var customized = Set<Verb>()
        var problems: [String] = []
        var warnings: [String] = []
        for (name, keys) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let verb = Verb(rawValue: name) else {
                if let verbs = commands[name] {
                    let to = verbs.first.map { "set `\($0.rawValue) = …` instead (every page doing it follows)" } ?? "it has no verb; its key is the page's own"
                    warnings.append("\(name): keys belong to verbs now, so this command-id line is ignored — \(to)")
                } else if name.contains(".") {
                    warnings.append("\(name): a command id (v2's), ignored here — keys belong to verbs")
                } else {
                    problems.append("\(name): no such verb")
                }
                continue
            }
            let bad = keys.filter { !validKey($0) }
            if !bad.isEmpty { problems.append("\(name): not a key — \(bad.map { "\"\($0)\"" }.joined(separator: ", "))") }
            let good = keys.filter(validKey)
            if verb.spec.native { problems.append("\(name): the text field does it; it can't move"); continue }
            if verb.spec.tier == .insert {
                vk.entry[verb] = good
                vk.keys[verb] = good.filter { $0 != "ret" }
            } else {
                vk.keys[verb] = good
            }
            customized.insert(verb)
        }
        return (vk, customized, problems, warnings)
    }

    /// The table's own rule: within each mode class a key (or a chord's prefix) belongs to one verb.
    /// The leader is a verb like any other, so nothing can sit on it. Checked again after keys.toml.
    public static func tableProblems(_ vk: VerbKeys) -> [String] {
        var out: [String] = []
        for (cls, table) in [("", vk.keys), ("text entry: ", vk.entry)] {
            var owner: [String: Verb] = [:]
            for v in Verb.allCases {
                for k in table[v] ?? [] {
                    if let o = owner[k], o != v { out.append("\(cls)\(k): \(o.rawValue) and \(v.rawValue)") } else { owner[k] = v }
                }
            }
            let keys = owner.keys.sorted()
            for k in keys {
                for p in keys where p != k && k.hasPrefix(p + " ") {
                    out.append("\(cls)\(p) (\(owner[p]!.rawValue)) swallows \(k) (\(owner[k]!.rawValue))")
                }
            }
        }
        return out
    }

    /// What the commands do with the table, checked within each mode: a key bound twice in one
    /// scope, a scope on no page, a page's leader namespace with a key twice or a key that swallows
    /// another (`, b` and `, b p`), and insert mode growing past its fixed set (send; esc is the engine's).
    public static func clashes(_ cmds: [Bound], surfaceScopes: [String: [String]]) -> [String] {
        let modes = Array(Set(cmds.flatMap(\.modes))).sorted { $0 == "normal" ? true : $1 == "normal" ? false : $0 < $1 }
        var out = cmds.filter { $0.modes.contains("insert") && !$0.keys.isEmpty && (!$0.local.isEmpty || $0.verbs.contains { $0 != Verb.send.rawValue }) }
            .map { "insert: \($0.id) adds to the fixed set (esc stops, ⌃↵ sends, ⌥↵ newline)" }
        out += cmds.filter { $0.verbs.contains { Verb(rawValue: $0)?.spec.native == true } }.map { "\($0.id): the text field does that itself" }
        out += modes.flatMap { m in
            clashesInMode(cmds.filter { $0.modes.contains(m) }, surfaceScopes: surfaceScopes).map { m == "normal" ? $0 : "\(m): \($0)" }
        }
        return out
    }

    static func clashesInMode(_ cmds: [Bound], surfaceScopes: [String: [String]]) -> [String] {
        let surfaces = surfaceScopes.sorted { $0.key < $1.key }
        var out: [String] = []
        var inScope: [String: [String]] = [:]
        var scopeOrder: [String] = []
        var leaderKeys: [String: [String: [String]]] = [:]
        var noPage = Set<String>()
        for c in cmds {
            let pages = surfaces.filter { c.scope == "global" || $0.value.contains(c.scope) }.map(\.key)
            if pages.isEmpty, !c.keys.isEmpty, noPage.insert(c.id).inserted { out.append("\(c.id): scope \(c.scope) is on no page") }
            for key in c.keys {
                let here = "\(c.scope) \(key)"
                if inScope[here] == nil { scopeOrder.append(here) }
                if !(inScope[here]?.contains(c.id) ?? false) { inScope[here, default: []].append(c.id) }
                if c.local.contains(key) {
                    for p in pages where !(leaderKeys[p]?[key]?.contains(c.id) ?? false) { leaderKeys[p, default: [:]][key, default: []].append(c.id) }
                }
            }
        }
        for here in scopeOrder {
            let ids = inScope[here]!
            if ids.count > 1 { out.append("\(here.split(separator: " ").dropFirst().joined(separator: " ")): \(ids.joined(separator: " and ")) in one place") }
        }
        for (page, keys) in leaderKeys.sorted(by: { $0.key < $1.key }) {
            let sorted = keys.sorted { $0.key < $1.key }
            for (key, ids) in sorted {
                if ids.count > 1 { out.append("\(page): \(key) is \(ids.joined(separator: " and "))") }
                for (other, oids) in sorted where other.hasPrefix(key + " ") {
                    out.append("\(page): \(key) (\(ids[0])) swallows \(other) (\(oids[0]))")
                }
            }
        }
        return out
    }
}
