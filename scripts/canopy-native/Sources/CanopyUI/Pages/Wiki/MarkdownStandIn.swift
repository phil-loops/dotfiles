import Foundation

/// The markdown renderer the wiki consumes. Area C (Ship) publishes the real one, ported from
/// review/markdown.ts; until it lands this stand-in is a line-for-line port of the same file, so the
/// wiki renders and its tests pass. The seam is exactly markdown.ts's two exports the wiki uses:
///
///     static func inline(_ src: String) -> String                  // one line → safe HTML
///     static func render(_ src: String, replaces: [String]) -> String   // a body → safe HTML
///
/// Coordinator: point `WikiMarkdown` at C's type (or delete this file and alias C's) when it lands.
typealias WikiMarkdown = MarkdownStandIn

/// GitHub-flavoured markdown rendered SAFELY (markdown.ts): everything is HTML-escaped first and
/// only the constructs below become markup. Blocks: fenced code (```suggestion as a suggested
/// change), headings, quotes, lists (task boxes too), tables, rules, paragraphs with hard breaks.
/// Inline: code, bold, italic, strikethrough, http(s) links and bare URLs, @mentions. HTML comments
/// are dropped. Pure.
enum MarkdownStandIn {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ src: String) -> String {
        var codes: [String] = []
        var s = Rx.replace(src, "(`+)([^`]|[^`][\\s\\S]*?[^`])\\1(?!`)") { g in
            let body = g[2]
            let inner = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? body : Rx.replace(body, "^ (.*) $", template: "$1")
            codes.append("<code class=\"md-code\">\(esc(inner))</code>")
            return "\u{0}\(codes.count - 1)\u{0}"
        }
        s = esc(s)
        s = Rx.replace(s, "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)") { g in "<a href=\"\(g[2])\" target=\"_blank\" rel=\"noopener noreferrer\">\(g[1])</a>" }
        s = Rx.replace(s, "(^|[\\s(])(https?://[^\\s<)]+[^\\s<).,;:!?'\"])") { g in
            "\(g[1])<a href=\"\(g[2])\" target=\"_blank\" rel=\"noopener noreferrer\">\(g[2])</a>"
        }
        s = Rx.replace(s, "\\*\\*([^*]+)\\*\\*", template: "<strong>$1</strong>")
        s = Rx.replace(s, "__([^_]+)__", template: "<strong>$1</strong>")
        s = Rx.replace(s, "(^|[^*\\w])\\*([^*\\s][^*]*?)\\*(?!\\w)", template: "$1<em>$2</em>")
        s = Rx.replace(s, "(^|[^_\\w])_([^_\\s][^_]*?)_(?!\\w)", template: "$1<em>$2</em>")
        s = Rx.replace(s, "~~([^~]+)~~", template: "<del>$1</del>")
        s = Rx.replace(s, "(^|[\\s(])@([A-Za-z0-9][\\w-]*)", template: "$1<span class=\"md-at\">@$2</span>")
        return Rx.replace(s, "\u{0}(\\d+)\u{0}") { g in codes[Int(g[1])!] }
    }

    private static func fence(_ lang: String, _ body: [String], _ replaces: [String]) -> String {
        if lang == "suggestion" {
            let old = replaces.map { "<div class=\"md-sg-del\"><span>-</span>\(esc($0).isEmpty ? " " : esc($0))</div>" }.joined()
            let neu = body.map { "<div class=\"md-sg-add\"><span>+</span>\(esc($0).isEmpty ? " " : esc($0))</div>" }.joined()
            return "<div class=\"md-suggestion\"><div class=\"md-sg-head\">Suggested change</div><pre>\(old)\(neu.isEmpty ? "<div class=\"md-sg-empty\">(removes the lines)</div>" : neu)</pre></div>"
        }
        return "<pre class=\"md-pre\"><code>\(esc(body.joined(separator: "\n")))</code></pre>"
    }

    /// Bots post HTML: their links and paragraphs become markdown, the rest is escaped as usual.
    private static func fromHtml(_ s: String) -> String {
        guard Rx.test("(?i)^\\s*<p>", s) else { return s }
        var t = Rx.replace(s, "(?i)<a\\s+href=\"(https?://[^\"]+)\"[^>]*>([^<]*)</a>", template: "[$2]($1)")
        t = Rx.replace(t, "(?i)</p>\\s*<p>", template: "\n\n")
        return Rx.replace(t, "(?i)</?p>|<br\\s*/?>", template: "\n")
    }

    private static let listItem = "^(\\s*)([-*+]|\\d+[.)])\\s+(.*)$"
    private static let tableRule = "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$"
    private static let tableRow = "^\\s*\\|.*\\|\\s*$"

    /// A table row's cells: split on pipes that aren't escaped or inside backticks.
    static func cells(_ row: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var tick = false
        var s = row.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let cs = Array(s)
        var i = 0
        while i < cs.count {
            let ch = cs[i]
            if ch == "\\", i + 1 < cs.count, cs[i + 1] == "|" {
                cur += "|"
                i += 1
            } else if ch == "`" {
                tick.toggle()
                cur.append(ch)
            } else if ch == "|", !tick {
                out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines))
                cur = ""
            } else {
                cur.append(ch)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines))
        return out
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func indentOf(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }

    static func render(_ src: String, replaces: [String] = []) -> String {
        let cleaned = Rx.replace(Rx.replace(src, "\\r\\n?", template: "\n"), "<!--[\\s\\S]*?-->", template: "")
        let lines = fromHtml(cleaned).components(separatedBy: "\n")
        var out: [String] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append("<p>\(para.map(inline).joined(separator: "<br>"))</p>") }
            para = []
        }
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let ln = lines[i]
            if let f = Rx.exec("^\\s*(```|~~~)\\s*([\\w-]*)", ln) {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].drop(while: { $0.isWhitespace }).hasPrefix(f[1]!) {
                    body.append(lines[i])
                    i += 1
                }
                out.append(fence(f[2] ?? "", body, replaces))
                continue
            }
            if let h = Rx.exec("^(#{1,6})\\s+(.*)$", ln) {
                flush()
                let n = h[1]!.count
                out.append("<h\(n) class=\"md-h\">\(inline(h[2] ?? ""))</h\(n)>")
                continue
            }
            if Rx.test("^\\s*([-*_])(\\s*\\1){2,}\\s*$", ln) {
                flush()
                out.append("<hr>")
                continue
            }
            if Rx.test("^\\s*>", ln) {
                flush()
                var quote: [String] = []
                while i < lines.count, Rx.test("^\\s*>", lines[i]) {
                    quote.append(Rx.replace(lines[i], "^\\s*> ?", template: ""))
                    i += 1
                }
                i -= 1
                out.append("<blockquote>\(render(quote.joined(separator: "\n"), replaces: replaces))</blockquote>")
                continue
            }
            if Rx.test(tableRow, ln), i + 1 < lines.count, Rx.test(tableRule, lines[i + 1]) {
                flush()
                var rows: [[String]] = [cells(ln)]
                i += 2
                while i < lines.count, Rx.test(tableRow, lines[i]) {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                i -= 1
                func row(_ r: [String], _ tag: String) -> String { "<tr>\(r.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined())</tr>" }
                out.append("<table class=\"md-table\"><thead>\(row(rows[0], "th"))</thead><tbody>\(rows.dropFirst().map { row($0, "td") }.joined())</tbody></table>")
                continue
            }
            if let li = Rx.exec(listItem, ln) {
                flush()
                let base = li[1]!.count
                let ordered = Rx.test("\\d", li[2]!)
                var items: [(text: String, sub: [String])] = []
                while i < lines.count {
                    let m = Rx.exec(listItem, lines[i])
                    if let m, m[1]!.count == base {
                        items.append((m[3] ?? "", []))
                    } else if let m, m[1]!.count > base, !items.isEmpty {
                        items[items.count - 1].sub.append(lines[i])
                    } else if m == nil, !blank(lines[i]), Rx.test("^\\s{2,}", lines[i]), !items.isEmpty {
                        if !items[items.count - 1].sub.isEmpty { items[items.count - 1].sub.append(lines[i]) }
                        else { items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespacesAndNewlines) }
                    } else if blank(lines[i]), !items.isEmpty {
                        // a blank line inside a loose list: it goes on if what follows is its next item or indented under it
                        var j = i + 1
                        while j < lines.count, blank(lines[j]) { j += 1 }
                        let next = j < lines.count ? lines[j] : ""
                        let m2 = Rx.exec(listItem, next)
                        let indent = indentOf(next)
                        if let m2, m2[1]!.count == base { i += 1; continue }
                        if indent > base && indent >= 2 { items[items.count - 1].sub.append("") } else { break }
                    } else {
                        break
                    }
                    i += 1
                }
                i -= 1
                let first = Int(li[2]!.filter(\.isNumber)) ?? 0
                let body = items.map { item -> String in
                    let task = Rx.exec("^\\[([ xX])\\]\\s+(.*)$", item.text)
                    let head = task.map { "\($0[1] == " " ? "☐" : "☑") \(inline($0[2] ?? ""))" } ?? inline(item.text)
                    let indents = item.sub.filter { !blank($0) }.map(indentOf)
                    let indent = indents.min() ?? 0
                    let nested = item.sub.isEmpty ? "" : render(item.sub.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n"), replaces: replaces)
                    return "<li\(task != nil ? " class=\"md-task\"" : "")>\(head)\(nested)</li>"
                }.joined()
                out.append(ordered ? "<ol\(first > 1 ? " start=\"\(first)\"" : "")>\(body)</ol>" : "<ul>\(body)</ul>")
                continue
            }
            if blank(ln) {
                flush()
                continue
            }
            para.append(ln)
        }
        flush()
        return out.joined()
    }
}
