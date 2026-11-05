import Foundation

// A branch's unified diff (the /node payload's per-file patches) as rows the page renders and the
// cursor walks: one row per line in unified view, one per old/new pair in split view. Pure — a port
// of review/diff.ts, kept line-for-line so a block key here is the key the web app wrote.

public enum LineKind: String, Sendable { case ctx, add, del }

public struct DiffLine: Equatable, Sendable {
    public var kind: LineKind
    public var old: Int?
    public var new: Int?
    public var text: String
    public init(kind: LineKind, old: Int?, new: Int?, text: String) { self.kind = kind; self.old = old; self.new = new; self.text = text }
}

public struct Hunk: Equatable, Sendable {
    public var header: String
    public var lines: [DiffLine]
}

public enum FileStatus: String, Sendable { case added, deleted, renamed, modified, binary }

public struct FileDiff: Equatable, Sendable {
    public var path: String
    public var oldPath: String?
    public var status: FileStatus
    public var add: Int
    public var del: Int
    public var hunks: [Hunk]
}

/// "@@ -o,ol +n,nl @@ label" → its four numbers (lengths default to 1) and the label.
struct HunkHeader {
    var os: Int, ol: Int, ns: Int, nl: Int
    var label: String

    init?(_ s: String) {
        guard s.hasPrefix("@@ -") else { return nil }
        var rest = s.dropFirst(4)
        func num() -> Int? {
            let d = rest.prefix { $0.isASCII && $0.isNumber }
            guard !d.isEmpty else { return nil }
            rest = rest.dropFirst(d.count)
            return Int(d)
        }
        func opt() -> Int?? {
            guard rest.first == "," else { return .some(nil) }
            rest = rest.dropFirst()
            guard let n = num() else { return nil }
            return .some(n)
        }
        guard let os = num(), let ol = opt() else { return nil }
        guard rest.hasPrefix(" +") else { return nil }
        rest = rest.dropFirst(2)
        guard let ns = num(), let nl = opt() else { return nil }
        guard rest.hasPrefix(" @@") else { return nil }
        self.os = os; self.ol = ol ?? 1; self.ns = ns; self.nl = nl ?? 1
        label = String(rest.dropFirst(3))
        // the JS regex's `.*$`: `.` matches no line terminator
        if label.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
    }
}

public func parsePatch(_ path: String, _ patch: String) -> FileDiff {
    var out = FileDiff(path: path, oldPath: nil, status: .modified, add: 0, del: 0, hunks: [])
    var o = 0
    var n = 0
    // split on the "\n" code unit as JS does (a Swift Character "\r\n" is one grapheme)
    var parts = patch.components(separatedBy: "\n")
    if parts.count > 1 && parts.last == "" { parts.removeLast() }
    var lines: [DiffLine] = []
    var header: String?
    func flush() {
        if let h = header { out.hunks.append(Hunk(header: h, lines: lines)) }
        lines = []
    }
    for raw in parts {
        if let m = HunkHeader(raw) {
            flush()
            o = m.os
            n = m.ns
            header = raw
            continue
        }
        if header == nil {
            if raw.hasPrefix("new file") { out.status = .added }
            else if raw.hasPrefix("deleted file") { out.status = .deleted }
            else if raw.hasPrefix("rename from ") {
                out.status = .renamed
                out.oldPath = String(raw.dropFirst(12))
            } else if raw.hasPrefix("Binary files") { out.status = .binary }
            continue
        }
        guard let c = raw.unicodeScalars.first, c != "\\" else { continue }
        let text = String(raw.unicodeScalars.dropFirst())
        switch c {
        case "+":
            lines.append(DiffLine(kind: .add, old: nil, new: n, text: text)); n += 1; out.add += 1
        case "-":
            lines.append(DiffLine(kind: .del, old: o, new: nil, text: text)); o += 1; out.del += 1
        case " ":
            lines.append(DiffLine(kind: .ctx, old: o, new: n, text: text)); o += 1; n += 1
        default: break
        }
    }
    flush()
    return out
}

/// A display row: unified rows carry one line; split rows pair an old line with a new one.
public struct DiffRow: Equatable, Sendable {
    public var key: String
    public var hunk: Int
    public var left: DiffLine?
    public var right: DiffLine?
}

/// "R:<new>" for a line with a new side, else "L:<old>" — the anchor a thread or comment sits at.
public func anchorOf(_ l: DiffLine) -> String { l.new != nil ? "R:\(l.new!)" : "L:\(l.old ?? 0)" }

/// Every anchor a line answers to: a kept line sits on both sides.
public func anchorsOf(_ l: DiffLine) -> [String] { l.kind == .ctx ? ["R:\(l.new ?? 0)", "L:\(l.old ?? 0)"] : [anchorOf(l)] }

