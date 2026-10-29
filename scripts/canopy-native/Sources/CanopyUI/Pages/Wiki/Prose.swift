import Foundation

// The renderer's safe HTML, read back into blocks a SwiftUI view can draw. The markdown renderer
// escapes everything and emits only a closed set of tags (markdown.ts + wikitext.ts), so this reads
// exactly that set: p br h1-6 hr blockquote pre code ul ol li table thead tbody tr th td strong em
// del span.md-at a button.wk-cite div.md-suggestion. Anything else is kept as its text. Pure.

struct ProseStyle: OptionSet, Hashable {
    let rawValue: Int
    static let bold = ProseStyle(rawValue: 1), italic = ProseStyle(rawValue: 2), del = ProseStyle(rawValue: 4)
    static let code = ProseStyle(rawValue: 8), at = ProseStyle(rawValue: 16)
}

/// A link in a page, numbered in reading order: a citation (its anchor), another page (its slug), or the web.
struct ProseLink: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case cite(String)
        case page(String)
        case url(String)
    }
    var n: Int
    var kind: Kind
}

indirect enum ProseInline: Equatable {
    case text(String, ProseStyle)
    case link(ProseLink, [ProseInline])
    case br
}

struct ProseItem: Equatable {
    var task: Bool
    var head: [ProseInline]
    var blocks: [ProseBlock]
}

indirect enum ProseBlock: Equatable {
    case para([ProseInline])
    case heading(Int, [ProseInline])
    case code(String)
    case quote([ProseBlock])
    case list(ordered: Bool, start: Int, items: [ProseItem])
    case table(head: [[ProseInline]], rows: [[[ProseInline]]])
    case rule
    /// a ```suggestion: each line with its sign ("-" or "+"); empty when it removes the lines
    case suggestion([SuggestionLine])
}

struct SuggestionLine: Equatable {
    var sign: String
    var text: String
}

/// A rendered page: its top-level blocks, and every link with the block it sits in.
struct ProseDoc: Equatable {
    var blocks: [ProseBlock] = []
    var links: [(link: ProseLink, block: Int)] = []

    static func == (a: ProseDoc, b: ProseDoc) -> Bool { a.blocks == b.blocks && a.links.map(\.link) == b.links.map(\.link) && a.links.map(\.block) == b.links.map(\.block) }
}

