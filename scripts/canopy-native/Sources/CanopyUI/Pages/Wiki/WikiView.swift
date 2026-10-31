import CanopyCore
import SwiftUI

/// Wiki.tsx: the page list on the left (the cursor's: j/k move, ↵ opens), the page, and the open
/// citation's lines beside it. All three are panes — `C-w h/l` walks them, each keeps its cursor on
/// screen and shows its focus ring. On the page the cursor stops at each link in reading order (and
/// at each block with none), so `ret` follows a wikilink or opens a citation without a mouse.
struct WikiView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let wiki = app.state { WikiState() }
        Group {
            if let read = wiki.read {
                HStack(alignment: .top, spacing: 0) {
                    WikiList().frame(width: 260)
                    Group {
                        if let err = read.err {
                            Text(err).foregroundStyle(theme.del).padding(16)
                        } else if read.pages.isEmpty {
                            WikiEmpty(read: read).padding(16)
                        } else if let page = wiki.current(app) {
                            WikiArticle(page: page)
                        } else {
                            Text("no such page").foregroundStyle(theme.inkFaint).padding(16)
                        }
                    }
                    .frame(minWidth: 360, maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
                    if let c = wiki.cite {
                        WikiSource(cite: c).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("reading pages…").foregroundStyle(theme.inkFaint).padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { wiki.load(app) }
        .onChange(of: wiki.current(app)?.slug, initial: true) { _, slug in if slug != nil { wiki.arrive(app) } }
    }
}

private let label = Theme.mono(10.5)

/// The page list, section by section; the cursor row lit, the open page in gold.
struct WikiList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let wiki = app.state { WikiState() }
        let focused = app.isFocused(WikiState.listPane)
        let cursor = focused ? app.selected : nil
        let current = wiki.current(app)?.slug
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(WikiText.sectionsOf(wiki.pages), id: \.name) { s in
                        Text(s.name.uppercased()).font(label).tracking(1.4).foregroundStyle(theme.inkFaint)
                            .padding(.leading, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(s.pages) { p in
                            let key = RowKey.wiki(p.slug)
                            let on = key == cursor
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(p.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if p.isPlan {
                                    Text("PLAN").font(Theme.mono(9.5)).foregroundStyle(theme.ember).help("a plan for \(p.project)")
                                }
                            }
                            .font(Theme.mono(12.5))
                            .foregroundStyle(current == p.slug ? theme.goldLeaf : theme.inkDim)
                            .padding(.vertical, 3).padding(.leading, 10).padding(.trailing, 8)
                            .background(on ? theme.goldWash : .clear)
                            .overlay(alignment: .leading) { (on ? theme.goldLeaf : .clear).frame(width: 2) }
                            .contentShape(Rectangle())
                            .onTapGesture { app.runner.dispatch("wiki.open", via: .click, target: p.slug) }
                            .id(key)
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 16)
            }
            .onChange(of: cursor, initial: true) { _, k in if let k { proxy.scrollTo(k) } }
        }
        .overlay(alignment: .leading) { (focused ? theme.goldDeep : .clear).frame(width: 1) }
    }
}

/// No pages: either a root with nothing in it yet, or the wiki looking in the wrong place.
struct WikiEmpty: View {
    @Environment(\.theme) private var theme
    let read: PagesReply

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("no pages for \(read.repo)").font(Theme.display(17)).foregroundStyle(theme.ink)
            if let root = read.roots?.first {
                Text("add a markdown file to \(root)").foregroundStyle(theme.inkDim)
            } else {
                Text("none of these exist — the wiki is looking in the wrong place:").foregroundStyle(theme.inkDim)
                ForEach(read.searched ?? [], id: \.self) { Text($0).foregroundStyle(theme.del) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay { Rectangle().stroke(theme.del.opacity(0.7), lineWidth: 1) }
    }
}

/// One page: section, plan badge, title, lede, the prose, the word count.
struct WikiArticle: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let page: WikiPage

    var body: some View {
        let wiki = app.state { WikiState() }
        let doc = wiki.doc(page)
        let focused = app.isFocused(WikiState.pagePane)
        let row = focused ? app.selected : nil
        let look = ProseLook(theme: theme, cursorLink: row.flatMap { wiki.link($0, app)?.n },
                             openAnchor: wiki.cite?.anchor,
                             cursorBlock: row.flatMap { $0.hasPrefix("k:") ? Int($0.dropFirst(2)) : nil })
        let cursorBlock = row.flatMap { wiki.block($0, app) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(page.section.uppercased()).font(label).tracking(1.4).foregroundStyle(theme.inkFaint)
                            if page.isPlan {
                                Text("PLAN · \(page.project)").font(label).tracking(1.4).foregroundStyle(theme.ember)
                                    .help("the forest this plan describes — :wiki.forest")
                            }
                        }
                        Text(page.title).font(Theme.display(26)).foregroundStyle(theme.ink)
                        if !page.lede.isEmpty {
                            Text(page.lede).font(Theme.mono(14)).lineSpacing(4).foregroundStyle(theme.inkDim)
                        }
                    }
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) { theme.rule.frame(height: 1) }
                    .padding(.bottom, 24)
                    .id("top")
                    ProseView(doc: doc, look: look)
                    HStack(spacing: 0) {
                        Text("\(page.words) words")
                        if page.kind == "map" { Text(" · citations resolve against \(wiki.read?.ref ?? "")") }
                    }
                    .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                    .padding(.top, 12)
                    .overlay(alignment: .top) { theme.rule.frame(height: 1) }
                    .padding(.top, 32)
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .onChange(of: cursorBlock, initial: true) { _, b in
                guard let b else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(b == 0 ? "top" : "blk-\(b)", anchor: b == 0 ? .top : nil) }
            }
            .onChange(of: page.slug) { proxy.scrollTo("top", anchor: .top) }
        }
        .overlay(alignment: .leading) { (focused ? theme.goldDeep : .clear).frame(width: 1) }
    }
}

