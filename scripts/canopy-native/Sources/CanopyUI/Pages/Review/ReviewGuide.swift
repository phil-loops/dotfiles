import CanopyCore
import SwiftUI

@MainActor
enum ReviewGuide {
    enum Kind: Equatable {
        case flag(String)
        case thread(String)
    }

    struct Entry: Equatable {
        let key: String
        let kind: Kind
        let path: String
        let line: Int?
        let detail: String
        let stop: String?

        var title: String { path + (line.map { ":\($0)" } ?? "") }
        var isFlag: Bool { if case .flag = kind { return true }; return false }
    }

    static func entries(_ app: AppModel) -> [Entry] {
        let pg = ReviewPageState.of(app)
        guard pg.integration == nil else { return [] }
        let prefix = "guide|\(pg.contextKey)|"
        let marked = pg.serverMarks.flagged
        var flags: [String: Entry] = [:]
        for flag in app.store.view(Viewed.self, pg.id)?.flags ?? [] where (pg.viewedOverride[flag.key] ?? (marked.contains(flag.key) ? .flagged : .unread)) == .flagged {
            flags[flag.key] = Entry(key: prefix + "flag|" + flag.key, kind: .flag(flag.key), path: flag.path,
                                    line: flag.line, detail: flag.text, stop: nil)
        }
        if !pg.scoped && pg.diffCurrent {
            for view in pg.views {
                for (i, block) in view.blocks.enumerated() where view.marks[i] == .flagged {
                    let place = pg.flagPlace(block.key)
                    flags[block.key] = Entry(key: prefix + "flag|" + block.key, kind: .flag(block.key), path: view.file.path,
                                            line: place?.line, detail: place?.text ?? "", stop: pg.stopOf(block: block.key, in: view.file.path))
                }
            }
        }
        let threads = pg.threads.filter { !$0.resolved && !$0.outdated }.map { thread in
            Entry(key: prefix + "thread|" + thread.id, kind: .thread(thread.id), path: thread.path,
                  line: thread.local?.line ?? thread.line, detail: thread.comments.first?.body ?? thread.subject, stop: nil)
        }
        return flags.values.sorted { ($0.path, $0.line ?? 0, $0.key) < ($1.path, $1.line ?? 0, $1.key) } + threads
    }

    static func rows(_ app: AppModel) -> [String] {
        let entries = entries(app)
        return entries.isEmpty ? [emptyKey(app)] : entries.map(\.key)
    }

    static func emptyKey(_ app: AppModel) -> String { "guide|\(ReviewPageState.of(app).contextKey)|empty" }

    static func summary(_ app: AppModel) -> String { "return to" }

    static func progress(_ app: AppModel) -> String {
        let pg = ReviewPageState.of(app)
        guard pg.diffCurrent else { return "reading the current diff…" }
        if pg.scoped { return "read marks belong to the branch diff" }
        let marks = pg.views.flatMap(\.marks)
        guard !marks.isEmpty else { return "no change blocks in this diff" }
        return "\(marks.filter { $0 != .unread }.count) of \(marks.count) changes marked read"
    }

    static func location(_ app: AppModel) -> String? {
        let pg = ReviewPageState.of(app)
        guard pg.diffCurrent, let here = pg.here else { return nil }
        guard let row = here.row else { return here.path }
        let line = sideLine(row, prefer: pg.column)
        return "\(here.path):\(line.line)\(line.side == .left ? " · old" : "")"
    }

    static func open(_ app: AppModel) {
        let pg = ReviewPageState.of(app)
        pg.guideReturnPane = app.pane?.id
        pg.tab = "files"
        pg.guideContext = pg.contextKey
        CodeLookup.of(app).dismiss()
        app.focus(pane: reviewGuidePane)
    }

    static func close(_ app: AppModel) {
        let pg = ReviewPageState.of(app)
        let focused = app.pane?.id == reviewGuidePane || (pg.guideContext != nil && !pg.guideOpen)
        let pane = pg.guideReturnPane
        pg.guideContext = nil
        pg.guideReturnPane = nil
        if focused { app.focus(pane: pane.flatMap { id in app.panes.contains(where: { $0.id == id }) ? id : nil } ?? pg.windows.first?.pane ?? reviewDiffPane) }
    }