public func unifiedRows(_ f: FileDiff) -> [DiffRow] {
    var rows: [DiffRow] = []
    rows.reserveCapacity(f.hunks.reduce(0) { $0 + $1.lines.count })
    for (i, h) in f.hunks.enumerated() {
        for l in h.lines {
            rows.append(DiffRow(key: anchorOf(l), hunk: i, left: l.kind == .add ? nil : l, right: l.kind == .del ? nil : l))
        }
    }
    return rows
}

/// Split view: kept lines on both halves; a run of removals beside the additions that replace it.
public func splitRows(_ f: FileDiff) -> [DiffRow] {
    var rows: [DiffRow] = []
    for (i, h) in f.hunks.enumerated() {
        var dels: [DiffLine] = []
        var adds: [DiffLine] = []
        func flush() {
            for k in 0..<max(dels.count, adds.count) {
                let left = k < dels.count ? dels[k] : nil
                let right = k < adds.count ? adds[k] : nil
                rows.append(DiffRow(key: right.map(anchorOf) ?? anchorOf(left!), hunk: i, left: left, right: right))
            }
            dels = []
            adds = []
        }
        for l in h.lines {
            switch l.kind {
            case .del:
                if !adds.isEmpty { flush() }
                dels.append(l)
            case .add: adds.append(l)
            case .ctx:
                flush()
                rows.append(DiffRow(key: anchorOf(l), hunk: i, left: l, right: l))
            }
        }
        flush()
    }
    return rows
}

/// The anchors a row answers to (a thread at any of them renders under it).
public func rowAnchors(_ r: DiffRow) -> [String] {
    var out: [String] = []
    if let n = r.right?.new { out.append("R:\(n)") }
    if let o = r.left?.old, !out.contains("L:\(o)") { out.append("L:\(o)") }
    return out
}

// ── context: the unchanged lines a diff leaves out, revealed on request ──

/// A run of unchanged lines the diff hides: before hunk `at`, or after the last (`at` = hunks.count).
public struct Gap: Equatable, Sendable {
    public var at: Int
    /// new-side line numbers of what's still hidden; `last` nil = to the end of a file not read yet
    public var first: Int
    public var last: Int?
    /// the hunk header's own context (the enclosing function), for the gap row
    public var label: String
}

private struct Span { var first: Int, last: Int, offset: Int, after: Int, label: String }

private func span(_ h: Hunk) -> Span? {
    guard let m = HunkHeader(h.header) else { return nil }
    // a side with no lines (`+12,0`) sits AFTER its start line
    let first = m.nl != 0 ? m.ns : m.ns + 1
    let oldFirst = m.ol != 0 ? m.os : m.os + 1
    return Span(first: first, last: first + m.nl - 1, offset: oldFirst - first,
                after: oldFirst + m.ol - 1 - (first + m.nl - 1), label: m.label.trimmingCharacters(in: .whitespaces))
}

/// The file with `reveal[at]` more unchanged lines shown at each gap — taken from `lines` (the new
/// file, 1-based by index + 1) and added to the neighbouring hunk as ordinary context lines — plus
/// the gaps still hidden. A gap before a hunk reveals upward from it, the gap after the last
/// downward. Without `lines` nothing is revealed, and the trailing gap's end is unknown.
public func expand(_ f: FileDiff, _ lines: [String]?, _ reveal: [Int: Int]) -> (file: FileDiff, gaps: [Gap]) {
    if f.status == .added || f.status == .deleted || f.status == .binary || f.hunks.isEmpty { return (f, []) }
    let spans = f.hunks.map(span)
    if spans.contains(where: { $0 == nil }) { return (f, []) }
    let ss = spans.map { $0! }
    let eof: Int? = lines.map { l in !l.isEmpty && l[l.count - 1] == "" ? l.count - 1 : l.count }
    var hunks = f.hunks
    var gaps: [Gap] = []
    func ctx(_ n: Int, _ offset: Int) -> DiffLine {
        DiffLine(kind: .ctx, old: n + offset, new: n, text: (lines.flatMap { n - 1 < $0.count && n >= 1 ? $0[n - 1] : nil }) ?? "")
    }
    var prevEnd = 0
    for (i, s) in ss.enumerated() {
        let want = reveal[i] ?? 0
        var hiddenLast = s.first - 1
        if lines != nil && want > 0 {
            let from = max(prevEnd + 1, s.first - want)
            if from < s.first { hunks[i].lines.insert(contentsOf: (from..<s.first).map { ctx($0, s.offset) }, at: 0) }
            hiddenLast = from - 1
        }
        if hiddenLast >= prevEnd + 1 { gaps.append(Gap(at: i, first: prevEnd + 1, last: hiddenLast, label: s.label)) }
        prevEnd = s.last
    }
    let last = ss[ss.count - 1]
    let want = reveal[ss.count] ?? 0
    var hiddenFirst = last.last + 1
    if let eof, want > 0 {
        let to = min(eof, last.last + want)
        if last.last + 1 <= to { hunks[hunks.count - 1].lines.append(contentsOf: (last.last + 1...to).map { ctx($0, last.after) }) }
        hiddenFirst = to + 1
    }
    if eof == nil || hiddenFirst <= eof! { gaps.append(Gap(at: ss.count, first: hiddenFirst, last: eof, label: "")) }
    var out = f
    out.hunks = hunks
    return (out, gaps)
}

