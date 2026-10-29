import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// wikitext.test.ts, ported, plus the page read back into blocks and the wiki driven by keys.
@MainActor @Suite struct WikiTextTests {
    func page(_ slug: String, _ section: String) -> WikiPage { WikiPage(slug: slug, title: slug, section: section) }
    func matches(_ s: String, _ pattern: String) -> Bool { Rx.test(pattern, s) }

    @Test func sectionsKeepTheServersPageOrderAndTheirOwnFirstAppearance() {
        let s = WikiText.sectionsOf([page("a", "Mail"), page("b", "Canopy"), page("c", "Mail")])
        #expect(s.map(\.name) == ["Mail", "Canopy"])
        #expect(s.map { $0.pages.map(\.slug) } == [["a", "c"], ["b"]])
    }

    @Test func aCitationIsAButtonCarryingItsAnchorItsLabelStillMarkdown() {
        let html = WikiText.html("Every route returns a [`nextPage` URL](src:lib/rest-api/pagination.ts#buildPaginationMeta).")
        #expect(matches(html, #"<button class="wk-cite" data-anchor="lib/rest-api/pagination.ts#buildPaginationMeta"[^>]*><code class="md-code">nextPage</code> URL</button>"#), "\(html)")
        #expect(!html.contains("src:"))
    }

    @Test func aWikilinkNamesThePageByItsTitleWhenItsKnown() {
        #expect(matches(WikiText.html("see [[canopy-v2-keys]]") { $0 == "canopy-v2-keys" ? "Keys like Helix" : nil }, #"data-slug="canopy-v2-keys">Keys like Helix</a>"#))
        #expect(matches(WikiText.html("see [[no-such]]"), ">no such</a>"))
        #expect(matches(WikiText.html("(see [Keys like Helix](canopy-v2-keys))"),
                        #"\(see <a class="wk-link" href="/v2/wiki/canopy-v2-keys" data-slug="canopy-v2-keys">Keys like Helix</a>\)"#))
    }

