import CanopyCore
import Foundation

/// The words by name (NAV.md, 2026-11-08: name the target, don't walk to it). `:title`, `:why`,
/// `:desc` and `:reword` reach a branch's words from anywhere: typed after the name, the words are
/// written and saved in one go; with nothing after it, the page opens on that row, writing.
@MainActor
enum WordsByName {
    /// The branch these act on: the review page's, else the branch under the cursor, else the forest page's words face.
    static func branch(_ app: AppModel) -> String? {
        if let id = ShipSeam.branchID(app) { return id }
        if let id = app.target(for: .branch), app.store.view(Branch.self, id) != nil { return id }
        return WordsState.of(app).focus
    }

    static func install(_ app: AppModel) {
        weak let weakApp = app
        let r = app.registry
        let onABranch: (String?) -> Bool = { _ in weakApp.map { branch($0) != nil } ?? false }

        r.register(Command(
            id: "title", title: "The PR's title — :title <text> writes and saves it; alone, opens it to write",
            scope: .global, budget: .gitWrite, verb: .wordsTitle, takes: "<text>", label: "title", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                try landing(app, id, row: .title, typed: typed(arg).map(oneLine)) { words, text in
                    var v = words.prValue(id)
                    v.subject = text
                    words.editPr(id, v)
                }
            }))

        r.register(Command(
            id: "why", title: "The PR's why — :why <text> writes and saves it; alone, opens it to write",
            scope: .global, budget: .gitWrite, verb: .wordsWhy, takes: "<text>", label: "why", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                try landing(app, id, row: .body, typed: typed(arg)) { words, text in
                    var v = words.prValue(id)
                    v.body = OutlineHints.joinTemplate(text, OutlineHints.splitTemplate(v.body).template)
                    words.editPr(id, v)
                }
            }))

        r.register(Command(
            id: "desc", title: "The branch's description — :desc <text> saves it; alone, opens it to write",
            scope: .global, budget: .configWrite, verb: .wordsDescription, takes: "<text>", label: "describe", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                guard let text = typed(arg) else { return try open(app, id, .desc) }
                app.runner.dispatch("branch.describe", via: .palette, target: id, arg: oneLine(text))
            }))

        r.register(Command(
            id: "reword", title: "A commit's subject — :reword <sha> <subject> saves it; :reword <sha> opens it to write",
            scope: .global, budget: .gitWrite, takes: "<sha> <subject>", label: "reword", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                guard let t = typed(arg) else { throw Refusal("name the commit: :reword <sha> <subject>") }
                let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
                let sha = parts[0], subject = parts.count > 1 ? oneLine(parts[1]) : nil
                try withWords(app, id) {
                    let words = WordsState.of(app)
                    guard let c = commit(words, id, sha) else { throw Refusal("\(sha) isn't one of this branch's commits") }
                    try act(app, id, row: .subject(c.sha), typed: subject) { words, text in
                        words.editTo(id, c, MessageWords(subject: text, body: words.valueOf(id, c).body))
                    }
                }
            }))
    }

    /// What was typed after the command's name, or nil when nothing was.
    static func typed(_ arg: Any?) -> String? {
        guard let s = (arg as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).joined(separator: " ") }

    /// The branch's own commit a sha (or its prefix) names.
    static func commit(_ words: WordsState, _ id: String, _ sha: String) -> OutlineCommit? {
        words.shown[id]?.commits.first { !$0.carried && ($0.sha.hasPrefix(sha) || $0.short.hasPrefix(sha)) }
    }

    /// Run `f` once the branch's words are read; a refusal after the read is said, since nothing awaits it.
    static func withWords(_ app: AppModel, _ id: String, _ f: @escaping @MainActor () throws -> Void) throws {
        let words = WordsState.of(app)
        if words.shown[id] != nil { return try f() }
        app.runner.say("reading the branch's words…")
        words.whenShown(app, id) {
            do { try f() } catch { app.runner.say("\(error)") }
        }
    }

    /// The title or why: written and saved when typed, opened to write when not.
    static func landing(_ app: AppModel, _ id: String, row: WordsRow, typed: String?, set: @escaping (WordsState, String) -> Void) throws {
        try withWords(app, id) { try act(app, id, row: row, typed: typed, set: set) }
    }

    static func act(_ app: AppModel, _ id: String, row: WordsRow, typed: String?, set: (WordsState, String) -> Void) throws {
        try refuseIfShared(app, id, row)
        guard let typed else { return try open(app, id, row) }
        let words = WordsState.of(app)
        set(words, typed)
        guard words.pending(id) > 0 else { throw Refusal("it already says that") }
        app.runner.dispatch("words.save", via: .palette, target: id)
    }

    /// Words that can't change here say where they can.
    static func refuseIfShared(_ app: AppModel, _ id: String, _ row: WordsRow) throws {
        if WordsCommands.editable(app, id, row) { return }
        let o = WordsState.of(app).shown[id]
        switch row {
        case .title, .body:
            if let pr = o?.pr, WordsState.githubOwns(pr) { throw Refusal("GitHub holds #\(pr.number ?? 0)'s words now — change them there") }
            throw Refusal("this branch has no landing words yet")
        case .subject(let sha), .commitBody(let sha):
            let c = o?.commits.first { $0.sha == sha }
            throw Refusal("\(c?.short.prefix(7) ?? "that commit") is \(c?.locked ?? "gone") — it can't be reworded here")
        case .desc:
            throw Refusal("no such branch")
        }
    }

    /// Open the branch's page on the stretch whose words `row` is, the words pane on it, writing.
    static func open(_ app: AppModel, _ id: String, _ row: WordsRow) throws {
        guard let b = app.store.view(Branch.self, id) else { throw Refusal("no such branch") }
        if ShipSeam.branchID(app) != id { app.go(.review(repo: b.repo, branch: b.name)) }
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        guard pg.integration == nil else { throw Refusal("an integration has no words of its own") }
        switch row {
        case .subject(let sha), .commitBody(let sha):
            ship.showCommit(sha)
        case .title, .body:
            if pg.base != .parent { pg.setBase(.parent) }
            if pg.scoped { ship.showCommit(nil) }
        case .desc:
            break
        }
        ship.host.tab = "files"
        let key: String = switch row {
        case .desc: "w|desc"
        case .title: "w|title"
        case .body: "w|body"
        case .subject(let sha): "w|s|\(sha)"
        case .commitBody(let sha): "w|b|\(sha)"
        }
        app.focus(pane: ShipSeam.wordsPane)
        app.setCursor(key)
        app.beginInsert(row.field(id), lines: row.lines)
    }
}
