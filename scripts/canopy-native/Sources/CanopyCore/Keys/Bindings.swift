import Foundation

/// A command as the key rules see it.
public struct Bound: Equatable, Sendable {
    public var id: String
    public var scope: String
    public var keys: [String]
    public var modes: [String]
    /// key → the verb it means here (its raw name), or `leaderMeaning` for a key under the page's leader
    public var meaning: [String: String]
    public static let leaderMeaning = "(leader)"
    public init(id: String, scope: String, keys: [String], modes: [String] = ["normal"], meaning: [String: String] = [:]) {
        self.id = id; self.scope = scope; self.keys = keys; self.modes = modes; self.meaning = meaning
    }
}

/// Your keys over the defaults, and the one rule they must keep: a key means one thing on every
/// page (bindings.ts). Pure.
public enum Bindings {
    /// Transitional: commands not yet on verbs, grouped under the verb they'll become.
    public static let sameMove: [String: [String]] = [
        "next": ["cursor.down", "review.down", "history.next"],
        "previous": ["cursor.up", "review.up", "history.prev"],
        "cancel": ["overlay.close", "review.back", "history.exit", "commit.exit", "wiki.back", "tutor.back"],
        "out": ["forest.collapse", "review.leave", "forest.leave", "commit.back", "machine.log.close", "tutor.home"],
        "in": ["forest.expand", "branch.open", "history.enter", "machine.log", "review.in"],
        "main": ["row.primary", "review.fold", "todo.open", "review.expand", "history.open", "machine.open", "wiki.open", "tutor.concept", "tutor.open", "pane.open", "tutor.concept.show"],
        "push": ["branch.push", "review.send", "review.push"],
        "move-up": ["focus.up", "todo.up"],
        "move-down": ["focus.down", "todo.down"],
        "put-away": ["project.archive", "todo.drop", "machine.kill", "tutor.forget", "tutor.evidence.cut"],
        "words": ["review.words", "forest.words", "story.why"],
        "face": ["review.tab", "forest.face", "machine.log.jobs"],
        "github": ["branch.pr", "review.finish"],
        "preview": ["branch.preview", "review.preview", "forest.preview"],
        "sync": ["branch.sync", "review.sync"],
        "map": ["review.map", "tutor.map"],
        "type": ["review.types", "tutor.types"],
        "definition": ["review.definition", "tutor.definition"],
        "type-definition": ["review.type-definition", "tutor.type-definition"],
        "implementations": ["review.implementation", "tutor.implementation"],
        "references": ["review.references", "tutor.references"],
        "symbols": ["review.symbols", "tutor.symbols"],
        "write": ["review.note.insert", "tutor.write", "branch.describe.edit", "machine.port", "review.compose.edit", "words.edit"],
        "send": ["branch.describe.save", "review.filter.accept", "tutor.submit", "review.compose.send", "words.submit"],
        // NAV.md §5
        "find": ["review.filter", "forest.find", "forests.find"],
        "search": ["page.search", "review.search"],
        "next-sibling": ["forest.branch.next", "review.branch.next"],
        "previous-sibling": ["forest.branch.prev", "review.branch.prev"],
        "parent": ["forest.parent", "review.parent"],
        "child": ["forest.child", "review.child"],
        "root": ["forest.root", "review.root"],
        "tip": ["forest.tip", "review.tip"],
        "first": ["cursor.top", "review.top"],
        "last": ["cursor.bottom", "review.bottom"],
    ]

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

    /// The table's own rule: within each mode class a key (or a chord's prefix) belongs to one verb,
    /// and nothing sits on the leader. Checked again after keys.toml.
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

    /// Keys that mean different things on different pages, or two things in one place — checked
    /// within each mode (a key may mean one thing in normal and another in insert).
    public static func clashes(_ cmds: [Bound], surfaceScopes: [String: [String]]) -> [String] {
        let modes = Array(Set(cmds.flatMap(\.modes))).sorted { $0 == "normal" ? true : $1 == "normal" ? false : $0 < $1 }
        return modes.flatMap { m in
            clashesInMode(cmds.filter { $0.modes.contains(m) }, surfaceScopes: surfaceScopes).map { m == "normal" ? $0 : "\(m): \($0)" }
        }
    }

    static func clashesInMode(_ cmds: [Bound], surfaceScopes: [String: [String]]) -> [String] {
        let surfaces = surfaceScopes.sorted { $0.key < $1.key }
        func move(_ id: String) -> String { sameMove.first { $0.value.contains(id) }?.key ?? id }
        let byID = Dictionary(cmds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func token(_ id: String, _ key: String) -> String { byID[id]?.meaning[key] ?? move(id) }
        let scopeOf = byID.mapValues(\.scope)
        var leaderKeys: [String: [String: [String]]] = [:]
        var out: [String] = []
        var byKey: [String: [String: [String]]] = [:]
        var keyOrder: [String] = []
        var inScope: [String: [String]] = [:]
        var scopeOrder: [String] = []
        for c in cmds {
            for key in c.keys {
                let here = "\(c.scope) \(key)"
                if inScope[here] == nil { scopeOrder.append(here) }
                inScope[here, default: []].append(c.id)
                let pages = surfaces.filter { c.scope == "global" || $0.value.contains(c.scope) }.map(\.key)
                if pages.isEmpty { out.append("\(c.id): scope \(c.scope) is on no page") }
                if c.meaning[key] == Bound.leaderMeaning {
                    for p in pages where !(leaderKeys[p]?[key]?.contains(c.id) ?? false) { leaderKeys[p, default: [:]][key, default: []].append(c.id) }
                    continue
                }
                if byKey[key] == nil { keyOrder.append(key) }
                for p in pages {
                    var ids = byKey[key, default: [:]][p, default: []]
                    if !ids.contains(c.id) { ids.append(c.id) }
                    byKey[key, default: [:]][p] = ids
                }
            }
        }
        for here in scopeOrder {
            let ids = inScope[here]!
            if ids.count > 1 { out.append("\(here.split(separator: " ").dropFirst().joined(separator: " ")): \(ids.joined(separator: " and ")) in one place") }
        }
        for key in keyOrder {
            let at = byKey[key] ?? [:]
            // a page's own command wins over a global one, so the global meaning counts only where a page has none
            var meaning: [(String, String)] = []
            for (page, ids) in at.sorted(by: { $0.key < $1.key }) {
                let own = ids.filter { scopeOf[$0] != "global" }
                meaning.append((page, Array(Set((own.isEmpty ? ids : own).map { token($0, key) })).sorted().joined(separator: " | ")))
            }
            if Set(meaning.map(\.1)).count > 1 {
                out.append("\(key): \(meaning.map { "\($0.0) → \($0.1)" }.joined(separator: ", "))")
            }
        }
        // a page's leader namespace: one command per key, and no key a prefix of another
        for (page, keys) in leaderKeys.sorted(by: { $0.key < $1.key }) {
            for (key, ids) in keys.sorted(by: { $0.key < $1.key }) {
                if ids.count > 1 { out.append("\(page): \(key) is \(ids.joined(separator: " and "))") }
                for (other, oids) in keys where other.hasPrefix(key + " ") {
                    out.append("\(page): \(key) (\(ids[0])) swallows \(other) (\(oids[0]))")
                }
            }
        }
        return out
    }
}
