import Foundation

// outlineHints.ts: the outline's voice rules, as live hints — never a block. The opening commit
// carries `type(scope):` with the forest's ticket as the lowercase scope; follow-ups read bare,
// the way they'd be typed at `git commit -m`; subjects stay short; a body is one non-obvious why,
// and the forest plan belongs in the PR body, not baked into a commit. Pure.

/// A commit message (or the PR's title + body): the words a hint reads and a fix rewrites.
public struct MessageWords: Equatable, Sendable {
    public var subject: String
    public var body: String
    public init(subject: String, body: String) { self.subject = subject; self.body = body }
}

public struct WordsHint: Sendable {
    public enum Tone: String, Sendable { case error, warn, note }
    public struct Fix: Sendable {
        public var label: String
        public var apply: @Sendable (MessageWords) -> MessageWords
    }
    public var id: String
    public var tone: Tone
    public var text: String
    public var fix: Fix?
}

public enum OutlineHints {
    /// Phil's hand-typed PR titles run 20–35 chars after `type(scope):`; past 40 reads drafted. The
    /// prefix isn't counted — the median subject on main is 49 chars whole.
    public static let subjectLimit = 40
    static let longBody = 240
    static let types = ["feat", "fix", "chore", "refactor", "docs", "test", "perf", "style", "ci", "build", "revert"]
    static let prefixRE = try! NSRegularExpression(pattern: "^(\(types.joined(separator: "|")))(\\(([^)]*)\\))?(!)?:\\s*", options: [.caseInsensitive])
    static let wipRE = try! NSRegularExpression(pattern: "^(wip\\b|fixup!|squash!|amend!)", options: [.caseInsensitive])

    /// JS `.length`: UTF-16 units, so limits read as v2's do.
    static func len(_ s: String) -> Int { s.utf16.count }

    /// The subject's own words: what `subjectLimit` measures.
    public static func wordsLength(_ subject: String) -> Int { len(bare(subject.trimmingCharacters(in: .whitespacesAndNewlines))) }

    public struct Prefix: Equatable, Sendable {
        public var type: String
        public var scope: String?
        public var bang: String
        public var rest: String
    }

