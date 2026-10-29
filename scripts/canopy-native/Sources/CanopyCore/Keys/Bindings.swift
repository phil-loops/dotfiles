import Foundation

/// A command as the key rules see it.
public struct Bound: Equatable, Sendable {
    public var id: String
    public var scope: String
    public var keys: [String]
    public var modes: [String]
    public init(id: String, scope: String, keys: [String], modes: [String] = ["normal"]) {
        self.id = id; self.scope = scope; self.keys = keys; self.modes = modes
    }
}

/// Your keys over the defaults, and the one rule they must keep: a key means one thing on every
/// page (bindings.ts). Pure.
public enum Bindings {
    /// Commands that are the same move on different pages, each page doing it to its own things.
    public static var sameMove: [String: [String]] = [
        "next": ["cursor.down", "review.down", "history.next"],
        "previous": ["cursor.up", "review.up", "history.prev"],
        "back out": ["overlay.close", "review.back", "history.exit", "commit.exit", "wiki.back", "tutor.back"],
        "out": ["forest.collapse", "review.leave", "forest.leave", "commit.back", "machine.log.close", "tutor.home"],
        "in": ["forest.expand", "branch.open", "history.enter", "machine.log"],
        "the thing's main action": ["row.primary", "review.fold", "todo.open", "review.expand", "history.open", "machine.open", "wiki.open", "tutor.concept", "tutor.open", "pane.open"],
        "send to GitHub": ["branch.push", "review.send", "review.push"],
        "move up the list": ["focus.up", "todo.up"],
        "move down the list": ["focus.down", "todo.down"],
        "put it away": ["project.archive", "todo.drop", "machine.kill", "tutor.forget"],
        "the words": ["review.words", "forest.words", "story.why"],
        "the page's other face": ["review.tab", "forest.face", "machine.log.jobs"],
        "open on GitHub": ["branch.pr", "review.finish"],
        "preview it": ["branch.preview", "review.preview", "forest.preview"],
        "sync it": ["branch.sync", "review.sync"],
        "the map": ["review.map", "tutor.map"],
        "show the type": ["review.types", "tutor.types"],
        "go to the definition": ["review.definition", "tutor.definition"],
        "go to the type's definition": ["review.type-definition", "tutor.type-definition"],
        "go to the implementations": ["review.implementation", "tutor.implementation"],
        "list the references": ["review.references", "tutor.references"],
        "list the file's symbols": ["review.symbols", "tutor.symbols"],
        "start writing": ["review.note.insert", "tutor.write", "branch.describe.edit"],
        // NAV.md §5
        "find on the page": ["review.filter", "forest.find", "forests.find"],
        "search the page": ["page.search", "review.search"],
        "next branch in merge order": ["forest.branch.next", "review.branch.next"],
        "previous branch in merge order": ["forest.branch.prev", "review.branch.prev"],
        "the parent branch": ["forest.parent", "review.parent"],
        "a child branch": ["forest.child", "review.child"],
        "the stack's root": ["forest.root", "review.root"],
        "the stack's tip": ["forest.tip", "review.tip"],
        "first row": ["cursor.top", "review.top"],
        "last row": ["cursor.bottom", "review.bottom"],
    ]

    private static let named: Set<String> = ["space", "esc", "ret", "tab", "up", "down", "left", "right"]

    public static func validKey(_ k: String) -> Bool {
        k.split(separator: " ", omittingEmptySubsequences: false).allSatisfy { tok in
            var t = Substring(tok)
            if t.count > 2, t.hasPrefix("C-") || t.hasPrefix("A-") { t = t.dropFirst(2) }
            return t.count == 1 || named.contains(String(t))
        }
    }

    /// Set each overridden command's keys; returns what couldn't be applied.
    public static func applyKeys(_ cmds: inout [Bound], _ overrides: [String: [String]]) -> [String] {
        var problems: [String] = []
        for (id, keys) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let i = cmds.firstIndex(where: { $0.id == id }) else {
                problems.append("\(id): no such command")
                continue
            }
            let bad = keys.filter { !validKey($0) }
            if !bad.isEmpty { problems.append("\(id): not a key — \(bad.map { "\"\($0)\"" }.joined(separator: ", "))") }
            cmds[i].keys = keys.filter(validKey)
        }
        return problems
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
        let scopeOf = Dictionary(cmds.map { ($0.id, $0.scope) }, uniquingKeysWith: { a, _ in a })
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
                meaning.append((page, Array(Set((own.isEmpty ? ids : own).map(move))).sorted().joined(separator: " | ")))
            }
            if Set(meaning.map(\.1)).count > 1 {
                out.append("\(key): \(meaning.map { "\($0.0) → \($0.1)" }.joined(separator: ", "))")
            }
        }
        return out
    }
}
