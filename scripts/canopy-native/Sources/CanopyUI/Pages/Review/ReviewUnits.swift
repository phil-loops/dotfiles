import CanopyCore
import Foundation

/// What one `, m` reads: the declaration a change sits in, as the change blocks it spans.
public struct ReviewUnit: Equatable {
    public var blocks: [Int]
    public var name: String
}

enum ReviewUnitRule {
    /// Each change block's unit, from the file's symbols. Steps into containers — a class, a namespace,
    /// a `describe(…)` callback — and stops at the first declaration inside: a function, a method, an
    /// `it(…)`, a multi-line const. Neighbouring one-line declarations the change touches read as one
    /// (a run of new constants or imports). Blocks that share a declaration share its unit; a change
    /// outside every declaration is its own. A new file is one unit, symbols or not.
    static func units(rows: [DiffRow], rowBlock: [String: Int], status: FileStatus, symbols: [LSPSymbols.Symbol]?) -> [Int: ReviewUnit] {
        let blocks = Set(rowBlock.values).sorted()
        if blocks.isEmpty { return [:] }
        if status == .added {
            let u = ReviewUnit(blocks: blocks, name: "the new file")
            return Dictionary(uniqueKeysWithValues: blocks.map { ($0, u) })
        }

        var lines: [Int: [Int]] = [:]
        for (i, r) in rows.enumerated() {
            guard let b = rowBlock[r.key] else { continue }
            if let l = r.right, l.kind == .add, let n = l.new {
                lines[b, default: []].append(n)
            } else if r.right == nil || r.right?.kind == .ctx {
                // a removal answers to the line that now stands where it was
                let after = rows[(i + 1)...].first { $0.right?.new != nil }?.right?.new
                let before = rows[..<i].last { $0.right?.new != nil }?.right?.new
                lines[b, default: []].append(after ?? before.map { $0 + 1 } ?? 1)
            }
        }

        let roots = tree(symbols ?? [])
        var leafBlocks: [Int: [Int]] = [:]
        var leafAt: [Int: (siblings: [Node], at: Int)] = [:]
        for b in blocks {
            for x in Set(lines[b] ?? []) {
                guard let hit = leaf(x, roots) else { continue }
                if !(leafBlocks[hit.node.i]?.contains(b) ?? false) { leafBlocks[hit.node.i, default: []].append(b) }
                leafAt[hit.node.i] = (hit.siblings, hit.at)
            }
        }

        var parent = Dictionary(uniqueKeysWithValues: blocks.map { ($0, $0) })
        func find(_ b: Int) -> Int {
            var b = b
            while parent[b]! != b { b = parent[b]! }
            return b
        }
        func union(_ a: Int, _ b: Int) { let (ra, rb) = (find(a), find(b)); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        for bs in leafBlocks.values { for b in bs.dropFirst() { union(bs[0], b) } }
        for (i, place) in leafAt {
            let s = place.siblings[place.at].s
            guard s.line == s.endLine, place.at + 1 < place.siblings.count else { continue }
            let next = place.siblings[place.at + 1]
            guard next.s.line == next.s.endLine, let other = leafBlocks[next.i]?.first, let mine = leafBlocks[i]?.first else { continue }
            union(mine, other)
        }

        var groups: [Int: [Int]] = [:]
        for b in blocks { groups[find(b), default: []].append(b) }
        var out: [Int: ReviewUnit] = [:]
        for members in groups.values {
            let leaves = leafBlocks.filter { !Set($0.value).isDisjoint(with: members) }.keys.sorted()
            let syms = leaves.compactMap { i in leafAt[i].map { $0.siblings[$0.at].s } }
            let u = ReviewUnit(blocks: members.sorted(), name: name(syms))
            for b in members { out[b] = u }
        }
        return out
    }

    final class Node {
        let s: LSPSymbols.Symbol
        let i: Int
        var kids: [Node] = []
        init(_ s: LSPSymbols.Symbol, _ i: Int) { self.s = s; self.i = i }
    }

    /// The flat, depth-tagged symbol list back as a tree.
    static func tree(_ syms: [LSPSymbols.Symbol]) -> [Node] {
        var roots: [Node] = [], stack: [Node] = []
        for (i, s) in syms.enumerated() {
            let n = Node(s, i)
            while let top = stack.last, top.s.depth >= s.depth { stack.removeLast() }
            if let p = stack.last { p.kids.append(n) } else { roots.append(n) }
            stack.append(n)
        }
        return roots
    }

    private static let suite = try! NSRegularExpression(pattern: #"^(describe|suite|context)(\.\w+)*\(.*\) callback$"#)

    /// A symbol a unit sits inside of rather than one that is a unit.
    static func container(_ s: LSPSymbols.Symbol) -> Bool {
        if ["class", "namespace", "module"].contains(s.kind) { return true }
        return suite.firstMatch(in: s.name, range: NSRange(s.name.startIndex..., in: s.name)) != nil
    }

    /// The declaration line `x` reads as part of, and where it sits among its siblings; nil outside every one.
    static func leaf(_ x: Int, _ roots: [Node]) -> (node: Node, siblings: [Node], at: Int)? {
        var level = roots
        while let at = level.firstIndex(where: { $0.s.line <= x && x <= $0.s.endLine }) {
            let n = level[at]
            guard container(n.s), !n.kids.isEmpty else { return (n, level, at) }
            level = n.kids
        }
        return nil
    }

    static func name(_ syms: [LSPSymbols.Symbol]) -> String {
        if syms.isEmpty { return "a change" }
        if syms.count > 1 {
            return syms.allSatisfy { $0.line == $0.endLine } ? "\(syms.count) declarations" : syms.map(label).joined(separator: ", ")
        }
        return label(syms[0])
    }

    static func label(_ s: LSPSymbols.Symbol) -> String {
        if s.name.hasSuffix(" callback") { return String(s.name.dropLast(9)) }
        switch s.kind {
        case "function", "method", "class", "interface", "enum": return "\(s.kind) \(s.name)"
        default: return s.name
        }
    }
}

/// Each reviewed file's units, read in the background as the cursor enters the file. `, m` asks here;
/// until a file's symbols are in, a change is its own unit, as before.
@MainActor
final class ReviewUnits {
    static func of(_ app: AppModel) -> ReviewUnits { app.state { ReviewUnits(app) } }

    private weak var app: AppModel?
    private var byKey: [String: [Int: ReviewUnit]] = [:]
    private var asking: Set<String> = []

    init(_ app: AppModel) { self.app = app }

    private func key(_ pg: ReviewPageState, _ path: String) -> String { "\(pg.id)@\(pg.tip)|\(pg.baseSha)|\(path)" }

    func unit(_ pg: ReviewPageState, path: String, block: Int) -> ReviewUnit? { byKey[key(pg, path)]?[block] }

    private struct Ask: Encodable { var branch: String; var path: String; var side = "new" }

    func load(_ pg: ReviewPageState, path: String) async {
        let k = key(pg, path)
        guard byKey[k] == nil, !asking.contains(k), let app, let t = pg.target, let fv = pg.fileOf(path), !fv.blocks.isEmpty else { return }
        var syms: [LSPSymbols.Symbol]?
        var answered = fv.file.status == .added
        if !answered {
            asking.insert(k)
            defer { asking.remove(k) }
            // quiet on purpose: CodeLookup's own asks pop notes and cancel each other; this one is background
            for _ in 0..<20 {
                let r = await app.transport.ask(app.transport.atRepo(t.repo, "/lsp/symbols"), Ask(branch: t.name, path: path), as: LSPSymbols.self)
                if r?.ok == true { syms = r?.symbols ?? []; answered = true; break }
                guard r?.state == "loading" else { answered = r != nil; break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // a server that never answered is asked again next time; one that said "no symbols" is believed
        guard answered, let fv = pg.fileOf(path), key(pg, path) == k else { return }
        byKey[k] = ReviewUnitRule.units(rows: fv.rows, rowBlock: fv.rowBlock, status: fv.file.status, symbols: syms)
    }
}