    /// `{type, scope, bang, rest}` when the subject opens with a conventional prefix.
    public static func prefixOf(_ subject: String) -> Prefix? {
        let ns = subject as NSString
        guard let m = prefixRE.firstMatch(in: subject, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        return Prefix(type: g(1)!.lowercased(), scope: g(3), bang: g(4) ?? "", rest: ns.substring(from: m.range.upperBound))
    }

    /// The subject with its conventional prefix removed — how a follow-up reads.
    public static func bare(_ subject: String) -> String { prefixOf(subject)?.rest ?? subject }

    /// The opening subject with the ticket as its scope; a prefix-less one gains `feat(<ticket>):`.
    public static func withScope(_ subject: String, _ ticket: String) -> String {
        guard let p = prefixOf(subject) else { return "feat(\(ticket)): \(subject)" }
        return "\(p.type)(\(ticket))\(p.bang): \(p.rest)"
    }

    static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when a body still carries the generated "Part of a stack" block or the old fence.
    public static func hasPlan(_ body: String) -> Bool {
        lines(body).contains { $0.hasPrefix("Part of ") || $0 == "-- forest --" }
    }

    static let stepRE = try! NSRegularExpression(pattern: "^\\s+\\S|^\\s*(\\d+\\.\\s|[-*•]\\s|\\[)")
    static func isStep(_ l: String) -> Bool { stepRE.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil }

    /// The body without its generated forest block: the "Part of …" line and the step lines under
    /// it, plus the retired `-- forest --` fence. Prose before or after the block stays.
    public static func stripPlan(_ body: String) -> String {
        let ls = lines(body)
        var out: [String] = []
        var i = 0
        while i < ls.count {
            defer { i += 1 }
            if trim(ls[i]) == "-- forest --" { continue }
            if ls[i].hasPrefix("Part of ") {
                // the block runs to the first blank line that isn't followed by more steps: a squash
                // message wraps long steps onto unindented lines, so every non-blank line until then is the block's
                while i + 1 < ls.count {
                    if trim(ls[i + 1]) != "" { i += 1; continue }
                    var j = i + 1
                    while j < ls.count && trim(ls[j]) == "" { j += 1 }
                    if j < ls.count && isStep(ls[j]) { i = j } else { break }
                }
                continue
            }
            out.append(ls[i])
        }
        var s = out.joined(separator: "\n")
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return trim(s)
    }

    public enum Kind: Sendable { case commit, title }

    /// Every hint for one outline row. `opening` = the branch's first own commit (or the PR title,
    /// which follows the same rule); `ticket` = the forest's ticket, lowercase, if it has one.
    public static func hintsFor(_ w: MessageWords, opening: Bool, ticket: String? = nil, kind: Kind = .commit) -> [WordsHint] {
        var hints: [WordsHint] = []
        let subject = trim(w.subject)
        if subject.isEmpty { return [WordsHint(id: "empty", tone: .error, text: "a subject is required")] }
        if wipRE.firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) != nil {
            hints.append(WordsHint(id: "wip", tone: .error, text: "a placeholder subject — saving refuses it"))
        }
        if wordsLength(subject) > subjectLimit {
            hints.append(WordsHint(id: "long", tone: .warn, text: "\(wordsLength(subject)) chars after the prefix — yours run 20–35 (≤ \(subjectLimit))"))
        }
        let p = prefixOf(subject)
        if opening, let t = ticket, !t.isEmpty {
            let ticket = t.lowercased()
            let fix = WordsHint.Fix(label: p == nil ? "＋ feat(\(ticket)):" : "fix scope") { x in
                MessageWords(subject: withScope(trim(x.subject), ticket), body: x.body)
            }
            if p == nil {
                hints.append(WordsHint(id: "scope", tone: .warn, text: "the opening line wants `type(\(ticket)):`", fix: fix))
            } else if p!.scope != ticket {
                let text = p!.scope.map { "scope `\($0)` — the forest's ticket is `\(ticket)`" } ?? "no scope — the forest's ticket is `\(ticket)`"
                hints.append(WordsHint(id: "scope", tone: .warn, text: text, fix: fix))
            }
        } else if opening && p == nil {
            hints.append(WordsHint(id: "type", tone: .note, text: "the opening line usually carries a `type:` prefix"))
        }
        if !opening && p != nil {
            hints.append(WordsHint(id: "bare", tone: .warn, text: "follow-ups read bare — no type, no scope",
                                   fix: WordsHint.Fix(label: "make bare") { x in MessageWords(subject: bare(trim(x.subject)), body: x.body) }))
        }
        if kind != .title && hasPlan(w.body) {
            hints.append(WordsHint(id: "plan", tone: .warn, text: "a baked forest block — the PR body carries the stack now",
                                   fix: WordsHint.Fix(label: "strip it") { x in MessageWords(subject: x.subject, body: stripPlan(x.body)) }))
        } else if kind != .title && len(trim(w.body)) > longBody {
            hints.append(WordsHint(id: "prose", tone: .note, text: "\(len(trim(w.body)))-char body — one line of why is plenty"))
        }
        return hints
    }

    /// Hints for a PR body: a baked forest block (GitHub squashes the PR body onto main, so it lands
    /// there) and a long one — Phil's own run 0–3 casual lines above the template.
    public static func bodyHints(_ body: String, template: String = "") -> [WordsHint] {
        if hasPlan(body) {
            return [WordsHint(id: "plan", tone: .warn, text: "a baked forest block — it lands on main with the squash",
                              fix: WordsHint.Fix(label: "strip it") { x in MessageWords(subject: x.subject, body: stripPlan(x.body)) })]
        }
        let tpl = trim(template)
        let own = trim(!template.isEmpty && body.contains(tpl) ? replaceFirst(body, tpl, "") : body)
        return len(own) > longBody ? [WordsHint(id: "prose", tone: .note, text: "\(len(own)) chars above the template — yours are a line or three")] : []
    }

    static func replaceFirst(_ s: String, _ what: String, _ with: String) -> String {
        guard !what.isEmpty, let r = s.range(of: what) else { return s }
        return s.replacingCharacters(in: r, with: with)
    }

    static let ruleRE = try! NSRegularExpression(pattern: "^---[ \\t]*$", options: [.anchorsMatchLines])

    /// A PR body as Phil's own lines and the repo template under them (from its first `---` rule on).
    public static func splitTemplate(_ body: String) -> (own: String, template: String) {
        let ns = body as NSString
        guard let m = ruleRE.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return (body, "") }
        let head = ns.substring(to: m.range.location)
        let own = head.hasSuffix("\n\n") ? String(head.dropLast(2)) : head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return (own, trim(ns.substring(from: m.range.location)))
    }

    /// Rejoin what splitTemplate split, so editing the own lines keeps the template exactly.
    public static func joinTemplate(_ own: String, _ template: String) -> String {
        template.isEmpty ? own : own.isEmpty ? template : "\(own)\n\n\(template)"
    }
}
