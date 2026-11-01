import AppKit
import CanopyCore
import SwiftUI

// The diff as canvas segments (Review.tsx's FileBlock / GapRow / RowView / RowExtras / Elsewhere,
// and CodePane's lines): each file is a header segment and a body segment, keyed by exactly what
// their text depends on — so marking a hunk viewed re-sets one header line, and moving the cursor
// re-sets nothing.

/// Accumulates one segment's text and attribute runs, then makes the attributed string in one go.
final class DocBuilder {
    let s = NSMutableString()
    private var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
    private var paraStart = 0

    var length: Int { s.length }

    func put(_ t: String, _ a: [NSAttributedString.Key: Any] = [:]) {
        let loc = s.length
        s.append(t)
        if !a.isEmpty { runs.append((NSRange(location: loc, length: s.length - loc), a)) }
    }

    /// Color the code's tokens, `at` the UTF-16 offset the code starts at.
    func tokens(_ code: String, _ lang: Lang, at: Int, _ colors: CodeColors, alpha: CGFloat = 1) {
        for t in CanopyUI.tokens(code, lang) {
            var a: [NSAttributedString.Key: Any] = [.foregroundColor: colors.color(t.kind).withAlphaComponent(alpha)]
            if t.kind == .comment { a[.obliqueness] = 0.12 }
            runs.append((NSRange(location: at + t.location, length: t.length), a))
        }
    }

    func endRow(_ info: RowInfo, _ para: NSParagraphStyle) {
        s.append("\n")
        runs.append((NSRange(location: paraStart, length: s.length - paraStart), [.rvRow: info, .paragraphStyle: para]))
        paraStart = s.length
    }

    func build(_ base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s as String, attributes: base)
        a.beginEditing()
        for (r, at) in runs { a.addAttributes(at, range: r) }
        a.endEditing()
        return a
    }
}

@MainActor
enum Para {
    private static var cache: [String: NSParagraphStyle] = [:]

    /// A row's paragraph: wrapped lines hang at `indent` columns; tabs every 4 columns.
    static func row(indent: Int, spacing: CGFloat = 2) -> NSParagraphStyle {
        let cw = DocFont.charWidth
        let k = "\(indent)|\(spacing)|\(cw)"
        if let p = cache[k] { return p }
        let p = NSMutableParagraphStyle()
        p.headIndent = CGFloat(indent) * cw
        p.lineSpacing = spacing
        p.defaultTabInterval = 4 * cw
        p.tabStops = []
        p.lineBreakMode = .byWordWrapping
        cache[k] = p
        return p
    }
}

/// The words that differ between an old line and the new line that replaced it, as UTF-16 ranges
/// in each: a longest-common-subsequence over word, space and punctuation tokens. A line that
/// shares almost nothing gets no highlight (the whole line changed; the band already says so).
func changedWords(_ old: String, _ new: String) -> ([NSRange], [NSRange]) {
    func tokens(_ s: String) -> [(String, NSRange)] {
        let ns = s as NSString
        let re = try! NSRegularExpression(pattern: "[A-Za-z0-9_$]+|\\s+|[^A-Za-z0-9_$\\s]")
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.range) }
    }
    let a = tokens(old), b = tokens(new)
    guard a.count * b.count <= 160_000 else { return ([], []) }
    var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            dp[i][j] = a[i].0 == b[j].0 ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
        }
    }
    var keepA = Set<Int>(), keepB = Set<Int>()
    var i = 0, j = 0
    while i < a.count && j < b.count {
        if a[i].0 == b[j].0 { keepA.insert(i); keepB.insert(j); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
    }
    let shared = a.indices.filter { keepA.contains($0) && !a[$0].0.allSatisfy(\.isWhitespace) }.count
    let words = max(1, a.filter { !$0.0.allSatisfy(\.isWhitespace) }.count)
    guard Double(shared) / Double(words) >= 0.4 else { return ([], []) }
    func ranges(_ t: [(String, NSRange)], _ keep: Set<Int>) -> [NSRange] {
        t.indices.filter { !keep.contains($0) && !t[$0].0.allSatisfy(\.isWhitespace) }.map { t[$0].1 }
    }
    return (ranges(a, keepA), ranges(b, keepB))
}