    @Test func anAnchorCantBreakOutOfItsAttributeAndProseAroundItIsStillEscaped() {
        let html = WikiText.html(#"<b>x</b> [y](src:a"onclick="z)"#)
        #expect(html.contains("&lt;b&gt;x&lt;/b&gt;"))
        #expect(html.contains(#"data-anchor="a&quot;onclick=&quot;z""#))
    }

    @Test func tablesRenderAPipeInsideCodeStayingInItsCell() {
        let html = WikiText.html("| key | was |\n|---|---|\n| `a | b` | `space` |\n| x | y |")
        #expect(html.contains(#"<table class="md-table"><thead><tr><th>key</th><th>was</th></tr></thead>"#), "\(html)")
        #expect(html.contains(#"<td><code class="md-code">a | b</code></td><td><code class="md-code">space</code></td>"#))
        #expect(html.contains("<td>x</td><td>y</td></tr></tbody></table>"))
    }

    @Test func anIndentedListNestsUnderItsItem() {
        let html = WikiText.html("1. **Motion.** first\n2. **Actions** each:\n   - thread header\n   - pending draft\n\n   Other keys.\n3. Third")
        #expect(html == "<ol><li><strong>Motion.</strong> first</li><li><strong>Actions</strong> each:<ul><li>thread header</li><li>pending draft</li></ul><p>Other keys.</p></li><li>Third</li></ol>")
        #expect(WikiText.html("4. four\n5. five").hasPrefix(#"<ol start="4">"#))
    }

    // ── the HTML read back into blocks ──

    @Test func linksAreNumberedInReadingOrderWithTheirBlock() {
        let doc = Prose.doc(WikiText.html("Intro [a](src:x.ts#A) and [[hop-peek]].\n\nPlain.\n\n- one [b](src:y.ts#B)\n- see https://example.com"))
        #expect(doc.blocks.count == 3)
        #expect(doc.links.map(\.link.kind) == [.cite("x.ts#A"), .page("hop-peek"), .cite("y.ts#B"), .url("https://example.com")])
        #expect(doc.links.map(\.block) == [0, 0, 2, 2])
        guard case .para(let ins) = doc.blocks[0] else { Issue.record("not a paragraph"); return }
        #expect(Prose.text(ins) == "Intro a and hop peek.")
    }

    @Test func styledRunsAndBlocksSurviveTheRoundTrip() {
        let doc = Prose.doc(WikiText.html("## Head\n\n**bold** *it* ~~gone~~ `c<d>` @someone\n\n```\nlet x = 1 < 2\n```\n\n> quoted\n\n---\n\n- [x] done"))
        #expect(doc.blocks.count == 6)
        if case .heading(2, let h) = doc.blocks[0] { #expect(Prose.text(h) == "Head") } else { Issue.record("no heading") }
        if case .para(let ins) = doc.blocks[1] {
            #expect(ins.contains(.text("bold", .bold)))
            #expect(ins.contains(.text("it", .italic)))
            #expect(ins.contains(.text("gone", .del)))
            #expect(ins.contains(.text("c<d>", .code)))
            #expect(ins.contains(.text("@someone", .at)))
        } else { Issue.record("no paragraph") }
        #expect(doc.blocks[2] == .code("let x = 1 < 2"))
        #expect(doc.blocks[4] == .rule)
        if case .list(false, _, let items) = doc.blocks[5] { #expect(items.first?.task == true && Prose.text(items[0].head) == "☑ done") } else { Issue.record("no list") }
    }

    @Test func theSavedPagesDecodeAndEveryBodyRenders() throws {
        let r = try JSONDecoder().decode(PagesReply.self, from: Data(WikiFixture.pages.utf8))
        #expect(r.pages.count == 5)
        #expect(r.ref == "origin/main")
        for p in r.pages {
            let d = Prose.doc(WikiText.html(p.body))
            #expect(!d.blocks.isEmpty, "\(p.slug)")
            #expect(!WikiText.html(p.body).contains("src:"), "\(p.slug)")
        }
        let birth = r.pages.first { $0.slug == "hop-birth" }!
        #expect(Prose.doc(WikiText.html(birth.body)).links.filter { if case .cite = $0.link.kind { true } else { false } }.count == 3)
    }
}

@MainActor @Suite struct WikiTests {
    func app(_ slug: String? = nil) throws -> AppModel {
        var c = AppConfig()
        c.route = .wiki(slug: slug)
        let a = AppModel(config: c, port: 1, telemetry: false)
        a.state { WikiState() }.seed(try JSONDecoder().decode(PagesReply.self, from: Data(WikiFixture.pages.utf8)))
        a.state { WikiState() }.arrive(a)
        return a
    }

    var wiki: (AppModel) -> WikiState { { $0.state { WikiState() } } }

    @Test func theWikisCommandsAreAllReachableByKey() throws {
        let a = try app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("wiki.") || $0 == "find.wiki" }.isEmpty)
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    @Test func theListIsDrawnSectionBySectionAndTheURLsPageIsUnderTheCursor() throws {
        let a = try app("hop-park")
        let w = wiki(a)
        #expect(w.listRows == WikiText.sectionsOf(w.pages).flatMap { $0.pages.map { RowKey.wiki($0.slug) } })
        #expect(a.pane?.id == "pages")
        #expect(a.selected == "w:hop-park")
        #expect(a.liveScopes().first == .article)
        #expect(a.target(for: .article) == "hop-park")
    }

    @Test func noSlugOpensTheFirstPage() throws {
        let a = try app()
        #expect(wiki(a).current(a)?.slug == wiki(a).pages.first?.slug)
    }

    @Test func retOnTheListOpensThePage() throws {
        let a = try app()
        a.setCursor("w:hop-birth")
        a.keys.handle("ret")
        #expect(a.router.route == .wiki(slug: "hop-birth"))
        #expect(a.selected == "w:hop-birth")
    }

    @Test func thePageCursorStopsAtEachLinkAndRetFollowsAWikilink() throws {
        let a = try app("hop-birth")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.pane?.id == "page")
        #expect(!a.liveScopes().contains(.article), "the list's ret isn't live on the page")
        let rows = a.rows
        #expect(rows.first?.hasPrefix("k:") == true, "the first paragraph has no link")
        // the stops walk the citations and wikilinks in reading order
        let w = wiki(a)
        let kinds = rows.compactMap { w.link($0, a)?.kind }
        #expect(kinds.prefix(4) == [.cite("lib/send-mail.ts#getPriority"), .page("enqueued-email"), .page("status-log"), .cite("lib/mail-send-tokens.ts#HIGH_PRIORITY_THRESHOLD")])
        // enqueued-email isn't in the fixture: ret refuses quietly and stays
        a.setCursor(rows.first { w.link($0, a)?.kind == .page("enqueued-email") })
        a.keys.handle("ret")
        #expect(a.router.route == .wiki(slug: "hop-birth"))
        // from the overview, hop-park is in the fixture: ret follows it, the cursor reads from the new page's top
        a.runner.dispatch("wiki.open", via: .key, target: "overview")
        #expect(a.pane?.id == "page")
        a.setCursor(a.rows.first { w.link($0, a)?.kind == .page("hop-park") })
        a.keys.handle("ret")
        #expect(a.router.route == .wiki(slug: "hop-park"))
        #expect(a.pane?.id == "page")
        #expect(a.cursorIdx == 0)
        a.keys.handle("C-w"); a.keys.handle("h")
        #expect(a.selected == "w:hop-park")
    }

    @Test func retOnACitationOpensItsLinesAndEscPutsThemAway() throws {
        let a = try app("hop-birth")
        let w = wiki(a)
        a.focus(pane: "page")
        a.setCursor(a.rows.first { w.link($0, a)?.kind == .cite("lib/send-mail.ts#getPriority") })
        a.keys.handle("ret")
        #expect(w.cite?.anchor == "lib/send-mail.ts#getPriority")
        #expect(a.panes.map(\.id) == ["pages", "page", "source"])
        // the lines arrive: the source pane's cursor lands on the cited ones
        w.cite = WikiState.Cite(anchor: "lib/send-mail.ts#getPriority", src: try JSONDecoder().decode(SrcReply.self, from: Data(WikiFixture.src.utf8)))
        w.landSource(a)
        #expect(a.pane?.id == "page")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.pane?.id == "source")
        #expect(a.rows == (35...40).map { "s:\($0)" })
        #expect(a.selected == "s:38")
        // esc cancels: the citation closes, focus goes back to the page, and the page never changes
        a.keys.handle("esc")
        #expect(w.cite == nil)
        #expect(a.pane?.id == "page")
        #expect(a.router.route == .wiki(slug: "hop-birth"))
        a.keys.handle("esc")
        #expect(a.router.route == .wiki(slug: "hop-birth"))
    }

    @Test func theSameCitationAgainPutsItAway() throws {
        let a = try app("hop-birth")
        let w = wiki(a)
        a.runner.dispatch("wiki.cite", via: .click, target: "x#y")
        #expect(w.cite?.anchor == "x#y")
        a.runner.dispatch("wiki.cite", via: .click, target: "x#y")
        #expect(w.cite == nil)
    }

    @Test func theFinderOpensAPage() throws {
        let a = try app()
        a.runner.dispatch("find.wiki", via: .palette, arg: "api-pagination")
        #expect(a.router.route == .wiki(slug: "api-pagination"))
        #expect(a.selected == "w:api-pagination")
    }

    @Test func aPlanPageGoesToItsForestOnlyWhenTheStoreHasIt() throws {
        let a = try app("api-pagination")
        #expect(wiki(a).current(a)?.isPlan == true)
        #expect(a.registry.command("wiki.forest")?.available?(nil) == false)
    }

    @Test func anUnknownSlugIsNoPage() throws {
        let a = try app("nope")
        #expect(wiki(a).current(a) == nil)
        #expect(a.panes.first { $0.id == "page" }?.rows.isEmpty == true)
    }
}
