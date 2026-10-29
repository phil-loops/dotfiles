import Foundation

// markdown.ts: GitHub-flavoured markdown for review comments, PR bodies and wiki pages, parsed into
// blocks of styled spans — never HTML, so nothing a comment says can become markup or a script.
//
// Blocks: fenced code (```suggestion becomes a suggested change), headings, quotes, lists (task
// boxes too), tables, rules, paragraphs with GitHub's hard line breaks. Inline: code, bold, italic,
// strikethrough, http(s) links and bare URLs, @mentions. HTML comments (PR templates) are dropped.
//
// Published for the Wiki area (PORTING.md §8 C → F):
//   Markdown.parse(text, replaces:) -> [MdBlock]     the AST, testable
//   MarkdownView(text, replaces:)                     the SwiftUI rendering (MarkdownView.swift)
//   Markdown.inline(text) -> [MdSpan]                 one line of inline markup
//   Markdown.plain(text, max:) / Markdown.suggestionOf(text)

/// A run of text with one style. A link is only ever an http(s) URL.
public struct MdSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var strike = false
    public var code = false
    public var mention = false
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, mention: Bool = false, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.strike = strike; self.code = code; self.mention = mention; self.link = link
    }
}

public typealias MdLine = [MdSpan]

public struct MdItem: Equatable, Sendable {
    /// a task box: true checked, false open, nil a plain item
    public var task: Bool?
    public var text: MdLine
    public var children: [MdBlock]
}

public indirect enum MdBlock: Equatable, Sendable {
    /// lines joined by GitHub's hard line breaks
    case paragraph([MdLine])
    case heading(level: Int, MdLine)
    case code(lang: String, lines: [String])
    /// a ```suggestion: the lines it replaces (shown as removals) and what it puts there
    case suggestion(removes: [String], adds: [String])
    case rule
    case quote([MdBlock])
    case table(head: [MdLine], rows: [[MdLine]])
    case list(ordered: Bool, start: Int, items: [MdItem])
}

public enum Markdown {
    // private-use sentinels standing in for markup while the inline regexes run
    private static let codeMark = "\u{E000}", linkOpen = "\u{E001}", linkMid = "\u{E002}", linkClose = "\u{E003}"
    private static let bOpen = "\u{E004}", bClose = "\u{E005}", iOpen = "\u{E006}", iClose = "\u{E007}"
    private static let sOpen = "\u{E008}", sClose = "\u{E009}", atOpen = "\u{E00A}", atClose = "\u{E00B}", urlMark = "\u{E00C}"

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let codeRE = re("(`+)([^`]|[^`][\\s\\S]*?[^`])\\1(?!`)")
    private static let linkRE = re("\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)")
    private static let urlRE = re("(^|[\\s(])(https?://[^\\s<)\(linkOpen)\(linkMid)\(linkClose)]+[^\\s<).,;:!?'\"\(linkOpen)\(linkMid)\(linkClose)])")
    private static let boldRE = [re("\\*\\*([^*]+)\\*\\*"), re("__([^_]+)__")]
    private static let italicRE = [re("(^|[^*A-Za-z0-9_])\\*([^*\\s][^*]*?)\\*(?![A-Za-z0-9_])"), re("(^|[^_A-Za-z0-9_])_([^_\\s][^_]*?)_(?![A-Za-z0-9_])")]
    private static let strikeRE = re("~~([^~]+)~~")
    private static let mentionRE = re("(^|[\\s(])@([A-Za-z0-9][\\w-]*)")
    private static let tokenRE = re("\(codeMark)(\\d+)\(codeMark)|\(urlMark)(\\d+)\(urlMark)")

