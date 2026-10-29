import AppKit
import CanopyCore
import Foundation

// commands/words.ts — rewording a branch's unpushed commits: one save rewrites every changed message
// in a single guarded pass (POST /outline — same trees, refuses if the branch moved since it was
// read, reseats descendants), and u replays /outline-undo. Plus the native editor's keys: write the
// words row under the cursor (insert mode), apply a hint's fix, copy the PR text.

/// What `words.undo` puts back.
struct WordsUndo {
    var moves: Bool
    var pr: MessageWords?
}

/// A words row, decoded: "w|desc", "w|title", "w|body", "w|s|<sha>", "w|b|<sha>".
enum WordsRow: Equatable {
    case desc, title, body, subject(String), commitBody(String)

    init?(_ row: String) {
        let p = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.first == "w", p.count >= 2 else { return nil }
        switch p[1] {
        case "desc": self = .desc
        case "title": self = .title
        case "body": self = .body
        case "s" where p.count > 2: self = .subject(p[2])
        case "b" where p.count > 2: self = .commitBody(p[2])
        default: return nil
        }
    }

    /// The insert-mode field id for this row on branch `id`.
    func field(_ id: String) -> String {
        switch self {
        case .desc: "words.desc|\(id)"
        case .title: "words.title|\(id)"
        case .body: "words.body|\(id)"
        case .subject(let sha): "words.s|\(id)|\(sha)"
        case .commitBody(let sha): "words.b|\(id)|\(sha)"
        }
    }

    var sha: String? {
        switch self { case .subject(let s), .commitBody(let s): s; default: nil }
    }
}

@MainActor
enum WordsCommands {
    /// The branch a words command acts on: the review page's, else the forest page's words face (A sets `WordsState.focus`).
    static func branchOf(_ app: AppModel, _ target: String?) -> String? {
        if let t = target, let id = t.split(separator: " ").first.map(String.init), app.store.view(Branch.self, id) != nil { return id }
        return ShipSeam.branchID(app) ?? WordsState.of(app).focus
    }

