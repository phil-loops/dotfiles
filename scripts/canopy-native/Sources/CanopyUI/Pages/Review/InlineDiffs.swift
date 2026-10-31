import CanopyCore
import Observation
import SwiftUI

/// The outgoing change read commit by commit (inline.ts): each commit's own diff (GET
/// /commit-diff), its revealed context and its fold, keyed by commit so the commands that change
/// them (`inline.expand`, `inline.fold`) can reach them. `InlineDiffView` draws one file of one.
@MainActor
@Observable
public final class InlineDiffs {
    /// a commit's diff above this many changed lines arrives folded, with a diffstat
    public static let foldOver = 150

    public private(set) var diffs: [String: [NodeFile]] = [:]
    public private(set) var texts: [String: [String]] = [:]
    public private(set) var reveals: [String: [Int: Int]] = [:]
    public private(set) var folds: [String: Bool] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored weak var app: AppModel?

    init(_ app: AppModel) { self.app = app }
    public static func of(_ app: AppModel) -> InlineDiffs { app.state { InlineDiffs(app) } }

    private func repoPath(_ p: String) -> String {
        guard let app else { return p }
        return app.transport.atRepo(ReviewPageState.of(app).target?.repo ?? "", p)
    }

    /// Read a commit's own diff once.
    public func loadDiff(_ sha: String) {
        guard diffs[sha] == nil, !asking.contains(sha), let app else { return }
        asking.insert(sha)
        let path = repoPath("/commit-diff?sha=\(sha.uriComponent)")
        Task { @MainActor in
            struct D: Decodable { var files: [NodeFile] }
            defer { self.asking.remove(sha) }
            if let d = try? await app.transport.getJSON(path, as: D.self) { self.diffs[sha] = d.files }
        }
    }

    /// `<sha>|<path>`: one commit's version of one file.
    public static func fileKey(_ sha: String, _ path: String) -> String { "\(sha)|\(path)" }

    /// Show `n` more hidden lines at a gap of one commit's file; reads the file at that commit once.
    public func revealAt(sha: String, path: String, at: Int, n: Int = 20) {
        let k = Self.fileKey(sha, path)
        reveals[k, default: [:]][at, default: 0] += n
        guard texts[k] == nil, !asking.contains(k), let app else { return }
        asking.insert(k)
        let p = repoPath("/file?branch=\(sha.uriComponent)&path=\(path.uriComponent)")
        Task { @MainActor in
            defer { self.asking.remove(k) }
            if let t = await app.transport.getText(p) { self.texts[k] = t.components(separatedBy: "\n") }
        }
    }

    /// Folded: the commit's own choice if it was toggled, else folded when it's large.
    public func isFolded(_ sha: String, changed: Int) -> Bool { folds[sha] ?? (changed > Self.foldOver) }
    public func toggleFold(_ sha: String, changed: Int) { folds[sha] = !isFolded(sha, changed: changed) }
}

/// One commit's change to one file, drawn inline (InlineDiff.tsx): the same rows as the files tab
/// (unified or split, highlighted), its hidden context expandable, and — when `stable` (no later
/// commit touches the file, so its lines are the tip's) — the threads anchored there.
public struct InlineDiffView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let sha: String
    let file: FileDiff
    let stable: Bool
    @State private var handle = CanvasHandle()

    public init(sha: String, file: FileDiff, stable: Bool) { self.sha = sha; self.file = file; self.stable = stable }

    public var body: some View {
        let inl = InlineDiffs.of(app)
        let k = InlineDiffs.fileKey(sha, file.path)
        let (f, gaps) = expand(file, inl.texts[k], inl.reveals[k] ?? [:])
        let pg = ReviewPageState.of(app)
        let rows = pg.split ? splitRows(f) : unifiedRows(f)
        var threadsAt: [String: [CanopyCore.Thread]] = [:]
        if stable {
            for t in pg.threads where t.path == file.path && t.local != nil && (!t.outdated || pg.showOutdated) {
                threadsAt["\(t.side == .left ? "L" : "R"):\(t.local!.line)", default: []].append(t)
            }
        }
        let fv = FileView(file: f, rows: rows, threadsAt: threadsAt, pendingAt: [:], aside: [], open: 0, viewed: false, blocks: [], seen: 0, seenHunks: [], gaps: gaps)
        let c = CanvasColors(theme)
        let key = "i|\(k)|\(pg.split)|\(inl.texts[k]?.count ?? -1)|\((inl.reveals[k] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })|\(threadsAt.keys.sorted())"
        let lines = rows.count + gaps.count + threadsAt.count * 3
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(file.path).foregroundStyle(theme.ink)
                Text("+\(file.add)").foregroundStyle(theme.add)
                Text("−\(file.del)").foregroundStyle(theme.del)
            }
            .font(Theme.text(12)).padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading).background(theme.vellumRaise)
            CanvasView(handle: handle, segments: [Segment(key: key) {
                ReviewDocument.body(fv, aside: [], split: pg.split, composer: nil, open: [], replies: [:], pg, app, c)
            }], marks: CanvasMarks(), onClick: { stop, _ in
                if stop.hasPrefix("g|"), let at = stop.split(separator: "|").last.flatMap({ Int($0) }) {
                    app.runner.dispatch("inline.expand", via: .click, arg: "\(sha)|\(file.path)|\(at)")
                }
            })
            .frame(height: CGFloat(min(lines, 400)) * (DocFont.size * 1.6) + 12)
        }
    }
}