    /// Replace every match, building each replacement from the match's groups.
    private static func sub(_ s: String, _ r: NSRegularExpression, _ f: ([String?]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let groups = (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            out += f(groups)
            at = m.range.upperBound
        }
        return out + ns.substring(from: at)
    }

    /// One line of inline markup as styled spans.
    public static func inline(_ src: String) -> MdLine {
        var codes: [String] = []
        var urls: [String] = []
        var s = sub(src, codeRE) { g in
            let body = g[2] ?? ""
            let trimmed = body.trimmingCharacters(in: .whitespaces).isEmpty ? body
                : (body.hasPrefix(" ") && body.hasSuffix(" ") && body.count >= 2 ? String(body.dropFirst().dropLast()) : body)
            codes.append(trimmed)
            return "\(codeMark)\(codes.count - 1)\(codeMark)"
        }
        s = sub(s, linkRE) { g in
            urls.append(g[2]!)
            return "\(linkOpen)\(urls.count - 1)\(linkMid)\(g[1]!)\(linkClose)"
        }
        s = sub(s, urlRE) { g in
            urls.append(g[2]!)
            return "\(g[1] ?? "")\(urlMark)\(urls.count - 1)\(urlMark)"
        }
        for r in boldRE { s = sub(s, r) { "\(bOpen)\($0[1]!)\(bClose)" } }
        for r in italicRE { s = sub(s, r) { "\($0[1] ?? "")\(iOpen)\($0[2]!)\(iClose)" } }
        s = sub(s, strikeRE) { "\(sOpen)\($0[1]!)\(sClose)" }
        s = sub(s, mentionRE) { "\($0[1] ?? "")\(atOpen)@\($0[2]!)\(atClose)" }
        return spans(s, codes: codes, urls: urls)
    }

    /// Walk the sentinel string into spans.
    private static func spans(_ s: String, codes: [String], urls: [String]) -> MdLine {
        var out: MdLine = []
        var cur = MdSpan("")
        func push(_ x: MdSpan) {
            guard !x.text.isEmpty else { return }
            if var last = out.last, last.bold == x.bold, last.italic == x.italic, last.strike == x.strike, last.code == x.code,
               last.mention == x.mention, last.link == x.link {
                last.text += x.text
                out[out.count - 1] = last
            } else { out.append(x) }
        }
        func flush() { push(cur); cur.text = "" }
        var chars = Array(s.unicodeScalars)[...]
        var pendingLink: Int?
        while let c = chars.first {
            chars = chars.dropFirst()
            let ch = String(c)
            switch ch {
            case codeMark, urlMark:
                var digits = ""
                while let d = chars.first, String(d) != ch { digits.unicodeScalars.append(d); chars = chars.dropFirst() }
                chars = chars.dropFirst()
                flush()
                let i = Int(digits) ?? 0
                if ch == codeMark { var x = cur; x.text = codes.indices.contains(i) ? codes[i] : ""; x.code = true; push(x) }
                else { var x = cur; x.text = urls.indices.contains(i) ? urls[i] : ""; x.link = x.text; push(x) }
            case linkOpen:
                var digits = ""
                while let d = chars.first, String(d) != linkMid { digits.unicodeScalars.append(d); chars = chars.dropFirst() }
                chars = chars.dropFirst()
                pendingLink = Int(digits)
                flush()
                cur.link = pendingLink.flatMap { urls.indices.contains($0) ? urls[$0] : nil }
            case linkClose: flush(); cur.link = nil
            case bOpen: flush(); cur.bold = true
            case bClose: flush(); cur.bold = false
            case iOpen: flush(); cur.italic = true
            case iClose: flush(); cur.italic = false
            case sOpen: flush(); cur.strike = true
            case sClose: flush(); cur.strike = false
            case atOpen: flush(); cur.mention = true
            case atClose: flush(); cur.mention = false
            default: cur.text.unicodeScalars.append(c)
            }
        }
        flush()
        return out
    }

    /// Bots (linear-code) post HTML: their links and paragraphs become markdown; any other tag stays text.
    private static func fromHtml(_ s: String) -> String {
        guard s.range(of: "^\\s*<p>", options: [.regularExpression, .caseInsensitive]) != nil else { return s }
        var t = sub(s, re("<a\\s+href=\"(https?://[^\"]+)\"[^>]*>([^<]*)</a>", [.caseInsensitive])) { "[\($0[2]!)](\($0[1]!))" }
        t = t.replacingOccurrences(of: "</p>\\s*<p>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        return t.replacingOccurrences(of: "</?p>|<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    private static func matches(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
    private static func groups(_ s: String, _ r: NSRegularExpression) -> [String?]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
    }
    private static let fenceRE = re("^\\s*(```|~~~)\\s*([\\w-]*)")
    private static let headingRE = re("^(#{1,6})\\s+(.*)$")
    private static let listRE = re("^(\\s*)([-*+]|\\d+[.)])\\s+(.*)$")
    private static let taskRE = re("^\\[([ xX])\\]\\s+(.*)$")
    private static let tableRule = "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$"
    private static func indentOf(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }

    /// A table row's cells: split on pipes that aren't escaped or inside backticks.
    private static func cells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        var out: [String] = []
        var cur = ""
        var tick = false
        let cs = Array(s)
        var i = 0
        while i < cs.count {
            let ch = cs[i]
            if ch == "\\" && i + 1 < cs.count && cs[i + 1] == "|" { cur.append("|"); i += 1 }
            else if ch == "`" { tick.toggle(); cur.append(ch) }
            else if ch == "|" && !tick { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
            else { cur.append(ch) }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Parse markdown into blocks. `replaces` are the lines a ```suggestion replaces, shown above it as removals.
    public static func parse(_ src: String, replaces: [String] = []) -> [MdBlock] {
        let normalized = src.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let lines = fromHtml(normalized).components(separatedBy: "\n")
        var out: [MdBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.map(inline))) }
            para = []
        }
        var i = 0
        while i < lines.count {
            let ln = lines[i]
            if let f = groups(ln, fenceRE) {
                flush()
                let mark = f[1]!
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].drop { $0 == " " || $0 == "\t" }.hasPrefix(mark) { body.append(lines[i]); i += 1 }
                let lang = f[2] ?? ""
                out.append(lang == "suggestion" ? .suggestion(removes: replaces, adds: body) : .code(lang: lang, lines: body))
                i += 1
                continue
            }
            if let h = groups(ln, headingRE) {
                flush()
                out.append(.heading(level: h[1]!.count, inline(h[2] ?? "")))
                i += 1
                continue
            }
            if matches(ln, "^\\s*([-*_])(\\s*\\1){2,}\\s*$") {
                flush()
                out.append(.rule)
                i += 1
                continue
            }
            if matches(ln, "^\\s*>") {
                flush()
                var quote: [String] = []
                while i < lines.count && matches(lines[i], "^\\s*>") {
                    quote.append(lines[i].replacingOccurrences(of: "^\\s*> ?", with: "", options: .regularExpression))
                    i += 1
                }
                out.append(.quote(parse(quote.joined(separator: "\n"), replaces: replaces)))
                continue
            }
            if matches(ln, "^\\s*\\|.*\\|\\s*$"), i + 1 < lines.count, matches(lines[i + 1], tableRule) {
                flush()
                var rows = [cells(ln)]
                i += 2
                while i < lines.count && matches(lines[i], "^\\s*\\|.*\\|\\s*$") { rows.append(cells(lines[i])); i += 1 }
                out.append(.table(head: rows[0].map(inline), rows: rows.dropFirst().map { $0.map(inline) }))
                continue
            }
            if let li = groups(ln, listRE) {
                flush()
                let base = li[1]!.count
                let ordered = li[2]!.first!.isNumber
                var items: [(text: String, sub: [String])] = []
                scan: while i < lines.count {
                    let m = groups(lines[i], listRE)
                    if let m, m[1]!.count == base { items.append((m[3] ?? "", [])) }
                    else if let m, m[1]!.count > base, !items.isEmpty { items[items.count - 1].sub.append(lines[i]) }
                    else if m == nil, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, matches(lines[i], "^\\s{2,}"), !items.isEmpty {
                        if items[items.count - 1].sub.isEmpty { items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces) }
                        else { items[items.count - 1].sub.append(lines[i]) }
                    } else if lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !items.isEmpty {
                        // a blank line inside a loose list: it goes on if what follows is its next item or indented under it
                        var j = i + 1
                        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        let next = j < lines.count ? lines[j] : ""
                        let indent = indentOf(next)
                        if let m2 = groups(next, listRE), m2[1]!.count == base { i += 1; continue scan }
                        if indent > base && indent >= 2 { items[items.count - 1].sub.append("") } else { break scan }
                    } else { break scan }
                    i += 1
                }
                let first = Int(li[2]!.prefix { $0.isNumber }) ?? 1
                let parsed = items.map { it -> MdItem in
                    let task = groups(it.text, taskRE)
                    let head = task.map { inline($0[2] ?? "") } ?? inline(it.text)
                    let nonBlank = it.sub.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    let indent = nonBlank.map(indentOf).min() ?? 0
                    let nested = it.sub.isEmpty ? [] : parse(it.sub.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n"), replaces: replaces)
                    return MdItem(task: task.map { $0[1] != " " }, text: head, children: nested)
                }
                out.append(.list(ordered: ordered, start: ordered ? first : 1, items: parsed))
                continue
            }
            if ln.trimmingCharacters(in: .whitespaces).isEmpty { flush(); i += 1; continue }
            para.append(ln)
            i += 1
        }
        flush()
        return out
    }

    /// The first ```suggestion block's lines, or nil (mirrors srv/reviewdesk.suggestion_of).
    public static func suggestionOf(_ body: String) -> [String]? {
        let b = body.replacingOccurrences(of: "\r\n", with: "\n")
        guard let g = groups(b, re("^```suggestion[^\\n]*\\n([\\s\\S]*?)^```", [.anchorsMatchLines])) else { return nil }
        let inner = g[1] ?? ""
        if inner.isEmpty { return [] }
        return (inner.hasSuffix("\n") ? String(inner.dropLast()) : inner).components(separatedBy: "\n")
    }

    /// One line of plain text from markdown, for a folded summary.
    public static func plain(_ src: String, max: Int = 140) -> String {
        var s = src.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[`*_>#~]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    /// Every block's text, flattened — for tests and search.
    public static func text(_ blocks: [MdBlock]) -> String {
        func line(_ l: MdLine) -> String { l.map(\.text).joined() }
        return blocks.map { b -> String in
            switch b {
            case .paragraph(let ls): return ls.map(line).joined(separator: "\n")
            case .heading(_, let l): return line(l)
            case .code(_, let ls): return ls.joined(separator: "\n")
            case .suggestion(let r, let a): return (r.map { "-\($0)" } + a.map { "+\($0)" }).joined(separator: "\n")
            case .rule: return "---"
            case .quote(let bs): return text(bs)
            case .table(let h, let rows): return ([h] + rows).map { $0.map(line).joined(separator: " | ") }.joined(separator: "\n")
            case .list(_, _, let items):
                return items.map { it in
                    let box = it.task.map { $0 ? "☑ " : "☐ " } ?? ""
                    return box + line(it.text) + (it.children.isEmpty ? "" : "\n" + text(it.children))
                }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}