    static func install(_ app: AppModel) {
        let r = app.registry
        let words = WordsState.of(app)
        let store = app.store
        let tr = app.transport

        r.register(Command(
            id: "words.save", title: "Save the commit message edits", scope: .global, budget: .gitWrite, quiet: true,
            available: { [weak app] t in
                guard let app, let id = branchOf(app, t) else { return false }
                return words.pending(id) > 0
            },
            write: { [weak app] t, _ in
                guard let app, let id = branchOf(app, t), let b = store.view(Branch.self, id), let o = words.shown[id] else { return nil }
                let edits = words.changed(id)
                let pr = words.prChange(id)
                if edits.isEmpty && pr == nil { return nil }
                if edits.contains(where: { $0.subject.isEmpty }) { throw Refusal("a commit needs a subject") }
                let was = words.drafts
                var mine = was[id] ?? [:]
                let prBefore = words.prOnFile(id)
                let prAfter = pr == nil ? nil : words.prValue(id)
                for e in edits { mine[e.sha] = nil }
                if pr != nil { mine[WordsState.pr] = nil }
                words.drafts[id] = mine
                let savedWas = words.savedPr
                if let a = prAfter {
                    words.savedPr[id] = MessageWords(subject: a.subject.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     body: a.body.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let n = edits.count
                let what = [n > 0 ? "reworded \(n) commit\(n == 1 ? "" : "s")" : "", pr != nil ? "saved the PR text" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
                var body: JSONObject = ["branch": .string(b.name), "head": .string(o.head),
                                        "edits": .array(edits.map { .object(["sha": .string($0.sha), "subject": .string($0.subject), "body": .string($0.body)]) })]
                if let t = pr?.prTitle { body["prTitle"] = .string(t) }
                if let x = pr?.prBody { body["prBody"] = .string(x) }
                let undo = WordsUndo(moves: n > 0, pr: pr == nil ? nil : prBefore)
                return Write(
                    path: tr.atRepo(b.repo, "/outline"), body: .object(body),
                    // rewording moves the tip; a PR-text-only save lands in config, done when the server answers
                    settled: { n == 0 || store.table(Branch.self)[id]?.tip != o.head },
                    said: "\(what) · \(app.registry.keyOf("undo")) undoes",
                    failed: "couldn't save — the branch may have moved; your edits are kept",
                    inverse: { _ in Inverse(id: "words.undo", target: id, arg: undo) },
                    rollback: {
                        words.drafts = was
                        words.savedPr = savedWas
                    })
            }))

        r.register(Command(
            id: "words.undo", title: "Put the commit messages back as they were", scope: .global, budget: .gitWrite, needsArg: true, quiet: true,
            write: { id, arg in
                guard let b = store.view(Branch.self, id) else { return nil }
                let tip = b.tip
                let u = arg as? WordsUndo ?? WordsUndo(moves: true, pr: nil)
                let savedWas = words.savedPr
                if let pr = u.pr { words.savedPr[id] = pr }
                return Write(
                    path: tr.atRepo(b.repo, "/outline-undo"), body: ["branch": .string(b.name)],
                    settled: { !u.moves || store.table(Branch.self)[id]?.tip != tip },
                    said: "undone", failed: "couldn't put the messages back",
                    rollback: { words.savedPr = savedWas })
            }))

        r.register(Command(
            id: "words.fix", title: "Apply a hint's fix to the words under the cursor", scope: .words, keys: ["A"], label: "fix",
            available: { [weak app] row in
                guard let app, let row, let id = branchOf(app, nil) else { return false }
                return !fixes(app, id, row).isEmpty
            },
            local: { [weak app] row, arg in
                guard let app, let row, let id = branchOf(app, nil) else { return }
                let hintID = arg as? String
                guard let fix = fixes(app, id, row).first(where: { hintID == nil || $0.id == hintID }) else { throw Refusal("that hint has nothing to fix any more") }
                fix.apply()
            }))

        r.register(Command(
            id: "words.copy", title: "Copy the PR title, or its body on the body row, for a PR form filled by hand", scope: .words, keys: ["y"], label: "copy",
            available: { row in row == "w|title" || row == "w|body" },
            local: { [weak app] row, _ in
                guard let app, let id = branchOf(app, nil) else { return }
                let w = words.prValue(id)
                let part = row == "w|title" ? "title" : "body"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(part == "title" ? w.subject : w.body, forType: .string)
                app.runner.say("copied the PR \(part)")
            }))

        r.register(Command(
            id: "words.edit", title: "Write the words under the cursor (esc stops; ⌃↵ saves)", scope: .words, keys: ["i"], label: "write",
            available: { [weak app] row in
                guard let app, let row, let w = WordsRow(row), let id = branchOf(app, nil) else { return false }
                return editable(app, id, w)
            },
            local: { [weak app] row, _ in
                guard let app, let row, let w = WordsRow(row), let id = branchOf(app, nil) else { return }
                app.focus(pane: ShipSeam.wordsPane)
                app.setCursor(row)
                app.beginInsert(w.field(id))
            }))
    }

    /// Whether a words row can be written here: the PR's text until GitHub owns it, a commit until it's locked.
    static func editable(_ app: AppModel, _ id: String, _ w: WordsRow) -> Bool {
        let words = WordsState.of(app)
        switch w {
        case .desc: return app.store.view(Branch.self, id) != nil
        case .title, .body:
            guard let o = words.shown[id] else { return false }
            return o.draft != nil && !WordsState.githubOwns(o.pr)
        case .subject(let sha), .commitBody(let sha):
            return words.shown[id]?.commits.first { $0.sha == sha }?.locked.isEmpty == true
        }
    }

    /// The fixable hints on a words row, each with the edit it makes.
    static func fixes(_ app: AppModel, _ id: String, _ row: String) -> [(id: String, label: String, apply: () -> Void)] {
        let words = WordsState.of(app)
        guard let w = WordsRow(row) else { return [] }
        switch w {
        case .desc: return []
        case .title, .body:
            return words.prHints(id).compactMap { h in
                h.fix.map { f in (h.id, f.label, { words.editPr(id, f.apply(words.prValue(id))) }) }
            }
        case .subject(let sha), .commitBody(let sha):
            guard let c = words.shown[id]?.commits.first(where: { $0.sha == sha }) else { return [] }
            return words.hintsOf(id, c).compactMap { h in
                h.fix.map { f in (h.id, f.label, { words.editTo(id, c, f.apply(words.valueOf(id, c))) }) }
            }
        }
    }
}
