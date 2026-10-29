import CanopyCore
import Foundation
import Observation

/// The wiki (wikiread.ts), read once per launch — GET /wiki-pages holds every page's body — and
/// kept: moving between pages never waits. A citation's lines come from GET /wiki-src at origin/main.
/// Also the page's cursor model: three panes — the page list, the page's stops (each link, and each
/// block with none, in reading order), and the open citation's lines.
@MainActor
@Observable
final class WikiState {
    var read: PagesReply?
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var docs: [String: ProseDoc] = [:]

    /// The citation open beside the page: its anchor, then its lines once they arrive.
    struct Cite: Equatable {
        var anchor: String
        var src: SrcReply?
    }
    var cite: Cite?

    static let listPane = "pages", pagePane = "page", sourcePane = "source"

    /// Read the pages, once — the menu's finder asks too.
    func load(_ app: AppModel) {
        guard !asked else { return }
        asked = true
        let t = app.transport
        Task { @MainActor in
            do {
                read = try await t.getJSON("/wiki-pages", as: PagesReply.self)
            } catch {
                asked = false
                read = PagesReply(err: String(describing: error))
            }
        }
    }

    /// Tests and previews: the pages as if the server had answered.
    func seed(_ r: PagesReply) {
        asked = true
        docs = [:]
        read = r
    }

    var pages: [WikiPage] { read?.pages ?? [] }
    func page(_ slug: String?) -> WikiPage? { slug.flatMap { s in pages.first { $0.slug == s } } }

    /// The page the URL names; the first page when it names none. nil for a slug that isn't a page.
    func current(_ app: AppModel) -> WikiPage? {
        guard case .wiki(let slug) = app.router.route else { return nil }
        return slug.map { page($0) } ?? pages.first
    }

    /// A page's body as the renderer draws it, read back into blocks (cached: pages don't change).
    func doc(_ p: WikiPage) -> ProseDoc {
        if let d = docs[p.slug] { return d }
        let d = Prose.doc(WikiText.html(p.body) { [weak self] s in self?.page(s)?.title })
        docs[p.slug] = d
        return d
    }

    // ── the panes ──

    /// The list's rows, as drawn: section by section.
    var listRows: [String] { WikiText.sectionsOf(pages).flatMap { $0.pages.map { RowKey.wiki($0.slug) } } }

    /// The page's stops in reading order: each link ("l:<n>"), and each block with none ("k:<i>").
    func pageRows(_ app: AppModel) -> [String] {
        guard let p = current(app) else { return [] }
        let d = doc(p)
        var out: [String] = []
        for i in d.blocks.indices {
            let here = d.links.filter { $0.block == i }
            if here.isEmpty { out.append("k:\(i)") } else { out += here.map { "l:\($0.link.n)" } }
        }
        return out
    }

    /// The open citation's lines ("s:<line>"), when they've arrived.
    var sourceRows: [String] {
        guard let s = cite?.src, s.err == nil else { return [] }
        return s.text.components(separatedBy: "\n").indices.map { "s:\(s.from + $0)" }
    }

    func link(_ row: String, _ app: AppModel) -> ProseLink? {
        guard row.hasPrefix("l:"), let n = Int(row.dropFirst(2)), let p = current(app) else { return nil }
        return doc(p).links.first { $0.link.n == n }?.link
    }

    /// The block a page stop sits in.
    func block(_ row: String, _ app: AppModel) -> Int? {
        if row.hasPrefix("k:") { return Int(row.dropFirst(2)) }
        guard let p = current(app), let l = link(row, app) else { return nil }
        return doc(p).links.first { $0.link == l }?.block
    }

    // ── moves ──

    /// The page the URL names is the one under the list's cursor when it opens, and reads from the top.
    func arrive(_ app: AppModel) {
        cite = nil
        let was = app.pane?.id
        app.focus(pane: Self.listPane)
        if let s = current(app)?.slug { app.setCursor(RowKey.wiki(s)) }
        if let was, was != Self.listPane {
            app.focus(pane: Self.pagePane)
            app.cursorTo(0)
        }
    }

    func go(_ slug: String, _ app: AppModel) {
        cite = nil
        app.go(.wiki(slug: slug))
        arrive(app)
    }

    /// Show a citation's lines (the same anchor again puts them away).
    func showCite(_ anchor: String?, _ app: AppModel) {
        guard let anchor, cite?.anchor != anchor else { return closeCite(app) }
        cite = Cite(anchor: anchor)
        let t = app.transport
        Task { @MainActor [weak self, weak app] in
            var src: SrcReply
            do {
                src = try await t.getJSON("/wiki-src?anchor=\(anchor.uriComponent)", as: SrcReply.self)
            } catch {
                src = SrcReply(path: anchor, err: String(describing: error))
            }
            guard let self, self.cite?.anchor == anchor else { return }
            self.cite = Cite(anchor: anchor, src: src)
            if let app { self.landSource(app) }
        }
    }

    /// Put the source pane's cursor on the cited lines, so C-w l lands there.
    func landSource(_ app: AppModel) {
        guard let s = cite?.src, s.err == nil else { return }
        let was = app.pane?.id
        app.focus(pane: Self.sourcePane)
        app.setCursor("s:\(s.start)")
        if let was { app.focus(pane: was) }
    }

    func closeCite(_ app: AppModel) {
        let inSource = app.pane?.id == Self.sourcePane
        cite = nil
        if inSource { app.focus(pane: Self.pagePane) }
    }

    /// The forest a plan page describes, when the store has it.
    func planForest(_ app: AppModel) -> Project? {
        guard let p = current(app), p.isPlan else { return nil }
        return app.store.view(Project.self, "\(read?.repo ?? ""):\(p.project)")
    }
}
