import CanopyCore
import Foundation

/// The words by name (NAV.md, 2026-11-08: name the target, don't walk to it). `:title`, `:why`,
/// `:desc` and `:reword` reach a branch's words from anywhere: typed after the name, the words are
/// written and saved in one go; with nothing after it, the page opens on that row, writing.
@MainActor
enum WordsByName {
    @MainActor private final class Intent {
        var generation = 0
        var pending: Origin?
        static func of(_ app: AppModel) -> Intent { app.state { Intent() } }
    }
    @MainActor private struct Origin {
        let source: BranchSource
        let generation: Int
        var reader: ReaderContext

        init?(_ app: AppModel, _ id: String) {
            guard let source = BranchSource.current(app, id) else { return nil }
            self.source = source
            generation = Intent.of(app).generation
            reader = ReaderContext(app)
        }

        func current(_ app: AppModel, afterPicker: Bool = false) -> Bool {
            source == BranchSource.current(app, source.id) && generation == Intent.of(app).generation &&
                (afterPicker ? reader.isCurrentAfterPickerChoice(app) : reader.isCurrent(app))
        }
    }
    /// The branch these act on: the review page's, else the branch under the cursor, else the forest page's words face.
    static func branch(_ app: AppModel) -> String? {
        if let id = ShipSeam.branchID(app) { return id }
        if let id = app.target(for: .branch), app.store.view(Branch.self, id) != nil { return id }
        return WordsState.of(app).focus
    }

    static func install(_ app: AppModel) {
        weak let weakApp = app
        let r = app.registry
        app.addCloser(first: true, isOpen: { [weak app] in
            app.map(hasPending) ?? false
        }, close: { [weak app] in
            if let app { _ = backOut(app) }
        })
        let onABranch: (String?) -> Bool = { _ in weakApp.map { branch($0) != nil } ?? false }

        r.register(Command(
            id: "title", title: "The PR's title — :title <text> writes and saves it; alone, opens it to write",
            scope: .global, budget: .gitWrite, verb: .wordsTitle, takes: "<text>", label: "title", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                Intent.of(app).generation &+= 1
                Intent.of(app).pending = nil
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
                Intent.of(app).generation &+= 1
                Intent.of(app).pending = nil
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
                Intent.of(app).generation &+= 1
                Intent.of(app).pending = nil
                guard let text = typed(arg) else { return try open(app, id, .desc) }
                app.runner.dispatch("branch.describe", via: .palette, target: id, arg: oneLine(text))
            }))