enum Prose {
    /// One element or a run of text, as the HTML nests them.
    indirect enum Node: Equatable {
        case text(String)
        case el(String, [String: String], [Node])

        var name: String? { if case .el(let n, _, _) = self { return n }; return nil }
        var attrs: [String: String] { if case .el(_, let a, _) = self { return a }; return [:] }
        var kids: [Node] { if case .el(_, _, let k) = self { return k }; return [] }
        var cls: String { attrs["class"] ?? "" }
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let void: Set<String> = ["br", "hr"]

    /// The tag tree of the renderer's HTML.
    static func nodes(_ html: String) -> [Node] {
        // a stack of open elements: (name, attrs, children so far)
        var stack: [(String, [String: String], [Node])] = [("", [:], [])]
        func add(_ n: Node) { stack[stack.count - 1].2.append(n) }
        func close() {
            let (name, attrs, kids) = stack.removeLast()
            add(.el(name, attrs, kids))
        }
        let s = Array(html.unicodeScalars)
        var i = 0
        var text = ""
        func flushText() {
            if !text.isEmpty { add(.text(decode(text))) }
            text = ""
        }
        while i < s.count {
            if s[i] == "<", let end = s[i...].firstIndex(of: ">") {
                flushText()
                let tag = String(String.UnicodeScalarView(s[(i + 1)..<end]))
                i = end + 1
                if tag.hasPrefix("/") {
                    let name = tag.dropFirst().lowercased()
                    if stack.dropFirst().contains(where: { $0.0 == name }) {
                        while stack.count > 1, stack.last!.0 != name { close() }
                        if stack.count > 1 { close() }
                    }
                    continue
                }
                let name = String(tag.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
                var attrs: [String: String] = [:]
                for m in Rx.re("([\\w-]+)=\"([^\"]*)\"").matches(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                    attrs[(tag as NSString).substring(with: m.range(at: 1))] = decode((tag as NSString).substring(with: m.range(at: 2)))
                }
                if void.contains(name) || tag.hasSuffix("/") { add(.el(name, attrs, [])) } else { stack.append((name, attrs, [])) }
            } else {
                text.unicodeScalars.append(s[i])
                i += 1
            }
        }
        flushText()
        while stack.count > 1 { close() }
        return stack[0].2
    }

    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "blockquote", "pre", "ul", "ol", "table", "div"]

    /// The renderer's HTML as a page: blocks, and its links numbered in reading order.
    static func doc(_ html: String) -> ProseDoc {
        var b = Builder()
        let blocks = b.blocks(nodes(html), top: true)
        return ProseDoc(blocks: blocks, links: b.links)
    }

    private struct Builder {
        var links: [(link: ProseLink, block: Int)] = []
        var block = 0

        mutating func blocks(_ ns: [Node], top: Bool = false) -> [ProseBlock] {
            var out: [ProseBlock] = []
            var loose: [Node] = []
            func flushLoose(_ me: inout Builder) {
                let ins = me.inlines(loose, [])
                if ins.contains(where: { if case .text(let t, _) = $0 { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true }) {
                    out.append(.para(ins))
                    if top { me.block += 1 }
                }
                loose = []
            }
            for n in ns {
                guard let name = n.name, Self.isBlock(n) else {
                    loose.append(n)
                    continue
                }
                flushLoose(&self)
                if let b = block(name, n) { out.append(b) }
                if top { block += 1 }
            }
            flushLoose(&self)
            return out
        }

        static func isBlock(_ n: Node) -> Bool { n.name.map { Prose.blockTags.contains($0) } ?? false }

        mutating func block(_ name: String, _ n: Node) -> ProseBlock? {
            switch name {
            case "p": return .para(inlines(n.kids, []))
            case "h1", "h2", "h3", "h4", "h5", "h6": return .heading(Int(name.dropFirst()) ?? 1, inlines(n.kids, []))
            case "hr": return .rule
            case "blockquote": return .quote(blocks(n.kids))
            case "pre": return .code(Prose.plain(n.kids))
            case "ul", "ol":
                let items = n.kids.filter { $0.name == "li" }.map { li -> ProseItem in
                    let head = li.kids.prefix { !Self.isBlock($0) }
                    let rest = li.kids.drop { !Self.isBlock($0) }
                    return ProseItem(task: li.cls.contains("md-task"), head: inlines(Array(head), []), blocks: blocks(Array(rest)))
                }
                return .list(ordered: name == "ol", start: Int(n.attrs["start"] ?? "") ?? 1, items: items)
            case "table":
                let sections = n.kids
                let headRow = sections.first { $0.name == "thead" }?.kids.first { $0.name == "tr" }
                let bodyRows = sections.first { $0.name == "tbody" }?.kids.filter { $0.name == "tr" } ?? []
                let head = headRow?.kids.filter { $0.name == "th" || $0.name == "td" }.map { inlines($0.kids, []) } ?? []
                let rows = bodyRows.map { r in r.kids.filter { $0.name == "th" || $0.name == "td" }.map { inlines($0.kids, []) } }
                return .table(head: head, rows: rows)
            case "div":
                if n.cls.contains("md-suggestion") {
                    let pre = n.kids.first { $0.name == "pre" }?.kids ?? []
                    return .suggestion(pre.compactMap { d in
                        if d.cls.contains("md-sg-del") || d.cls.contains("md-sg-add") {
                            return SuggestionLine(sign: d.cls.contains("md-sg-del") ? "-" : "+", text: Prose.plain(Array(d.kids.dropFirst())))
                        }
                        return nil
                    })
                }
                let inner = blocks(n.kids)
                return inner.count == 1 ? inner[0] : .quote(inner)
            default: return nil
            }
        }

        mutating func inlines(_ ns: [Node], _ style: ProseStyle) -> [ProseInline] {
            var out: [ProseInline] = []
            for n in ns {
                switch n {
                case .text(let t): out.append(.text(t, style))
                case .el(let name, let attrs, let kids):
                    switch name {
                    case "br": out.append(.br)
                    case "strong", "b": out += inlines(kids, style.union(.bold))
                    case "em", "i": out += inlines(kids, style.union(.italic))
                    case "del", "s": out += inlines(kids, style.union(.del))
                    case "code": out += inlines(kids, style.union(.code))
                    case "span": out += inlines(kids, n.cls.contains("md-at") ? style.union(.at) : style)
                    case "button", "a":
                        let kind: ProseLink.Kind? = attrs["data-anchor"].map { .cite($0) } ?? attrs["data-slug"].map { .page($0) } ?? attrs["href"].map { .url($0) }
                        guard let kind else {
                            out += inlines(kids, style)
                            continue
                        }
                        let link = ProseLink(n: links.count, kind: kind)
                        links.append((link, block))
                        out.append(.link(link, inlines(kids, style)))
                    default: out += inlines(kids, style)
                    }
                }
            }
            return out
        }
    }

    /// The text of nodes, tags dropped.
    static func plain(_ ns: [Node]) -> String {
        ns.map { n -> String in
            switch n {
            case .text(let t): t
            case .el(let name, _, let kids): name == "br" ? "\n" : (name == "div" ? plain(kids) + "\n" : plain(kids))
            }
        }.joined()
    }

    /// The text of inlines.
    static func text(_ ins: [ProseInline]) -> String {
        ins.map { i -> String in
            switch i {
            case .text(let t, _): t
            case .link(_, let k): text(k)
            case .br: "\n"
            }
        }.joined()
    }
}