    static func activate(_ key: String, _ app: AppModel) throws {
        let pg = ReviewPageState.of(app)
        guard pg.guideOpen else { throw Refusal("reopen Return to for this diff") }
        if key == emptyKey(app) { return close(app) }
        guard let entry = entries(app).first(where: { $0.key == key }) else { throw Refusal("that item changed · reopen Return to") }
        switch entry.kind {
        case .flag:
            guard pg.diffCurrent else { throw Refusal("reading the current diff · try again when it lands") }
            guard let stop = entry.stop, pg.stopIndex[stop] != nil else { throw Refusal("this flagged change is not in this diff · no nearby line was substituted") }
            close(app)
            pg.setCursor(stop)
        case .thread(let id):
            guard ShipRows.conversation(app, pg.id).contains("t|\(id)") else { throw Refusal("the conversation is not loaded yet") }
            close(app)
            ShipState.of(app).unfold[id] = true
            pg.tab = "conversation"
            app.focus(pane: ShipSeam.conversationPane)
            app.setCursor("t|\(id)")
        }
    }

    static func pickFile(_ app: AppModel) throws {
        let pg = ReviewPageState.of(app)
        guard pg.diffCurrent else { throw Refusal("reading the current diff") }
        let files = pg.views
        guard !files.isEmpty else { throw Refusal(pg.payload == nil ? "reading the changed files" : "no changed files in this diff") }
        let context = pg.contextKey
        let paths = files.map(\.file.path)
        close(app)
        let items = files.map { view in
            PickItem(label: view.file.path, text: "+\(view.file.add) −\(view.file.del)" + (pg.scoped ? "" : " · \(view.marks.filter { $0 != .unread }.count) of \(view.blocks.count) changes marked read · \(view.flagged) flagged · \(view.open) open threads"))
        }
        app.nav.pick("changed files", items) { i in
            MainActor.assumeIsolated {
                guard app.router.route.surfaceID == "review", pg.contextKey == context, pg.diffCurrent, paths.indices.contains(i), pg.views.contains(where: { $0.file.path == paths[i] }) else {
                    app.runner.say("the diff changed · open the file picker again")
                    return
                }
                app.runner.dispatch("review.file.go", via: .key, arg: paths[i])
            }
        }
    }

    static func install(_ app: AppModel) {
        let pg = ReviewPageState.of(app)
        app.registry.register(Command(id: "review.guide", title: "Return to flagged changes and open threads", scope: .review, leader: LocalKey(",G"), label: "return to",
                                      available: { _ in pg.integration == nil }, local: { _, _ in if pg.guideOpen { close(app) } else { open(app) } }))
        app.registry.register(Command(id: "review.guide.go", title: "Open a return item", scope: .review, needsArg: true, quiet: true, recordsJump: true,
                                      local: { _, arg in guard let key = arg as? String else { return }; try activate(key, app) }))
        app.addCloser(first: true, isOpen: { [weak app] in app?.router.route.surfaceID == "review" && pg.guideOpen },
                      close: { [weak app] in if let app { close(app) } })
    }
}

struct ReviewGuidePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let entries = ReviewGuide.entries(app)
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Return to").font(Theme.display(18)).foregroundStyle(theme.ink)
                    Spacer()
                    KeyButton(title: "close", id: "review.back")
                        .labelTarget(pane: "review-guide-close", key: "close", title: "close", run: RouteTo("review.back"))
                }
                if let location = ReviewGuide.location(app) { Text(location).foregroundStyle(theme.inkDim).textSelection(.enabled) }
                Text(ReviewGuide.progress(app)).foregroundStyle(theme.inkFaint)
                KeyButton(title: "find a changed file", id: "review.files")
                    .labelTarget(pane: "review-guide-files", key: "files", title: "changed files", run: RouteTo("review.files"))
            }
            .font(Theme.text(11.5)).padding(14)
            theme.vellumEdge.frame(height: 1)
            PaneList(pane: reviewGuidePane, rows: ReviewGuide.rows(app)) { key, _ in
                if let entry = byKey[key] {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.isFlag ? "⚑" : "↳").foregroundStyle(theme.ember)
                            Text(entry.isFlag ? "flagged change" : "open thread").foregroundStyle(theme.inkDim)
                            if entry.isFlag && entry.stop == nil { Text(ReviewPageState.of(app).diffCurrent ? "not in this diff" : "reading diff…").foregroundStyle(theme.inkFaint) }
                        }
                        Text(entry.title).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                        if !entry.detail.isEmpty { Text(entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(theme.inkDim).lineLimit(3) }
                    }
                    .padding(.vertical, 5)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing set aside").foregroundStyle(theme.ink)
                        Text("No flagged changes or open threads here").foregroundStyle(theme.inkDim)
                        Text("Return to reading").foregroundStyle(theme.goldLeaf)
                    }
                    .padding(.vertical, 8)
                }
            }
            .font(Theme.text(11.5))
        }
        .paneRing(reviewGuidePane)
    }
}
