import AppKit
import CanopyCore
import Foundation

// commands/review.ts, the ship half: the push key, the words and history, GitHub's review verbs
// (comment on a line or a range, reply, apply a suggestion, address a thread) with GitHub's keys
// where it has them (r reply, c comment, ⌃G a suggestion) and Helix's otherwise. What Phil writes
// lands in the ledger (srv/reviewdesk.py) and, on his keypress, in his PENDING review on GitHub —
// submitting it, and resolving, happen on GitHub, which `g h` opens. Text is typed in insert mode:
// ⌃↵ sends, ⌥↵ saves a draft, ⌃G inserts a suggestion, esc stops typing (the words stay).

@MainActor
enum ReviewCommands {
    static let composeField = "ship.compose"

    static func install(_ app: AppModel) {
        let r = app.registry
        let ship = ShipState.of(app)
        let words = WordsState.of(app)
        let store = app.store
        let tr = app.transport
        weak let weakApp = app

        func branch(_ id: String?) -> Branch? { id.flatMap { store.view(Branch.self, $0) } }
        func thread(_ id: String?) -> CanopyCore.Thread? { id.flatMap { store.view(CanopyCore.Thread.self, $0) } }
        func page() -> String? { weakApp.flatMap(ShipSeam.branchID) }
        func conv() -> Conv? { page().flatMap { store.view(Conv.self, $0) } }
        func draft() -> Draft? { page().flatMap { store.view(Draft.self, $0) } }
        func repoPath(_ p: String) -> String { tr.atRepo(page().flatMap(ShipRows.splitID)?.repo ?? "", p) }
        func name() -> String { page().flatMap(ShipRows.splitID)?.name ?? "" }
        let integration = { () -> Bool in page().flatMap(ShipRows.splitID).map { Route.integrationOf($0.name) != nil } ?? false }
        let canWrite = { () -> Bool in conv() != nil && ship.commitScope == nil }
        let canNote = { () -> Bool in canWrite() || ship.commitScope != nil }
        let noting = { () -> Bool in ship.composer?.noteSha != nil }
        let open = { (u: URL) in ship.openURL(u) }

        // ── the push key and the words ──

        r.register(Command(
            id: "review.push", title: "Push to origin — a first push or follow-ups onto the PR (press twice)", scope: .review,
            keys: ["p"], label: "push",
            available: { id in pushRoute(weakApp, id) != nil },
            route: { id in pushRoute(weakApp, id).map { RouteTo($0, target: id) } }))
        r.register(Command(
            id: "review.words", title: "Edit what lands on main: the PR's title and why", scope: .review, keys: ["e"], label: "words",
            available: { _ in !integration() },
            local: { id, _ in
                guard let app = weakApp, let id = id ?? page() else { return }
                ship.host.tab = "commits"
                ship.historyFocus = .list
                ship.showCommit(nil)
                ship.loadHistory(app, id)
                words.load(app, id)
                app.focus(pane: ShipSeam.wordsPane)
                app.setCursor(words.shown[id].map { WordsState.githubOwns($0.pr) } == false ? "w|title" : "w|desc")
            }))
        r.register(Command(
            id: "review.history", title: "Step through the commits one at a time", scope: .review, keys: ["space h"], label: "commits",
            local: { id, _ in
                guard let app = weakApp, let id = id ?? page() else { return }
                ship.host.tab = "commits"
                ship.loadHistory(app, id)
                words.load(app, id)
                app.focus(pane: ShipSeam.historyPane)
                app.setCursor("h|\(ship.commitScope ?? "")")
            }))

        // ── history: the branch's commits one at a time (GitHub Desktop's view) ──

        let stepHistory = { (by: Int) in
            guard let app = weakApp else { return }
            app.focus(pane: ShipSeam.historyPane)
            app.moveCursor(by)
            let sha = app.selected.flatMap { $0.hasPrefix("h|") ? String($0.dropFirst(2)) : nil }
            ship.showCommit(sha?.isEmpty == false ? sha : nil)
        }
        r.register(Command(id: "history.next", title: "Next commit", scope: .history, keys: ["j", "down"], modes: [.normal, .select],
                           label: "commit", pair: "history.prev", quiet: true, local: { _, _ in stepHistory(1) }))
        r.register(Command(id: "history.prev", title: "Previous commit", scope: .history, keys: ["k", "up"], modes: [.normal, .select],
                           label: "commit", quiet: true, local: { _, _ in stepHistory(-1) }))
        r.register(Command(
            id: "history.select", title: "Show one commit's diff", scope: .review, needsArg: true, quiet: true,
            local: { _, arg in
                guard let app = weakApp else { return }
                let sha = (arg as? String).flatMap { $0.isEmpty ? nil : $0 }
                ship.host.tab = "commits"
                ship.historyFocus = .list
                app.focus(pane: ShipSeam.historyPane)
                app.setCursor("h|\(sha ?? "")")
                ship.showCommit(sha)
            }))
        let enterDiff = { (_: String?, _: Any?) in
            guard let app = weakApp else { return }
            ship.historyFocus = .diff
            ship.host.focusDiff(app, true)
        }
        r.register(Command(id: "history.enter", title: "Read the commit's diff", scope: .history, keys: ["l", "right"], label: "read",
                           available: { _ in ship.commitScope != nil }, local: enterDiff))
        r.register(Command(id: "history.open", title: "Open the commit's diff", scope: .history, keys: ["ret"], label: "read", quiet: true,
                           available: { _ in ship.commitScope != nil }, local: enterDiff))
        r.register(Command(id: "history.exit", title: "Go back to what lands on main", scope: .history, keys: ["esc"], label: "back",
                           local: { _, _ in
                               ship.showCommit(nil)
                               weakApp?.setCursor("h|")
                           }))
        let backToList = { (_: String?, _: Any?) in
            guard let app = weakApp else { return }
            ship.historyFocus = .list
            ship.host.focusDiff(app, false)
        }
        r.register(Command(id: "commit.back", title: "Go back to the commit list", scope: .commit, keys: ["h", "left"], label: "list", local: backToList))
        r.register(Command(id: "commit.exit", title: "Go back to the commit list", scope: .commit, keys: ["esc"], label: "list", local: backToList))

        // ── address: the commit that fixes a thread (wiki canopy-v2-address) ──

        let closeAddress = {
            ship.addressing = nil
            ship.addressPicking = false
            if weakApp?.keys.layer == .address { weakApp?.keys.closeLayer() }
        }
        r.register(Command(
            id: "review.address", title: "Address it — hand it to Claude, fix it yourself, or pick its commit", scope: .thread, keys: ["E"], label: "address",
            available: { id in thread(id).map { !$0.outdated && !$0.resolved } == true },
            local: { id, _ in
                guard let app = weakApp, let id else { return }
                ship.addressing = id
                ship.addressPicking = false
                app.keys.openLayer(.address)
            }))
        let addressed = { () -> CanopyCore.Thread? in thread(ship.addressing) }
        let inSheet: (String?) -> Bool = { _ in weakApp?.keys.layer == .address && ship.addressing != nil }
        r.register(Command(
            id: "review.address.claude", title: "Hand the thread to Claude to fix", scope: .review, budget: .slowIO,
            keys: ["ret", "c"], modes: [.address], label: "claude", available: inSheet,
            write: { _, _ in
                guard let t = addressed() else { return nil }
                closeAddress()
                return Write(path: repoPath("/review-address"), body: ["branch": .string(name()), "thread": .string(t.node), "claude": true],
                             settled: { true }, said: "claude window ready — send it there", failed: "couldn't start the Claude session",
                             inverse: { a in a["key"]?.string.flatMap { k in page().map { Inverse(id: "review.address.cancel", target: $0, arg: k) } } })
            }))
        r.register(Command(
            id: "review.address.helix", title: "Fix the thread yourself in Helix", scope: .review, budget: .slowIO,
            keys: ["o"], modes: [.address], label: "helix", available: inSheet,
            write: { _, _ in
                guard let t = addressed() else { return nil }
                closeAddress()
                return Write(path: repoPath("/open"), body: ["branch": .string(name()), "path": .string(t.path), "line": t.local.map { .number(Double($0.line)) } ?? .null],
                             settled: { true }, said: "fix, commit, then \(weakApp?.registry.keyOf("review.address") ?? "E") to pick it", failed: "couldn't open it in Helix")
            }))
        r.register(Command(
            id: "review.address.pick.list", title: "List the commits that could fix the thread", scope: .review,
            keys: ["p"], modes: [.address], label: "pick", available: inSheet,
            local: { _, _ in
                guard let app = weakApp, let id = page() else { return }
                ship.addressPicking.toggle()
                words.load(app, id)
            }))
        r.register(Command(
            id: "review.address.pick", title: "Declare a commit the thread's fix", scope: .review, budget: .gitWrite, needsArg: true, quiet: true,
            write: { _, arg in
                guard let id = page(), let sha = arg as? String, let t = addressed(), let o = words.shown[id] else { return nil }
                closeAddress()
                return Write(path: repoPath("/review-address"), body: ["branch": .string(name()), "thread": .string(t.node), "sha": .string(sha), "head": .string(o.head)],
                             settled: { store.table(Branch.self)[id]?.tip != o.head },
                             said: "\(sha.prefix(7)) addresses it · \(weakApp?.registry.keyOf("undo") ?? "u") undoes",
                             failed: "couldn't add the trailer — the branch may have moved",
                             inverse: { a in a["key"]?.string.map { Inverse(id: "review.address.undo", target: id, arg: $0) } })
            }))
        for n in 1...9 {
            r.register(Command(
                id: "review.address.pick.\(n)", title: "Pick commit \(n) as the thread's fix", scope: .review, keys: ["\(n)"], modes: [.address], quiet: true,
                available: { t in inSheet(t) && ship.addressPicking && addressCandidates(weakApp).count >= n },
                route: { t in
                    let c = addressCandidates(weakApp)
                    return c.count >= n ? RouteTo("review.address.pick", target: t ?? page(), arg: c[n - 1].sha) : nil
                }))
        }
        r.register(Command(
            id: "review.address.reply", title: "Draft the 'done in' reply for a thread a commit already addresses", scope: .thread, budget: .configWrite,
            available: { id in thread(id)?.fixedBy.isEmpty == false },
            write: { id, _ in
                guard let t = thread(id) else { return nil }
                // send: it rides the push — waits until its fix commit is on origin, then goes into the pending review
                return Write(path: repoPath("/review-draft"),
                             body: ["branch": .string(name()), "op": "add", "send": true,
                                    "item": ["kind": "reply", "thread": .string(t.node), "body": "done in {fix}", "fixFor": t.comments.first.map { .string($0.url) } ?? .null]],
                             settled: { true }, said: "reply drafted", failed: "couldn't draft the reply")
            }))
        r.register(Command(
            id: "review.address.undo", title: "Take back a declared fix", scope: .review, budget: .gitWrite, needsArg: true, quiet: true,
            write: { id, key in
                let tip = branch(id)?.tip
                return Write(path: repoPath("/review-address"), body: ["branch": .string(name()), "undo": key.map { .string("\($0)") } ?? .null],
                             settled: { store.table(Branch.self)[id]?.tip != tip }, said: "undone", failed: "couldn't take it back")
            }))
        r.register(Command(
            id: "review.address.cancel", title: "Drop a reply that waits for a fix", scope: .review, budget: .configWrite, needsArg: true, quiet: true,
            write: { _, key in
                Write(path: repoPath("/review-draft"), body: ["branch": .string(name()), "op": "remove", "key": key.map { .string("\($0)") } ?? .null],
                      settled: { true }, failed: "couldn't drop the reply")
            }))

        // ── writing: comments, the pending review, replies ──

        let lineComposer = { () -> ShipComposer? in
            guard let app = weakApp, let r = ship.host.lineRange(app) else { return nil }
            // on one commit's diff the box is a note for Claude about that commit, not a GitHub comment
            let sha = ship.commitScope
            let key = "\(sha.map { "n|\($0)" } ?? "c")|\(r.path)|\(r.side.rawValue)|\(r.line)|\(r.startLine.map(String.init) ?? "")"
            return .line(key: key, path: r.path, side: r.side, line: r.line, startLine: r.startLine, sha: sha)
        }
        let compose = { (c: ShipComposer?) in
            guard let c else { throw Refusal("no line under the cursor") }
            ship.composer = c
            weakApp?.beginInsert(composeField)
        }
        r.register(Command(id: "review.comment", title: "Comment on the line (or the range x selected)", scope: .line, keys: ["c"], label: "comment",
                           available: { _ in canNote() }, local: { _, _ in try compose(lineComposer()) }))
        r.register(Command(id: "review.gutter", title: "Comment on this line", scope: .review, needsArg: true, hint: ["click +"], quiet: true,
                           available: { _ in canNote() },
                           local: { _, arg in
                               if let r = arg as? ShipLineRange, let s = ship.host as? StandInHost { s.range = r }
                               try compose(lineComposer())
                           }))

        let unpushedNamed = { (body: String) -> [String] in Ledger.unpushedIn(body, conv()?.unpushed ?? []) }

        /// The composer's note on a commit's line, handed to a fresh Claude in the branch's worktree.
        let handNote = { () throws -> Write? in
            guard case .line(let key, let path, let side, let line, let startLine, let sha?) = ship.composer else { return nil }
            let body = ship.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { throw Refusal("write something first") }
            let c = ship.composer
            ship.setText(key, "")
            ship.composer = nil
            ship.host.clearMark()
            return Write(path: repoPath("/review-note"),
                         body: ["branch": .string(name()), "sha": .string(sha), "path": .string(path), "side": .string(side.rawValue),
                                "line": .number(Double(line)), "startLine": startLine.map { .number(Double($0)) } ?? .null, "body": .string(body)],
                         settled: { true }, said: "claude window ready — send it there", failed: "couldn't start the Claude session",
                         rollback: { ship.setText(key, body); ship.composer = c })
        }

        /// The composer's words as a new ledger item; send: on to the pending review, else a draft.
        let addItem = { (send: Bool) throws -> Write? in
            guard let c = ship.composer, let id = page(), let d = draft() else { return nil }
            let body = ship.text(c.key).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { throw Refusal("write something first") }
            let waits = unpushedNamed(body)
            let key = Ledger.rid()
            let state = waits.isEmpty ? (send ? "sending" : "draft") : "waiting"
            var item: JSONObject = ["key": .string(key), "body": .string(body), "err": .null, "send": .bool(send), "at": .string(Ledger.iso()),
                                    "waitsFor": .array(waits.map(JSONValue.string)), "state": .string(state)]
            var wire: JSONObject = ["key": .string(key), "body": .string(body)]
            switch c {
            case .line(_, let path, let side, let line, let startLine, _):
                let fields: JSONObject = ["kind": "comment", "path": .string(path), "side": .string(side.rawValue), "line": .number(Double(line)),
                                          "startLine": startLine.map { .number(Double($0)) } ?? .null]
                item.merge(fields) { $1 }
                wire.merge(fields) { $1 }
            case .reply(_, let threadID):
                let node = thread(threadID)?.node
                item.merge(["kind": "reply", "thread": node.map(JSONValue.string) ?? .null, "threadId": .string(threadID)]) { $1 }
                wire.merge(["kind": "reply", "thread": node.map(JSONValue.string) ?? .null]) { $1 }
            }
            ship.setText(c.key, "")
            ship.composer = nil
            ship.host.clearMark()
            let existing = (store.rawView("draft", id)?["items"]?.array) ?? []
            let restore = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if store.table(Draft.self)[id]?.items.contains(where: { $0.key == key }) == true { return }
                    ship.setText(c.key, body)
                    ship.composer = c
                }
            }
            let undoKey = weakApp?.registry.keyOf("review.pending.remove") ?? "d"
            let sendKey = weakApp?.registry.keyOf("review.send") ?? "p"
            let ghKey = weakApp?.registry.keyOf("review.finish") ?? "g h"
            _ = d
            return Write(
                ops: [Op(type: .draft, id: id, fields: ["items": .array(existing + [.object(item)])])],
                path: repoPath("/review-draft"),
                body: ["branch": .string(name()), "op": "add", "send": .bool(send), "item": .object(wire)],
                settled: {
                    guard let got = store.table(Draft.self)[id]?.items.first(where: { $0.key == key }) else { return false }
                    return got.state != .sending
                },
                said: !waits.isEmpty ? "kept as a draft until \(waits.map { String($0.prefix(7)) }.joined(separator: ", ")) is on origin — \(undoKey) drops it"
                    : send ? "in your pending review — \(ghKey) opens GitHub to submit it" : "saved as a draft — \(sendKey) sends it",
                failed: send ? "kept as a draft, not on GitHub" : "the draft didn't save",
                inverse: send ? nil : { _ in Inverse(id: "review.pending.remove", target: key) },
                rollback: restore)
        }

        let composing: (String?) -> Bool = { _ in ship.composer != nil }
        r.register(Command(
            id: "review.compose.send", title: "Add to your pending review on GitHub (or hand a commit's note to Claude)", scope: .review, budget: .slowIO,
            keys: ["C-ret"], modes: [.normal, .insert], label: "send", available: composing,
            write: { _, _ in
                let w = noting() ? try handNote() : try addItem(true)
                weakApp?.keys.setMode(.normal)
                return w
            }))
        r.register(Command(
            id: "review.compose.draft", title: "Save the comment as a draft (only here)", scope: .review, budget: .configWrite,
            keys: ["A-ret"], modes: [.normal, .insert], label: "draft",
            available: { _ in ship.composer != nil && !noting() },
            write: { _, _ in
                let w = try addItem(false)
                weakApp?.keys.setMode(.normal)
                return w
            }))
        r.register(Command(
            id: "review.compose.cancel", title: "Cancel the comment", scope: .review, quiet: true, available: composing,
            local: { _, _ in
                if let c = ship.composer { ship.setText(c.key, "") }
                ship.composer = nil
                if weakApp?.insertField == composeField { weakApp?.keys.setMode(.normal) }
            }))
        r.register(Command(
            id: "review.compose.edit", title: "Go back to writing the comment", scope: .review, keys: ["i"], label: "write",
            available: { _ in ship.composer != nil && weakApp?.keys.mode != .insert },
            local: { _, _ in weakApp?.beginInsert(composeField) }))
        r.register(Command(
            id: "review.compose.suggest", title: "Insert a suggestion", scope: .review, keys: ["C-g"], modes: [.normal, .insert], label: "suggest",
            available: { _ in ship.composer != nil && !noting() },
            local: { _, _ in
                guard let app = weakApp, let c = ship.composer else { return }
                var lines: [String] = []
                switch c {
                case .line(_, let path, _, let line, let startLine, _):
                    lines = ship.host.newLines(app, path: path, from: startLine ?? line, to: line)
                case .reply(_, let tid):
                    if let t = thread(tid), let l = t.local { lines = ship.host.newLines(app, path: t.path, from: l.startLine ?? l.line, to: l.line) }
                }
                let cur = ship.text(c.key)
                ship.setText(c.key, "\(cur)\(!cur.isEmpty && !cur.hasSuffix("\n") ? "\n" : "")```suggestion\n\(lines.joined(separator: "\n"))\n```\n")
            }))

        let item = { (key: String?) -> DraftItem? in draft()?.items.first { $0.key == key } }
        let unsent = { (i: DraftItem?) -> Bool in i.map { $0.state == .draft || $0.state == .waiting || $0.state == .gone } ?? false }
        r.register(Command(
            id: "review.pending.remove", title: "Delete the draft", scope: .pending, budget: .configWrite, keys: ["d"], label: "delete",
            available: { key in unsent(item(key)) },
            write: { key, _ in
                guard let id = page(), let it = item(key) else { return nil }
                let rest = (store.rawView("draft", id)?["items"]?.array ?? []).filter { $0["key"]?.string != key }
                return Write(ops: [Op(type: .draft, id: id, fields: ["items": .array(rest)])],
                             path: repoPath("/review-draft"), body: ["branch": .string(name()), "op": "remove", "key": .string(key)],
                             settled: { store.table(Draft.self)[id]?.items.contains { $0.key == key } != true },
                             said: "draft deleted · \(weakApp?.registry.keyOf("undo") ?? "u") undoes", failed: "couldn't delete the draft",
                             inverse: { _ in Inverse(id: "review.pending.restore", target: id, arg: it) })
            }))
        r.register(Command(
            id: "review.pending.restore", title: "Put a draft back", scope: .review, budget: .configWrite, needsArg: true, quiet: true,
            write: { _, arg in
                guard let id = page(), let it = arg as? DraftItem else { return nil }
                var x = it
                x.state = .draft
                let back = (try? JSONValue.from(x)) ?? .null
                let items = (store.rawView("draft", id)?["items"]?.array ?? []) + [back]
                var wire: JSONObject = ["key": .string(it.key), "kind": .string(it.kind), "body": .string(it.body)]
                if let p = it.path { wire["path"] = .string(p) }
                if let s = it.side { wire["side"] = .string(s.rawValue) }
                if let l = it.line { wire["line"] = .number(Double(l)) }
                if let s = it.startLine { wire["startLine"] = .number(Double(s)) }
                if let t = it.thread { wire["thread"] = .string(t) }
                return Write(ops: [Op(type: .draft, id: id, fields: ["items": .array(items)])],
                             path: repoPath("/review-draft"), body: ["branch": .string(name()), "op": "add", "item": .object(wire)],
                             settled: { store.table(Draft.self)[id]?.items.contains { $0.key == it.key } == true },
                             failed: "couldn't put the draft back")
            }))

        let sendWrite = { (keys: [String]) -> Write? in
            guard let id = page(), !keys.isEmpty else { return nil }
            let items = (store.rawView("draft", id)?["items"]?.array ?? []).map { v -> JSONValue in
                guard var o = v.object, let k = o["key"]?.string, keys.contains(k), o["state"]?.string == "draft" else { return v }
                o["state"] = "sending"
                o["err"] = .null
                return .object(o)
            }
            return Write(ops: [Op(type: .draft, id: id, fields: ["items": .array(items)])],
                         path: repoPath("/review-draft"), body: ["branch": .string(name()), "op": "send", "keys": .array(keys.map(JSONValue.string))],
                         settled: { store.table(Draft.self)[id]?.items.contains { keys.contains($0.key) && $0.state == .sending } != true },
                         said: "in your pending review — \(weakApp?.registry.keyOf("review.finish") ?? "g h") opens GitHub to submit it",
                         failed: "kept as a draft, not on GitHub")
        }
        r.register(Command(id: "review.send", title: "Send the draft to your pending review", scope: .pending, budget: .slowIO, keys: ["p"], label: "send",
                           available: { key in item(key)?.state == .draft }, write: { key, _ in sendWrite([key]) }))
        r.register(Command(id: "review.send.all", title: "Send every draft to your pending review", scope: .review, budget: .slowIO, keys: ["space p"], label: "send all",
                           available: { _ in draft()?.items.contains { $0.state == .draft } == true },
                           write: { _, _ in sendWrite((draft()?.items ?? []).filter { $0.state == .draft }.map(\.key)) }))

        r.register(Command(
            id: "review.reply", title: "Reply", scope: .thread, keys: ["r"], label: "reply",
            available: { id in canWrite() && thread(id) != nil },
            local: { id, _ in
                guard let t = thread(id) else { return }
                let key = "r|\(t.id)"
                if ship.text(key).isEmpty, let by = t.local?.addressedBy, conv()?.unpushed.contains(by) == true {
                    ship.setText(key, "Addressed in \(by.prefix(7)): ")
                }
                ship.unfold[t.id] = true
                try compose(.reply(key: key, threadID: t.id))
            }))
        r.register(Command(
            id: "review.note.insert", title: "Reply with the second reader's draft", scope: .thread, keys: ["i"], label: "insert",
            available: { id in canWrite() && thread(id)?.note?.draftReply?.isEmpty == false },
            local: { id, _ in
                guard let t = thread(id), let d = t.note?.draftReply else { return }
                let key = "r|\(t.id)"
                ship.setText(key, d)
                ship.unfold[t.id] = true
                try compose(.reply(key: key, threadID: t.id))
            }))
        r.register(Command(
            id: "review.fold", title: "Fold or unfold the conversation", scope: .thread, keys: ["ret"], label: "fold",
            local: { id, _ in if let t = thread(id) { ship.unfold[t.id] = !ship.isOpen(t) } }))
        r.register(Command(
            id: "review.note.toggle", title: "Open or fold the second reader's note", scope: .thread, keys: ["z"], label: "note",
            available: { id in thread(id)?.note != nil },
            local: { id, _ in
                guard let id else { return }
                ship.unfold["note:\(id)"] = !(ship.unfold["note:\(id)"] ?? false)
            }))
        r.register(Command(
            id: "review.thread.show", title: "Show the conversation at its line", scope: .review, needsArg: true, quiet: true,
            local: { _, arg in
                guard let app = weakApp, let id = arg as? String, let t = thread(id) else { return }
                ship.unfold[t.id] = true
                ship.host.showThread(app, id: t.id)
            }))
        r.register(Command(
            id: "review.resolve", title: "Resolve on GitHub (opens the conversation there)", scope: .thread, keys: ["R"], label: "resolve",
            available: { id in thread(id)?.comments.first.map { !$0.url.isEmpty } == true },
            local: { id, _ in if let u = thread(id)?.comments.first.flatMap({ URL(string: $0.url) }) { open(u) } }))
        r.register(Command(
            id: "review.apply", title: "Apply suggestion (a local commit)", scope: .thread, budget: .gitWrite, keys: ["a"], label: "apply",
            available: { id in
                guard let t = thread(id) else { return false }
                return !t.outdated && t.side == .right && t.local?.addressedBy == nil && t.applying != true
                    && t.comments.contains { Markdown.suggestionOf($0.body) != nil }
            },
            write: { id, _ in
                guard let t = thread(id), let pid = page() else { return nil }
                let tip = branch(pid)?.tip ?? conv()?.tip ?? ""
                return Write(ops: [Op(type: .thread, id: t.id, fields: ["applying": true])],
                             path: repoPath("/review-apply"), body: ["branch": .string(name()), "thread": .string(t.node)],
                             settled: { store.table(CanopyCore.Thread.self)[t.id]?.local?.addressedBy != nil || (store.table(Conv.self)[pid]?.tip ?? tip) != tip },
                             said: "applied · \(weakApp?.registry.keyOf("undo") ?? "u") undoes", failed: "couldn't apply the suggestion",
                             inverse: { a in a["sha"]?.string.map { Inverse(id: "review.unapply", target: pid, arg: $0) } })
            }))
        r.register(Command(
            id: "review.unapply", title: "Drop the applied suggestion's commit", scope: .review, budget: .gitWrite, needsArg: true, quiet: true,
            write: { id, arg in
                guard let sha = arg as? String else { return nil }
                return Write(path: repoPath("/revert-commit"), body: ["branch": .string(name()), "sha": .string(sha)],
                             settled: { (store.table(Conv.self)[id]?.tip ?? store.table(Branch.self)[id]?.tip) != sha },
                             said: "dropped \(sha.prefix(7))", failed: "couldn't drop \(sha.prefix(7))")
            }))

        // ── submitting happens on GitHub ──

        r.register(Command(
            id: "review.finish", title: "Go to GitHub — submit your review, or open the PR once it's pushed", scope: .review, keys: ["g h"], label: "github",
            route: { id in
                if canWrite() { return RouteTo("review.github", target: id) }
                return weakApp?.forestModel.opensPR(id) == true ? RouteTo("branch.pr", target: id) : nil
            }))
        r.register(Command(
            id: "review.preview", title: "Preview this branch — a dev server on a side port, opened once it answers", scope: .review, keys: ["g p"], label: "preview",
            route: { id in
                guard let app = weakApp, let id, let b = ShipRows.splitID(id) else { return nil }
                if let p = Route.integrationOf(b.name), app.store.view(Project.self, "\(b.repo):\(p)") != nil { return RouteTo("forest.preview", target: "\(b.repo):\(p)") }
                return branch(id) != nil ? RouteTo("branch.preview", target: id) : nil
            }))
        r.register(Command(
            id: "review.github", title: "Go to GitHub to submit your review", scope: .review, quiet: true,
            available: { _ in canWrite() },
            local: { _, _ in if let c = conv(), let u = URL(string: "\(c.url)/files") { open(u) } }))

        r.register(Command(
            id: "branch.pr", title: "Go to the PR (the prefilled compare form if there's none yet)", scope: .branch, keys: ["g h"], label: "pr", v1: ["open-pr"],
            available: { id in weakApp?.forestModel.opensPR(id) ?? false },
            local: { id, _ in
                guard let app = weakApp, let id, let b = branch(id) else { return }
                if let pr = store.view(Pr.self, id), let u = URL(string: pr.url) { open(u) } else if let v = app.forestModel.branchView(b.id) { open(app.forestModel.compareURL(v)) }
            }))
        r.register(Command(
            id: "branch.preview", title: "Preview it — a dev server on a side port, opened once it answers", scope: .branch, keys: ["g p"], label: "preview",
            v1: ["node.preview"],
            available: { id in branch(id) != nil },
            local: { id, _ in
                guard let b = branch(id) else { return }
                open(tr.url(tr.atRepo(b.repo, "/preview-wait") + "?branch=\(b.name.uriComponent)"))
            }))
        r.register(Command(
            id: "forest.preview", title: "Preview the whole forest — every branch merged, on a side port, opened once it answers", scope: .project,
            keys: ["g p"], label: "preview", v1: ["click:build this project's integration"],
            available: { pid in
                guard let pid else { return false }
                let bs = store.list(Branch.self).filter { $0.project == pid }
                return bs.count > 1 && bs.contains { ShipRules.shipOf($0, store.view(Pr.self, $0.id)) != .landed }
            },
            local: { pid, _ in
                guard let pid, let p = store.view(Project.self, pid) else { return }
                open(tr.url(tr.atRepo(p.repo, "/preview-wait") + "?project=\(p.name.uriComponent)"))
            }))

        // ── the gates strip: which gate's output it shows ──

        r.register(Command(
            id: "review.gates.show", title: "Show the next gate's output in the gates strip (round to the running one)", scope: .review,
            keys: ["space g"], label: "gate output",
            available: { id in !(GatesRun.rows(id.flatMap { ship.progressOf($0) }, now: Date().timeIntervalSince1970).isEmpty) },
            local: { id, arg in
                guard let id else { return }
                let rows = GatesRun.rows(ship.progressOf(id), now: Date().timeIntervalSince1970).filter { $0.state != .queued }
                if let g = arg as? String {
                    ship.gateShown = ship.gateShown == "\(id) \(g)" ? nil : "\(id) \(g)"
                    return
                }
                let cur = ship.gateShown.flatMap { $0.hasPrefix("\(id) ") ? String($0.dropFirst(id.count + 1)) : nil }
                let i = cur.flatMap { c in rows.firstIndex { $0.name == c } }.map { $0 + 1 } ?? 0
                ship.gateShown = i < rows.count ? "\(id) \(rows[i].name)" : nil
            }))
        r.register(Command(
            id: "review.gates.skip", title: "Skip the red gate shown (else the first red one) for this code and re-run the rest", scope: .review,
            available: { id in
                guard let id else { return false }
                return weakApp?.registry.command("branch.gates.skip") != nil
                    && GatesRun.rows(ship.progressOf(id), now: 0).contains { $0.state == .red }
            },
            local: { id, _ in
                guard let app = weakApp, let id else { return }
                let rows = GatesRun.rows(ship.progressOf(id), now: 0)
                let red = rows.filter { $0.state == .red }
                let shown = ship.gateShown.flatMap { $0.hasPrefix("\(id) ") ? String($0.dropFirst(id.count + 1)) : nil }
                guard let g = red.first(where: { $0.name == shown }) ?? red.first else { throw Refusal("no red gate") }
                let skipped = rows.filter { $0.state == .waived && $0.summary?.hasSuffix("skipped by you") == true }.map(\.name)
                app.runner.dispatch("branch.gates.skip", via: .key, target: "\(id) \((skipped + [g.name]).joined(separator: ","))")
            }))
    }

    /// What `p` does here: area A's `branch.push` route (arm, send, run the gates, force) for the branch.
    static func pushRoute(_ app: AppModel?, _ id: String?) -> String? {
        guard let app, let id, let route = app.registry.command("branch.push")?.route else { return nil }
        return route(id)?.id
    }

    /// The unpushed commits the address sheet offers, newest first, nine at most.
    static func addressCandidates(_ app: AppModel?) -> [OutlineCommit] {
        guard let app, let id = ShipSeam.branchID(app) else { return [] }
        return Array((WordsState.of(app).shown[id]?.commits ?? []).filter { $0.locked.isEmpty }.reversed().prefix(9))
    }
}

/// The ledger's small pure helpers.
enum Ledger {
    /// The unpushed commits a body names by sha — a reply naming one waits until it's on origin.
    static func unpushedIn(_ body: String, _ unpushed: [String]) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\b[0-9a-f]{7,40}\\b")
        let ns = body as NSString
        var out: [String] = []
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            for s in unpushed where s.hasPrefix(w) && !out.contains(s) { out.append(s) }
        }
        return out
    }

    static func rid() -> String { String((0..<10).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }

    static func iso(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
