import Foundation

// The wiki's pages as the page draws them (wikitext.ts, srv/wiki.py): grouped by section in the
// server's order, and a body's two kinds of link — a citation `[label](src:<anchor>)` (a map page's
// claim, resolved against origin/main) and a wikilink `[[slug]]` — swapped for markup around the
// shared markdown renderer, which escapes everything else. Pure.

/// One page of GET /wiki-pages.
struct WikiPage: Decodable, Equatable, Identifiable {
    var slug: String
    var title: String
    var section: String
    var order: Double
    var lede: String
    /// a design page's forest; empty on a map page
    var project: String
    /// "map" | "design"
    var kind: String
    var body: String
    var words: Int

    var id: String { slug }
    var isPlan: Bool { kind == "design" }

    init(slug: String, title: String, section: String, order: Double = 0, lede: String = "", project: String = "", kind: String = "map", body: String = "", words: Int = 0) {
        self.slug = slug; self.title = title; self.section = section; self.order = order; self.lede = lede
        self.project = project; self.kind = kind; self.body = body; self.words = words
    }

    enum CodingKeys: String, CodingKey { case slug, title, section, order, lede, project, kind, body, words }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = (try? c.decode(String.self, forKey: .title)) ?? slug
        section = (try? c.decode(String.self, forKey: .section)) ?? ""
        order = (try? c.decode(Double.self, forKey: .order)) ?? 0
        lede = (try? c.decode(String.self, forKey: .lede)) ?? ""
        project = (try? c.decode(String.self, forKey: .project)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "map"
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        words = (try? c.decode(Int.self, forKey: .words)) ?? 0
    }
}

/// GET /wiki-pages.
struct PagesReply: Decodable, Equatable {
    var pages: [WikiPage]
    var ref: String
    var repo: String
    var problems: [String]
    var err: String?
    /// where pages were looked for, and which of those exist — none, with no pages, is a misconfiguration
    var searched: [String]?
    var roots: [String]?

    init(pages: [WikiPage] = [], ref: String = "", repo: String = "", problems: [String] = [], err: String? = nil, searched: [String]? = nil, roots: [String]? = nil) {
        self.pages = pages; self.ref = ref; self.repo = repo; self.problems = problems; self.err = err; self.searched = searched; self.roots = roots
    }

    enum CodingKeys: String, CodingKey { case pages, ref, repo, problems, err, searched, roots }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pages = (try? c.decode([WikiPage].self, forKey: .pages)) ?? []
        ref = (try? c.decode(String.self, forKey: .ref)) ?? ""
        repo = (try? c.decode(String.self, forKey: .repo)) ?? ""
        problems = (try? c.decode([String].self, forKey: .problems)) ?? []
        err = try? c.decode(String.self, forKey: .err)
        searched = try? c.decode([String].self, forKey: .searched)
        roots = try? c.decode([String].self, forKey: .roots)
    }
}

/// GET /wiki-src: a citation's lines at origin/main.
struct SrcReply: Decodable, Equatable {
    var path: String
    var start: Int
    var end: Int
    /// the first line of `text` (a few lines of context above `start`)
    var from: Int
    var text: String
    var ref: String
    var err: String?

    init(path: String, start: Int = 0, end: Int = 0, from: Int = 0, text: String = "", ref: String = "", err: String? = nil) {
        self.path = path; self.start = start; self.end = end; self.from = from; self.text = text; self.ref = ref; self.err = err
    }

    enum CodingKeys: String, CodingKey { case path, start, end, from, text, ref, err }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        err = try? c.decode(String.self, forKey: .err)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        start = (try? c.decode(Int.self, forKey: .start)) ?? 0
        end = (try? c.decode(Int.self, forKey: .end)) ?? 0
        from = (try? c.decode(Int.self, forKey: .from)) ?? 0
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        ref = (try? c.decode(String.self, forKey: .ref)) ?? ""
    }
}

enum WikiText {
    static let cite = "\\[([^\\]]+)\\]\\(src:([^)\\s]+)\\)"
    static let wikilink = "\\[\\[([a-z0-9-]+)\\]\\]"
    /// `[label](slug)` — a plain markdown link to another page by its bare slug
    static let pagelink = "\\[([^\\]]+)\\]\\(([a-z0-9-]+)\\)"

    static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Sections in first-appearance order: the pages arrive sorted by `order`, so the grouping inherits it.
    static func sectionsOf(_ pages: [WikiPage]) -> [(name: String, pages: [WikiPage])] {
        var out: [(name: String, pages: [WikiPage])] = []
        for p in pages {
            if let i = out.firstIndex(where: { $0.name == p.section }) { out[i].pages.append(p) } else { out.append((p.section, [p])) }
        }
        return out
    }

    /// A page body as HTML: citations become buttons carrying their anchor, wikilinks links named by
    /// the page's title when it's known. Held out of the renderer as placeholders, so it never sees `src:`.
    static func html(_ body: String, titleOf: (String) -> String? = { _ in nil }) -> String {
        var held: [String] = []
        func hold(_ h: String) -> String {
            held.append(h)
            return "\u{1}\(held.count - 1)\u{1}"
        }
        var src = Rx.replace(body, cite) { g in
            hold("<button class=\"wk-cite\" data-anchor=\"\(attr(g[2]))\" title=\"\(attr(g[2]))\">\(WikiMarkdown.inline(g[1]))</button>")
        }
        src = Rx.replace(src, wikilink) { g in
            hold("<a class=\"wk-link\" href=\"/v2/wiki/\(g[1])\" data-slug=\"\(g[1])\">\(attr(titleOf(g[1]) ?? g[1].replacingOccurrences(of: "-", with: " ")))</a>")
        }
        src = Rx.replace(src, pagelink) { g in
            hold("<a class=\"wk-link\" href=\"/v2/wiki/\(g[2])\" data-slug=\"\(g[2])\">\(WikiMarkdown.inline(g[1]))</a>")
        }
        return Rx.replace(WikiMarkdown.render(src), "\u{1}(\\d+)\u{1}") { g in held[Int(g[1])!] }
    }
}