/// A citation's lines, the cited ones lit, a few either side for context. A pane: C-w l walks in,
/// j/k move line by line, the cursor kept on screen.
struct WikiSource: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let cite: WikiState.Cite

    var body: some View {
        let focused = app.isFocused(WikiState.sourcePane)
        let cursor = focused ? app.selected : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(cite.src.map { $0.path.isEmpty ? cite.anchor : $0.path } ?? cite.anchor)
                    .lineLimit(1).truncationMode(.head).foregroundStyle(theme.inkDim).help(cite.anchor)
                Spacer(minLength: 8)
                Text(cite.src.map { $0.err != nil ? "unresolved" : "\($0.start)–\($0.end) · \($0.ref)" } ?? "…").foregroundStyle(theme.inkFaint)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.vellumRaise)
            .overlay(alignment: .bottom) { theme.rule.frame(height: 1) }
            if let s = cite.src {
                if let err = s.err {
                    Text(err).font(Theme.mono(12)).foregroundStyle(theme.del).padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                let colors = CanvasColors(theme).code
                                let lang = langOf(s.path)
                                ForEach(Array(s.text.components(separatedBy: "\n").enumerated()), id: \.offset) { i, text in
                                    let n = s.from + i
                                    let lit = n >= s.start && n <= s.end
                                    let key = "s:\(n)"
                                    HStack(spacing: 0) {
                                        Text("\(n)").foregroundStyle(theme.inkFaint).frame(width: 44, alignment: .trailing).padding(.trailing, 12)
                                        Text(Self.highlighted(text, lang, colors)).foregroundStyle(lit ? theme.ink : theme.inkDim).fixedSize()
                                    }
                                    .font(Theme.mono(11.5))
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(key == cursor ? theme.goldWash : lit ? theme.goldWash.opacity(0.5) : .clear)
                                    .overlay(alignment: .leading) { (key == cursor ? theme.goldLeaf : .clear).frame(width: 2) }
                                    .id(key)
                                }
                            }
                            .padding(.vertical, 6).padding(.trailing, 12)
                        }
                        .onChange(of: cursor, initial: true) { _, k in if let k { proxy.scrollTo(k) } }
                        .onAppear { proxy.scrollTo("s:\(s.start)", anchor: .top) }
                    }
                }
            }
        }
        .background(theme.diffBg)
        .overlay(alignment: .leading) { (focused ? theme.goldDeep : .clear).frame(width: 1) }
        .padding(.leading, 16).padding(.trailing, 12)
    }

    /// A cited line in review's syntax colours (Highlight.swift), the rest left to the row's ink.
    static func highlighted(_ text: String, _ lang: Lang, _ colors: CodeColors) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        var out = AttributedString(text)
        let u = text.utf16
        for t in tokens(text, lang) {
            guard let lo = u.index(u.startIndex, offsetBy: t.location, limitedBy: u.endIndex),
                  let hi = u.index(lo, offsetBy: t.length, limitedBy: u.endIndex),
                  let r = Range(NSRange(lo..<hi, in: text), in: out) else { continue }
            out[r].foregroundColor = Color(nsColor: colors.color(t.kind))
        }
        return out
    }
}