private func pad(_ n: Int?, _ w: Int) -> String {
    let s = n.map(String.init) ?? ""
    return s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

private func fit(_ s: String, _ w: Int) -> String {
    let c = s.count
    if c == w { return s }
    if c < w { return s + String(repeating: " ", count: w - c) }
    return String(s.prefix(w - 1)) + "…"
}

@MainActor
enum ReviewDocument {
    static let gutter = 12

    /// Every segment of the files tab (or one commit's diff), in order.
    static func segments(_ pg: ReviewPageState, _ app: AppModel, _ c: CanvasColors) -> [Segment] {
        let split = pg.split
        let salt = pg.commitScope.map { "c:\($0)" } ?? (pg.payload?.key ?? "")
        let composer: (path: String, side: Side, line: Int)? = {
            if case .line(_, let path, let side, let line, _, _) = ShipState.of(app).composer { return (path, side, line) }
            return nil
        }()
        var out: [Segment] = []
        for fv in pg.views {
            let path = fv.file.path
            let hiddenOutdated = fv.aside.filter(\.outdated).count
            let hk = "h|\(path)|\(fv.viewed)|\(fv.seen)/\(fv.blocks.count)|\(fv.file.add)|\(fv.file.del)|\(fv.file.status.rawValue)|\(hiddenOutdated)|\(pg.showOutdated)|\(pg.scoped)"
            out.append(Segment(key: hk) { header(fv, hiddenOutdated: hiddenOutdated, showOutdated: pg.showOutdated, scoped: pg.scoped, c) })
            if fv.viewed {
                out.append(Segment(key: "b|\(path)|viewed") { NSAttributedString() })
                continue
            }
            let ctx = pg.contextOf(path)
            let ctxSig = ctx.map { "\($0.lines?.count ?? -1):\($0.reveal.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))" } ?? ""
            let aside = fv.aside.filter { !$0.outdated || pg.showOutdated }
            let open = Set(pg.threads.filter { pg.isOpen($0) }.map(\.id))
            let replies = Dictionary(grouping: pg.items.filter { $0.kind == "reply" }) { $0.threadId ?? "" }
            func extrasSig(_ ts: [CanopyCore.Thread]) -> String {
                ts.map { t in "\(t.id)\(open.contains(t.id) ? "+" + (replies[t.id] ?? []).map(\.key).joined(separator: ",") : "")" }.joined(separator: ";")
            }
            var anchorsSig = fv.threadsAt.keys.sorted().map { "\($0):\(extrasSig(fv.threadsAt[$0]!))" }.joined(separator: "|")
            anchorsSig += "#" + fv.pendingAt.keys.sorted().map { "\($0):\(fv.pendingAt[$0]!.map(\.key).joined(separator: ","))" }.joined(separator: "|")
            let comp = composer.flatMap { $0.path == path ? "\($0.side.rawValue):\($0.line)" : nil } ?? ""
            let bk = "b|\(salt)|\(split)|\(pg.diffColumns)|\(path)|\(ctxSig)|\(fv.gaps.map { "\($0.at):\($0.first):\($0.last ?? -1)" }.joined(separator: ","))|a:\(extrasSig(aside))|\(anchorsSig)|\(comp)"
            out.append(Segment(key: bk) { body(fv, aside: aside, split: split, composer: composer, open: open, replies: replies, pg, app, c) })
        }
        let elsewhere = pg.elsewhere
        if !elsewhere.isEmpty {
            out.append(Segment(key: "e|\(elsewhere.map(\.id).joined(separator: ","))") { elsewhereSeg(elsewhere, app, c) })
        }
        return out
    }

    static func base(_ c: CanvasColors) -> [NSAttributedString.Key: Any] { [.font: DocFont.font, .foregroundColor: c.ink] }

    static func header(_ fv: FileView, hiddenOutdated: Int, showOutdated: Bool, scoped: Bool, _ c: CanvasColors) -> NSAttributedString {
        let b = DocBuilder()
        let path = fv.file.path
        if !scoped { b.put(fv.viewed ? "☑ " : fv.seen > 0 ? "◪ " : "☐ ", [.foregroundColor: fv.viewed ? c.patina : c.inkFaint]) }
        b.put(path, [.font: DocFont.bold, .foregroundColor: fv.viewed ? c.inkDim : c.ink])
        if fv.file.status != .modified { b.put("  \(fv.file.status.rawValue)", [.foregroundColor: c.inkFaint]) }
        if let o = fv.file.oldPath { b.put("  ← \(o)", [.foregroundColor: c.inkFaint]) }
        b.put("  +\(fv.file.add)", [.foregroundColor: c.add])
        b.put(" −\(fv.file.del)", [.foregroundColor: c.del])
        if hiddenOutdated > 0 && !showOutdated { b.put("   \(hiddenOutdated) outdated", [.foregroundColor: c.inkFaint]) }
        if fv.open > 0 { b.put("   \(fv.open) open", [.foregroundColor: c.ember]) }
        let v = fv.viewed ? "viewed" : fv.seen > 0 ? "\(fv.seen)/\(fv.blocks.count) viewed" : ""
        if !v.isEmpty { b.put("   \(v)", [.foregroundColor: c.inkFaint]) }
        b.endRow(RowInfo(kind: .file, stop: "f|\(path)", path: path), Para.row(indent: 2, spacing: 8))
        return b.build(base(c))
    }

    static func body(_ fv: FileView, aside: [CanopyCore.Thread], split: Bool, composer: (path: String, side: Side, line: Int)?,
                     open: Set<String>, replies: [String: [DraftItem]], _ pg: ReviewPageState, _ app: AppModel, _ c: CanvasColors) -> NSAttributedString {
        let b = DocBuilder()
        let path = fv.file.path
        let lang = langOf(path)
        func threadStops(_ t: CanopyCore.Thread) -> [String] {
            ["t|\(t.id)"] + (open.contains(t.id) ? (replies[t.id] ?? []).map { "p|\($0.key)" } : [])
        }
        for t in aside {
            extras(b, id: "x|\(path)|aside|\(t.id)", stops: threadStops(t), path: path) { [weak app] in
                guard let app else { return AnyView(EmptyView()) }
                return ReviewExtrasView.thread(app, t.id, aside: true)
            }
        }
        let gapAt = Dictionary(fv.gaps.map { ($0.at, $0) }, uniquingKeysWith: { a, _ in a })
        let W = split ? pg.splitWidth(path) : 0
        let unified = Para.row(indent: gutter + 2)
        let splitPara = Para.row(indent: W + 13)
        var composed = false
        for (i, r) in fv.rows.enumerated() {
            if i == 0 || fv.rows[i - 1].hunk != r.hunk, let g = gapAt[r.hunk] { gapRow(b, path, g, c) }
            let key = "l|\(path)|\(r.key)"
            let at = fv.at(r)
            let threaded = !at.threads.isEmpty
            if split {
                b.put(pad(r.left?.old, 5) + " ", [.foregroundColor: c.inkFaint, .font: DocFont.small])
                let lstart = b.length
                let ltext = r.left.map { fit($0.text, W) } ?? String(repeating: " ", count: W)
                b.put(ltext)
                if r.left != nil { b.tokens(ltext, lang, at: lstart, c.code) }
                b.put(" " + pad(r.right?.new, 5) + " ", [.foregroundColor: c.inkFaint, .font: DocFont.small])
                let rstart = b.length
                if let rt = r.right { b.put(rt.text); b.tokens(rt.text, lang, at: rstart, c.code) }
                let (lh, rh) = r.left?.kind == .del && r.right?.kind == .add ? changedWords(r.left!.text, r.right!.text) : ([], [])
                b.endRow(RowInfo(kind: .line, stop: key, path: path, hunk: r.hunk, left: r.left?.kind, right: r.right?.kind,
                                 oldLine: r.left?.old, newLine: r.right?.new, threaded: threaded, splitCol: W + 7,
                                 codeStart: 6, rightCodeStart: W + 13, leftHot: lh.filter { NSMaxRange($0) < W }, rightHot: rh), splitPara)
            } else {
                let line = (r.right ?? r.left)!
                let kind: LineKind = r.left != nil && r.right != nil ? .ctx : r.right != nil ? .add : .del
                b.put(pad(r.left?.old, 5) + " " + pad(r.right?.new, 5) + " ", [.foregroundColor: c.inkFaint, .font: DocFont.small])
                b.put(kind == .ctx ? "  " : kind == .add ? "+ " : "− ", [.foregroundColor: kind == .add ? c.add : kind == .del ? c.del : c.inkFaint])
                let start = b.length
                b.put(line.text)
                b.tokens(line.text, lang, at: start, c.code)
                b.endRow(RowInfo(kind: .line, stop: key, path: path, hunk: r.hunk, left: r.left?.kind, right: r.right?.kind,
                                 oldLine: r.left?.old, newLine: r.right?.new, threaded: threaded, codeStart: gutter + 2), unified)
            }
            // what hangs under the row: its conversations, pending comments, and the comment box (under
            // the first row showing its line)
            var compHere = false
            if !composed, let cp = composer, cp.path == path, rowAnchors(r).contains("\(cp.side == .left ? "L" : "R"):\(cp.line)") {
                compHere = true
                composed = true
            }
            if threaded || !at.pending.isEmpty || compHere {
                let stops = at.threads.flatMap(threadStops) + at.pending.map { "p|\($0.key)" }
                let tids = at.threads.map(\.id)
                let pending = at.pending
                // in a split, a note sits under the half it's about: the new side's column, or the old side's
                let sides = Set(at.threads.map(\.side) + at.pending.map(\.side) + (compHere ? [composer!.side] : []))
                let column: Int? = split && sides.count == 1 ? (sides.first == .left ? 6 : W + 13) : nil
                extras(b, id: "x|\(path)|\(r.key)", stops: stops, path: path, column: column, splitCol: split ? W + 7 : 0) { [weak app] in
                    guard let app else { return AnyView(EmptyView()) }
                    return ReviewExtrasView.row(app, threads: tids, pending: pending, composing: compHere)
                }
            }
        }
        if let g = gapAt[fv.file.hunks.count] { gapRow(b, path, g, c) }
        if fv.rows.isEmpty, fv.gaps.isEmpty {
            b.put(String(repeating: " ", count: gutter + 2) + (fv.file.status == .binary ? "binary file" : fv.file.status == .renamed ? "renamed, no changes" : "no lines to show"),
                  [.foregroundColor: c.inkFaint])
            b.endRow(RowInfo(kind: .note, stop: nil, path: path), unified)
        }
        return b.build(base(c))
    }

    static func gapRow(_ b: DocBuilder, _ path: String, _ g: Gap, _ c: CanvasColors) {
        let n = g.last.map { $0 - g.first + 1 }
        let where_ = g.at == 0 ? "above" : (g.last == nil || g.label.isEmpty) ? "below" : "hidden"
        b.put(String(repeating: " ", count: gutter + 2))
        b.put("⋯ ", [.foregroundColor: c.gold])
        let what = n.map { "\($0) \(where_ == "hidden" ? "hidden" : "unchanged") line\($0 == 1 ? "" : "s")\(where_ == "hidden" ? "" : " \(where_)")" } ?? "more lines"
        b.put(what, [.foregroundColor: c.inkFaint, .font: DocFont.small])
        if !g.label.isEmpty { b.put(" · \(g.label)", [.foregroundColor: c.inkFaint, .font: DocFont.small]) }
        b.endRow(RowInfo(kind: .gap, stop: "g|\(path)|\(g.at)", path: path, hunk: g.at), Para.row(indent: gutter + 2, spacing: 4))
    }

    static func extras(_ b: DocBuilder, id: String, stops: [String], path: String, column: Int? = nil, splitCol: Int = 0, _ view: @escaping () -> AnyView) {
        b.put("\u{200B}")
        b.endRow(RowInfo(kind: .extras, stop: stops.first, stops: stops, path: path, splitCol: splitCol, extra: ExtraSpec(id: id, column: column, view: view)),
                 Para.row(indent: gutter))
    }

    static func elsewhereSeg(_ threads: [CanopyCore.Thread], _ app: AppModel, _ c: CanvasColors) -> NSAttributedString {
        let b = DocBuilder()
        b.put("threads on files it no longer changes", [.foregroundColor: c.inkDim, .font: DocFont.bold])
        b.endRow(RowInfo(kind: .file, stop: nil), Para.row(indent: 2, spacing: 8))
        for t in threads {
            extras(b, id: "x|elsewhere|\(t.id)", stops: ["t|\(t.id)"], path: t.path) { [weak app] in
                guard let app else { return AnyView(EmptyView()) }
                return ReviewExtrasView.thread(app, t.id, aside: true)
            }
        }
        return b.build(base(c))
    }

    /// One file at one commit as canvas rows ("s:<n>"), its line numbers in the gutter (CodePane).
    static func code(_ lines: [String], path: String, _ c: CanvasColors) -> NSAttributedString {
        let b = DocBuilder()
        let lang = langOf(path)
        let p = Para.row(indent: 6, spacing: 3)
        for (i, l) in lines.enumerated() {
            b.put(pad(i + 1, 5) + " ", [.foregroundColor: c.inkFaint, .font: DocFont.small])
            let start = b.length
            b.put(l, [.foregroundColor: c.inkDim])
            b.tokens(l, lang, at: start, c.code)
            b.endRow(RowInfo(kind: .code, stop: "s:\(i + 1)", path: path, newLine: i + 1, codeStart: 6), p)
        }
        return b.build(base(c))
    }
}
