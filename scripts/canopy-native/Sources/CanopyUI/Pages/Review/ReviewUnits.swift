import CanopyCore
import Foundation

/// What one `, m` reads: the declaration a change sits in, as the change blocks it spans.
public struct ReviewUnit: Equatable {
    public var blocks: [Int]
    public var name: String
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
    var units: [Int: ReviewUnit]
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
    /// Each change block's unit. Blocks that touch one declaration share its unit; neighbouring one-line
    /// declarations of one scope the change touches read as one (a run of new constants, imports or
    /// hook lines); a change outside every declaration is its own. A new file is one unit, declarations
    /// or not. Without declarations (no grammar for the file) every change is its own.
    static func units(rows: [DiffRow], rowBlock: [String: Int], status: FileStatus, decls: [SyntaxUnit]?) -> [Int: ReviewUnit] {
        let blocks = Set(rowBlock.values).sorted()
        if blocks.isEmpty { return [:] }
        if status == .added {
            let u = ReviewUnit(blocks: blocks, name: "the new file")
            return Dictionary(uniqueKeysWithValues: blocks.map { ($0, u) })
        }

        let lines = blockLines(rows: rows, rowBlock: rowBlock)
        let ds = decls ?? []
        var touched: [Int: [Int]] = [:]   // declaration index → its blocks
        for b in blocks {
            for x in Set(lines[b] ?? []) {
                guard let d = ds.firstIndex(where: { $0.line <= x && x <= $0.endLine }) else { continue }
                if !(touched[d]?.contains(b) ?? false) { touched[d, default: []].append(b) }
            }
        }

        var parent = Dictionary(uniqueKeysWithValues: blocks.map { ($0, $0) })
        func find(_ b: Int) -> Int {
            var b = b
            while parent[b]! != b { b = parent[b]! }
            return b
        }
        func union(_ a: Int, _ b: Int) { let (ra, rb) = (find(a), find(b)); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        for bs in touched.values { for b in bs.dropFirst() { union(bs[0], b) } }
        for d in touched.keys.sorted() where d + 1 < ds.count {
            let (a, n) = (ds[d], ds[d + 1])
            guard a.line == a.endLine, n.line == n.endLine, a.scope == n.scope, let next = touched[d + 1]?.first else { continue }
            union(touched[d]![0], next)
        }

        var groups: [Int: [Int]] = [:]
        for b in blocks { groups[find(b), default: []].append(b) }
        var out: [Int: ReviewUnit] = [:]
        for members in groups.values {
            let names = touched.filter { !Set($0.value).isDisjoint(with: members) }.keys.sorted().map { ds[$0] }
            let u = ReviewUnit(blocks: members.sorted(), name: name(names))
            for b in members { out[b] = u }
        }
        return out
    }

    /// Each block's new-side lines; a removal answers to the line that now stands where it was.
    static func blockLines(rows: [DiffRow], rowBlock: [String: Int]) -> [Int: [Int]] {
        var lines: [Int: [Int]] = [:]
        for (i, r) in rows.enumerated() {
            guard let b = rowBlock[r.key] else { continue }
            if let l = r.right, l.kind == .add, let n = l.new {
                lines[b, default: []].append(n)
            } else if r.right == nil || r.right?.kind == .ctx {
                let after = rows[(i + 1)...].first { $0.right?.new != nil }?.right?.new
                let before = rows[..<i].last { $0.right?.new != nil }?.right?.new
                lines[b, default: []].append(after ?? before.map { $0 + 1 } ?? 1)
            }
        }
        return lines
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

    func unit(_ pg: ReviewPageState, path: String, block: Int) -> ReviewUnit? { byKey[key(pg, path)]?.units[block] }

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
        byKey[k] = FileSyntax(
            units: ReviewUnitRule.units(rows: fv.rows, rowBlock: fv.rowBlock, status: fv.file.status, decls: got?.units),
            functions: got?.functions ?? [], classes: got?.classes ?? [],
            changed: Set(ReviewUnitRule.blockLines(rows: fv.rows, rowBlock: fv.rowBlock).values.joined()))
    }
}