        r.register(Command(
            id: "reword", title: "A commit's subject — :reword <sha> <subject> saves it; :reword <sha> opens it to write; alone, pick the commit",
            scope: .global, budget: .gitWrite, verb: .wordsCommit, takes: "<sha> <subject>", label: "reword", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                Intent.of(app).generation &+= 1
                Intent.of(app).pending = nil
                guard let t = typed(arg) else { return try withWords(app, id) { try pickCommit(app, id) } }
                let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
                let sha = parts[0], subject = parts.count > 1 ? oneLine(parts[1]) : nil
                try withWords(app, id) {
                    let words = WordsState.of(app)
                    let c = try commit(words, id, sha)
                    try act(app, id, row: .subject(c.sha), typed: subject) { words, text in
                        words.editTo(id, c, MessageWords(subject: text, body: words.valueOf(id, c).body))
                    }
                }
            }))

        // fold: one commit absorbed into the one below it — the server's one commit-tree pass (POST
        // /outline {fold}), tree-preserving and undone by u. Typed, it folds that sha; alone, it picks.
        r.register(Command(
            id: "fold", title: "Fold a commit into the one below it — :fold <sha>; alone, pick the commit",
            scope: .global, verb: .wordsFold, takes: "<sha>", label: "fold", available: onABranch,
            local: { _, arg in
                guard let app = weakApp, let id = branch(app) else { return }
                Intent.of(app).generation &+= 1
                Intent.of(app).pending = nil
                guard let t = typed(arg) else { return try withWords(app, id) { try pickFold(app, id) } }
                try withWords(app, id) { app.runner.dispatch("words.fold", via: .key, target: id, arg: String(t.split(separator: " ")[0])) }
            }))
        r.register(Command(
            id: "words.fold", title: "Fold the named commit into the one below it", scope: .global, budget: .gitWrite, needsArg: true, quiet: true,
            write: { [weak app] t, arg in
                guard let app, let id = t ?? branch(app), let b = app.store.view(Branch.self, id), let sha = arg as? String else { return nil }
                let words = WordsState.of(app)
                guard let o = words.shown[id] else { throw Refusal("the words aren't read yet") }
                let own = o.commits.filter { !$0.carried }
                let c = try commit(words, id, sha)
                guard let i = own.firstIndex(where: { $0.sha == c.sha }) else { throw Refusal("that commit is gone") }
                guard i > 0 else { throw Refusal("\(c.short.prefix(7)) is the branch's first commit — nothing below it to fold into") }
                let below = own[i - 1]
                for x in [c, below] where !x.locked.isEmpty { throw Refusal("\(x.short.prefix(7)) is \(x.locked)") }
                let tip = b.tip
                return Write(
                    path: app.transport.atRepo(b.repo, "/outline"),
                    body: ["branch": .string(b.name), "head": .string(o.head), "fold": .array([.string(c.sha)])],
                    settled: { app.store.table(Branch.self)[id]?.tip != tip },
                    said: "folded \(c.short.prefix(7)) into \(below.short.prefix(7)) — \(app.registry.keyOf("undo")) puts it back",
                    failed: "couldn't fold \(c.short.prefix(7))",
                    inverse: { _ in Inverse(id: "words.undo", target: id, arg: WordsUndo(moves: true, pr: nil)) })
            }))
    }

    private static func hasPending(_ app: AppModel) -> Bool {
        guard let pending = Intent.of(app).pending else { return false }
        return pending.current(app) && WordsState.of(app).hasWaiter(pending.source.id)
    }

    @discardableResult
    static func backOut(_ app: AppModel) -> Bool {
        guard hasPending(app) else { return false }
        let intent = Intent.of(app)
        intent.generation &+= 1
        intent.pending = nil
        app.runner.say("words action cancelled")
        return true
    }

    /// The branch's unpushed commits that have one below them, newest first; picking one folds it.
    static func pickFold(_ app: AppModel, _ id: String) throws {
        let words = WordsState.of(app)
        guard let outline = words.shown[id], var origin = Origin(app, id) else { throw Refusal("the branch's words aren't available") }
        let own = outline.commits.filter { !$0.carried }
        let candidates = Array(own.dropFirst().reversed())
        guard !candidates.isEmpty else { throw Refusal("this branch has one commit — nothing to fold") }
        let items = candidates.map { c in PickItem(label: String(c.short.prefix(7)), text: c.locked.isEmpty ? c.subject : "\(c.subject) · \(c.locked)") }
        app.nav.pick("fold a commit into the one below it", items) { [weak app] index in
            guard let app, candidates.indices.contains(index), origin.current(app, afterPicker: true), words.shown[id] == outline else { return }
            app.runner.dispatch("words.fold", via: .key, target: id, arg: candidates[index].sha)
        }
        origin.reader = ReaderContext(app)
    }

    /// The branch's own commits, newest first, by their subjects; picking opens one to write.
    static func pickCommit(_ app: AppModel, _ id: String) throws {
        let words = WordsState.of(app)
        guard let outline = words.shown[id], var origin = Origin(app, id) else { throw Refusal("the branch's words aren't available") }
        let candidates = outline.commits.filter { !$0.carried }.reversed().map { $0 }
        guard !candidates.isEmpty else { throw Refusal("this branch has no commits of its own") }
        let items = candidates.map { c in
            PickItem(label: String(c.short.prefix(7)), text: c.locked.isEmpty ? c.subject : "\(c.subject) · \(c.locked)")
        }
        app.nav.pick("reword a commit", items) { [weak app] index in
            guard let app, candidates.indices.contains(index), origin.current(app, afterPicker: true), words.shown[id] == outline else { return }
            let candidate = candidates[index]
            do {
                try refuseIfShared(app, id, .subject(candidate.sha))
                try open(app, id, .subject(candidate.sha))
            } catch { app.runner.say("\(error)") }
        }
        origin.reader = ReaderContext(app)
    }

    /// What was typed after the command's name, or nil when nothing was.
    static func typed(_ arg: Any?) -> String? {
        guard let s = (arg as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).joined(separator: " ") }

    /// The branch's own commit a sha (or its prefix) names.
    static func commit(_ words: WordsState, _ id: String, _ sha: String) throws -> OutlineCommit {
        let matches = (words.shown[id]?.commits ?? []).filter { !$0.carried && ($0.sha.hasPrefix(sha) || $0.short.hasPrefix(sha)) }
        guard !matches.isEmpty else { throw Refusal("\(sha) isn't one of this branch's commits") }
        guard matches.count == 1 else { throw Refusal("\(sha) names more than one commit; use a longer prefix") }
        return matches[0]
    }

    /// Run `f` once the branch's words are read; a refusal after the read is said, since nothing awaits it.
    static func withWords(_ app: AppModel, _ id: String, _ f: @escaping @MainActor () throws -> Void) throws {
        let words = WordsState.of(app)
        if words.hasShown(app, id) { return try f() }
        guard let origin = Origin(app, id) else { throw Refusal("that branch is gone") }
        Intent.of(app).pending = origin
        app.runner.say("reading the branch's words… · esc cancels")
        words.whenShown(app, id, current: { [weak app] in app.map { origin.current($0) } ?? false }) {
            Intent.of(app).pending = nil
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
        var row = row
        guard let b = app.store.view(Branch.self, id) else { throw Refusal("no such branch") }
        if ShipSeam.branchID(app) != id { app.go(.review(repo: b.repo, branch: b.name)) }
        let pg = ReviewPageState.of(app)
        let ship = ShipState.of(app)
        guard pg.integration == nil else { throw Refusal("an integration has no words of its own") }
        switch row {
        case .subject(let sha), .commitBody(let sha):
            ship.showCommit(sha)
            // a commit that is all that lands, and owns its words, is written as what lands
            if ship.host.wholeBranch, case .commit(let owner) = WordsState.of(app).landingOwner(id), owner.hasPrefix(sha) || sha.hasPrefix(owner) {
                row = row == .subject(sha) ? .title : .body
            }
        case .title, .body:
            try pg.apply(.base(.parent))
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
