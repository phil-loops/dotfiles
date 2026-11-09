import CanopyCore
import Foundation

/// What one `, m` reads: the declaration a change sits in, as the lines of each change block it spans.
public struct ReviewUnit: Equatable {
    /// block → the indexes of its lines in this unit
    public var parts: [Int: Set<Int>]
    public var name: String
    public var blocks: [Int] { parts.keys.sorted() }
}

/// A changed line: its block and its place in the block.
public struct LineID: Hashable {
    public var block: Int
    public var index: Int
}

/// One declaration of a file as POST /syntax/units reads it from the syntax tree (Helix's grammars):
/// a statement in its scope — the top level, a class body, a describe(…) callback, a React component.
struct SyntaxUnit: Decodable, Equatable {
    var line: Int
    var endLine: Int
    var name: String
    var scope: Int
}

/// A function or class as Helix's textobject queries find it — what Helix's ]f and ]t walk.
struct SyntaxSpan: Decodable, Equatable {
    var line: Int
    var endLine: Int
    var name: String
}

struct SyntaxUnits: Decodable {
    var ok: Bool
    var units: [SyntaxUnit]?
    var functions: [SyntaxSpan]?
    var classes: [SyntaxSpan]?
    var message: String?
}

/// What the review page knows of one file's syntax at this tip.
struct FileSyntax {
    var units: [LineID: ReviewUnit]
    var functions: [SyntaxSpan]
    var classes: [SyntaxSpan]
    /// new-side lines the change touches (a removal counts as the line now standing where it was)
    var changed: Set<Int>

    /// The functions (or classes) the change touches, in file order — ]f's (]t's) stops.
    func touched(_ spans: [SyntaxSpan]) -> [SyntaxSpan] {
        spans.filter { s in changed.contains { s.line <= $0 && $0 <= s.endLine } }.sorted { $0.line < $1.line }
    }
}

enum ReviewUnitRule {
    /// Each changed line's unit. Lines in one declaration share its unit; neighbouring one-line
    /// declarations of one scope the change touches read as one (a run of new constants, imports or hook
    /// lines). A line outside every declaration (a blank line, a comment) goes with the next declaration
    /// in its block, else the one before; a block touching none is one unit. A new file is one unit.
    static func units(lines: [(block: Int, index: Int, at: Int)], status: FileStatus, decls: [SyntaxUnit]?) -> [LineID: ReviewUnit] {
        if lines.isEmpty { return [:] }
        let ids = lines.map { LineID(block: $0.block, index: $0.index) }
        func unit(_ members: [Int], _ name: String) -> ReviewUnit {
            var parts: [Int: Set<Int>] = [:]
            for m in members { parts[ids[m].block, default: []].insert(ids[m].index) }
            return ReviewUnit(parts: parts, name: name)
        }
        if status == .added {
            let u = unit(Array(ids.indices), "the new file")
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, u) })
        }

        let ds = decls ?? []
        let declOf = lines.map { l in ds.firstIndex { $0.line <= l.at && l.at <= $0.endLine } }
        var parent = Array(ids.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let (ra, rb) = (find(a), find(b)); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }

        var firstIn: [Int: Int] = [:]   // declaration → its first line
        for (i, d) in declOf.enumerated() { if let d { if let f = firstIn[d] { union(f, i) } else { firstIn[d] = i } } }
        for d in firstIn.keys where d + 1 < ds.count {
            let (a, n) = (ds[d], ds[d + 1])
            guard a.line == a.endLine, n.line == n.endLine, a.scope == n.scope, let other = firstIn[d + 1] else { continue }
            union(firstIn[d]!, other)
        }
        var looseOf: [Int: Int] = [:]   // block → its first line outside every declaration, when it touches none
        for i in ids.indices where declOf[i] == nil {
            let same = { (k: Int) in ids[k].block == ids[i].block && declOf[k] != nil }
            if let k = ids.indices.first(where: { $0 > i && same($0) }) ?? ids.indices.last(where: { $0 < i && same($0) }) {
                union(i, k)
            } else if let f = looseOf[ids[i].block] {
                union(f, i)
            } else {
                looseOf[ids[i].block] = i
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in ids.indices { groups[find(i), default: []].append(i) }
        var out: [LineID: ReviewUnit] = [:]
        for members in groups.values {
            let names = Set(members.compactMap { declOf[$0] }).sorted().map { ds[$0] }
            let u = unit(members, name(names))
            for m in members { out[ids[m]] = u }
        }
        return out
    }

    static func name(_ ds: [SyntaxUnit]) -> String {
        guard let first = ds.first else { return "a change" }
        if ds.count == 1 { return first.name }
        if ds.allSatisfy({ $0.line == $0.endLine }) {
            return ds.allSatisfy({ $0.name == first.name }) ? "\(ds.count) \(first.name)s" : "\(ds.count) declarations"
        }
        return ds.map(\.name).joined(separator: ", ")
    }
}

/// Each reviewed file's units, read as the cursor enters the file. `, m` asks here; until a file's
/// declarations are in, a change is its own unit, as before.
@MainActor
final class ReviewUnits {
    static func of(_ app: AppModel) -> ReviewUnits { app.state { ReviewUnits(app) } }

    private weak var app: AppModel?
    private var byKey: [String: FileSyntax] = [:]
    private var asking: Set<String> = []

    init(_ app: AppModel) { self.app = app }

    private func key(_ pg: ReviewPageState, _ path: String) -> String { "\(pg.id)@\(pg.tip)|\(pg.baseSha)|\(path)" }

    /// The unit a changed row's line sits in, once the file's syntax is in.
    func unit(_ pg: ReviewPageState, path: String, row: DiffRow, block: Int) -> ReviewUnit? {
        guard let fs = byKey[key(pg, path)], let fv = pg.fileOf(path), fv.lineKeys.indices.contains(block) else { return nil }
        for k in fv.rowLines[row.key] ?? [] {
            if let i = fv.lineKeys[block].firstIndex(of: k), let u = fs.units[LineID(block: block, index: i)] { return u }
        }
        return nil
    }

    /// The file's syntax, read first if it isn't yet; nil when the server can't be reached.
    func syntax(_ pg: ReviewPageState, path: String) async -> FileSyntax? {
        await load(pg, path: path)
        return byKey[key(pg, path)]
    }

    private struct Ask: Encodable { var branch: String; var path: String }

    func load(_ pg: ReviewPageState, path: String) async {
        let k = key(pg, path)
        guard byKey[k] == nil, !asking.contains(k), let app, let t = pg.target, let fv = pg.fileOf(path), !fv.blocks.isEmpty else { return }
        asking.insert(k)
        defer { asking.remove(k) }
        let r = await app.transport.ask(app.transport.atRepo(t.repo, "/syntax/units"), Ask(branch: t.name, path: path), as: SyntaxUnits.self)
        // a server that never answered is asked again next time; one that read no declarations is believed
        guard let r else { return }
        let got = r.ok ? r : nil
        guard let fv = pg.fileOf(path), key(pg, path) == k else { return }
        let lines = lineAnchors(fv.file).map { ($0.block, $0.index, $0.at) }
        byKey[k] = FileSyntax(units: ReviewUnitRule.units(lines: lines, status: fv.file.status, decls: got?.units),
                              functions: got?.functions ?? [], classes: got?.classes ?? [], changed: Set(lines.map(\.2)))
    }
}