// ── viewed: a change stays reviewed until its own text changes ──

/// A run of consecutive changed lines — the unit "viewed" is kept on (wiki canopy-v2-viewed).
public struct Block: Equatable, Sendable {
    /// the path and the block's changed text with whitespace dropped (a reformat keeps it); an exact
    /// duplicate in the same file adds the unchanged lines around it, so a new copy never inherits a mark
    public var key: String
    /// the key until 2026-11-05 (exact text, duplicates numbered in file order), still read so marks made then count
    public var legacy: String
    /// the hunk it sits in, or -1 for a file with no changed lines to show (binary, a pure rename)
    public var hunk: Int
    /// which run of changed lines in its hunk, from 0
    public var run: Int
}

/// cyrb53 over UTF-16 code units, bit-for-bit the web app's (a key must be equal for equal text on
/// both clients — the server stores them).
public func cyrb53(_ s: String) -> String {
    let units = Array(s.utf16)
    let len = UInt32(truncatingIfNeeded: units.count)
    var h1: UInt32 = 0xDEADBEEF ^ len
    var h2: UInt32 = 0x41C6CE57 ^ len
    for u in units {
        let c = UInt32(u)
        h1 = (h1 ^ c) &* 2654435761
        h2 = (h2 ^ c) &* 1597334677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2246822507) ^ ((h2 ^ (h2 >> 13)) &* 3266489909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2246822507) ^ ((h1 ^ (h1 >> 13)) &* 3266489909)
    let v = (UInt64(h2 & 2097151) << 32) + UInt64(h1)
    return String(v, radix: 36)
}

/// The file's change blocks. `key` hashes the path and the block's `-` then `+` text with whitespace
/// dropped: no line numbers and no context, so it survives rebases, shifts, edited neighbours, git
/// regrouping hunks and a reformat. Two blocks with the same text in one file are told apart by the
/// unchanged line before and after each (then by order, if those match too). `legacy` is the key as
/// it was until 2026-11-05. A file with no changed lines gets one block for itself.
public func blocksOf(_ f: FileDiff) -> [Block] {
    struct Run { var hunk: Int; var run: Int; var lines: [DiffLine]; var before: String; var after: String }
    var runs: [Run] = []
    for (i, h) in f.hunks.enumerated() {
        var cur: [DiffLine] = [], before = "", lastCtx = "", n = 0
        for l in h.lines {
            if l.kind == .ctx {
                if !cur.isEmpty {
                    runs.append(Run(hunk: i, run: n, lines: cur, before: before, after: l.text))
                    n += 1
                    cur = []
                }
                lastCtx = l.text
            } else {
                if cur.isEmpty { before = lastCtx }
                cur.append(l)
            }
        }
        if !cur.isEmpty { runs.append(Run(hunk: i, run: n, lines: cur, before: before, after: "")) }
    }
    if runs.isEmpty {
        let k = cyrb53("\(f.path)\u{0}\u{0}\(f.status.rawValue)\u{0}\(f.oldPath ?? "")")
        return [Block(key: k, legacy: k, hunk: -1, run: 0)]
    }
    func squash(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })) }
    func exact(_ r: Run) -> String {
        (r.lines.filter { $0.kind == .del }.map { "-\($0.text)" } + r.lines.filter { $0.kind == .add }.map { "+\($0.text)" }).joined(separator: "\n")
    }
    func loose(_ r: Run) -> String {
        r.lines.filter { $0.kind == .del }.map { squash($0.text) }.joined() + "\u{1}" + r.lines.filter { $0.kind == .add }.map { squash($0.text) }.joined()
    }
    let bases = runs.map { cyrb53("\(f.path)\u{0}\(loose($0))") }
    var copies: [String: Int] = [:]
    for b in bases { copies[b, default: 0] += 1 }
    var legacySeen: [String: Int] = [:], keySeen: [String: Int] = [:]
    return runs.enumerated().map { j, r in
        let lb = cyrb53("\(f.path)\u{0}\(exact(r))")
        let ln = legacySeen[lb] ?? 0
        legacySeen[lb] = ln + 1
        var key = bases[j]
        if copies[key, default: 0] > 1 { key += "." + cyrb53(squash(r.before) + "\u{1}" + squash(r.after)) }
        let kn = keySeen[key] ?? 0
        keySeen[key] = kn + 1
        return Block(key: kn > 0 ? "\(key).\(kn)" : key, legacy: ln > 0 ? "\(lb).\(ln)" : lb, hunk: r.hunk, run: r.run)
    }
}
