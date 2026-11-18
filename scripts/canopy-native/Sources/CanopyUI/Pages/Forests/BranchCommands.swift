import CanopyCore
import Foundation

/// commands/branch.ts: a branch's way to main — push it (POST /push-origin: two keypresses, never by
/// itself; or the gates first when they're all that stands in the way), the one sanctioned force,
/// open its page, its description, and holding work for the morning (POST /outbox-hold). Nothing
/// here pushes, opens or merges on its own. `branch.pr` and `branch.preview` are Ship's.
@MainActor
enum BranchCommands {
    /// The description as the server stores it: one line, runs of space folded (srv/outline.py).
    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The field a branch's description is written in, here and on its review page: one draft.
    static func describeField(_ id: String) -> String { WordsRow.desc.field(id) }

    /// What `p` does: arm, then send — or, when only the gates stand in the way, run them. A branch
    /// diverged from origin can't push; inside the force scope `p` arms a force-with-lease instead.
    static func pushRoute(_ id: String?, _ app: AppModel) -> String? {
        guard let id, let v = app.forestModel.branchView(id) else { return nil }
        let next = situation(v, app).next
        switch next {
        case "branch.push.arm": return app.runner.armed == pushArm(id) ? "branch.push.confirm" : next
        case "branch.force.arm": return app.runner.armed == forceArm(id) ? "branch.force.confirm" : next
        case "branch.conform", "branch.catchup", "branch.gates.run", "branch.gates.next", "branch.proof": return next
        default: return nil
        }
    }

    /// The branch's situation with every read the branch page has made for this tip.
    static func situation(_ v: BranchView, _ app: AppModel) -> Stand {
        let ship = ShipState.of(app), id = v.b.id
        let scope = forceScope(id, app)
        let reads = SituationReads(
            prepRoute: ship.prepOf(id)?.route, prepRead: ship.prepFresh(id),
            force: scope.map { ($0.eligible, !$0.guards.allSatisfy { $0.ok || $0.k == "gates" }) },
            gatesCanPutNext: GatesRun.canPutNext(GatesRun.setup(ship.progressOf(id))),
            agent: v.st.actor.agentItem)
        return ShipRules.stand(v.b, v.pr, app.forestModel.parentStand(of: v.b), now: app.forestModel.now, reads: reads)
    }

    /// `p` while the gates run: put the run next when anything waits ahead of it — otherwise the
    /// press moves nothing, and `p` has no route until the gates answer.
    static func runningRoute(_ id: String, _ app: AppModel) -> String? {
        GatesRun.canPutNext(GatesRun.setup(ShipState.of(app).progressOf(id))) ? "branch.gates.next" : nil
    }

    /// An additive push onto a PR that's open: origin already has the branch and local only adds to it.
    static func quickFollowUp(_ v: BranchView) -> Bool { ShipRules.gatesAdvise(v.b, v.pr) }

    /// What a push's answer says about the children it carried: who came along, and the first
    /// that needs a hand. nil when it carried none.
    static func carriedLine(_ body: JSONObject) -> String? {
        guard case .array(let rows)? = body["carried"], !rows.isEmpty else { return nil }
        let recs = rows.compactMap { r -> (String, String?)? in
            guard case .object(let o) = r, let b = o["branch"]?.string else { return nil }
            return (leaf(b), o["err"]?.string)
        }
        let moved = recs.filter { $0.1 == nil }.map(\.0), stuck = recs.filter { $0.1 != nil }
        var parts: [String] = []
        if !moved.isEmpty { parts.append("carried \(moved.joined(separator: ", ")) along") }
        if let s = stuck.first { parts.append("\(s.0) stayed — \(s.1 ?? "")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the runner holds while a branch's push, or its force, waits for the second press.
    static func pushArm(_ id: String) -> String { "push \(id)" }
    static func forceArm(_ id: String) -> String { "force \(id)" }

    /// Whether this branch has a push or a force waiting for its second press.
    static func isArmed(_ id: String, _ app: AppModel) -> Bool {
        app.runner.armed == pushArm(id) || app.runner.armed == forceArm(id)
    }

    /// The branch whose description is being typed, if any.
    static func describing(_ app: AppModel) -> String? { LineEdit.target(app.insertField, prefix: "words.desc") }

    /// ↵ on a description: save the draft (and leave the field).
    static func saveDescription(_ app: AppModel, _ id: String) {
        let saved = app.store.view(Branch.self, id)?.description ?? ""
        LineEdit.of(app).save(app, describeField(id), saved: saved, command: "branch.describe", target: id)
    }

    /// The force scope Ship read for this tip (`ShipState`: GET /force-scope, once per tip), if any.
    static func forceScope(_ id: String?, _ app: AppModel) -> ForceScope? { ShipState.of(app).forceScopeOf(app, id) ?? nil }

    static func install(_ app: AppModel) {
        unowned let app = app
        let r = app.registry
        let m = app.forestModel
        let s = app.store
        let t = app.transport

        r.register(Command(
            id: "branch.push", title: "Push to origin", scope: .branch, verb: .push, label: "push",
            route: { id in pushRoute(id, app).map { RouteTo($0, target: id) } }))

        r.register(Command(id: "branch.proof", title: "A proof branch never pushes — it rides the forest for its run", scope: .branch, quiet: true,
                           local: { _, _ in throw Refusal("a proof branch never pushes or merges — it rides the forest for its e2e run; its gates are green") }))

        func gatesWrite(_ v: BranchView, skip: [String], quick: Bool = false) -> Write {
            let id = v.b.id, was = v.b.gates
            var body: JSONObject = ["branch": .string(v.b.name), "detach": true]
            if !skip.isEmpty { body["skip"] = .array(skip.map(JSONValue.string)) }
            if quick { body["mode"] = "quick" }
            // the server's answer settles the overlay when nothing new will run: a tree that already
            // passed answers cached (a run that finished the same second as the press, 2026-11-05)
            // and the server's copy was green all along, so "gates changed" would never come
            var answeredCached = false
            return Write(
                ops: [Op(type: .branch, id: id, fields: ["gates": "running"])],
                path: t.atRepo(v.b.repo, "/gates"), body: .object(body),
                settled: { answeredCached || s.table(Branch.self)[id]?.gates != was },
                said: !skip.isEmpty ? "skipping \(skip.joined(separator: ", ")) for this code — the rest re-run"
                    : quick ? "running the quick gates — typecheck and lint left to CI" : "running the gates — p pushes once they're green",
                failed: "the gates didn't start",
                answered: { ok, body in if ok, body["cached"] == true { answeredCached = true } })
        }
        r.register(Command(
            id: "branch.catchup", title: "Catch the chain up to its moved ancestors — drafts rebase, published links get a catch-up merge",
            scope: .branch, label: "catch up", quiet: true,
            available: { id in m.branchView(id)?.b.owes != nil },
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(path: t.atRepo(v.b.repo, "/catch-up"), body: ["branch": .string(v.b.name)], settled: { true },
                             said: "caught the chain up — p pushes next",
                             failed: "the catch-up stopped — a conflict to resolve by hand, or the forest is busy", alone: true)
            }))
        r.register(Command(
            id: "branch.conform", title: "Take origin's copy — it was rewritten upstream and already has everything local has",
            scope: .branch, label: "take origin's copy", quiet: true,
            available: { id in id.map { ShipState.of(app).prepOf($0)?.route == "conform" } ?? false },
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(path: t.atRepo(v.b.repo, "/prep-push"), body: ["branch": .string(v.b.name)], settled: { true },
                             said: "took origin's copy — local matches the PR again",
                             failed: "couldn't take origin's copy — local moved, or its worktree has uncommitted changes", alone: true)
            }))
        r.register(Command(
            id: "branch.gates.run", title: "Run the push gates", scope: .branch, label: "gates", quiet: true,
            available: { id in m.branchView(id).map { $0.b.gates != .running } ?? false },
            write: { id, _ in m.branchView(id).map { gatesWrite($0, skip: []) } }))
        r.register(Command(
            id: "branch.gates.quick", title: "Run the quick gates — typecheck and lint left to CI, which runs them on push",
            scope: .branch, label: "quick gates", quiet: true,
            available: { id in m.branchView(id).map { $0.b.gates != .running } ?? false },
            write: { id, _ in m.branchView(id).map { gatesWrite($0, skip: [], quick: true) } }))
        r.register(Command(
            id: "branch.gates.skip", title: "Skip a red gate for this code and re-run the rest (\"<branch> <gates> quick\" keeps a quick run quick)",
            scope: .branch, needsArg: true, quiet: true,
            write: { target, _ in
                let parts = target.split(separator: " ").map(String.init)
                let skip = (parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
                guard let v = m.branchView(parts.first), !skip.isEmpty else { return nil }
                return gatesWrite(v, skip: skip, quick: parts.dropFirst(2).contains("quick"))
            }))
        r.register(Command(
            id: "branch.gates.next", title: "Put this branch's queued gates ahead of every run you didn't click",
            scope: .branch, quiet: true,
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(
                    path: t.atRepo(v.b.repo, "/gates"), body: ["branch": .string(v.b.name), "next": true],
                    settled: { true },
                    said: "these gates go next — p pushes once they're green",
                    failed: "the gates are running — p pushes once they're green", alone: true)
            }))
        r.register(Command(
            id: "branch.review.run", title: "Review this branch's diff — the findings land as review flags for this code",
            scope: .branch, label: "review", quiet: true,
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(
                    path: t.atRepo(v.b.repo, "/review"), body: ["branch": .string(v.b.name)],
                    settled: { true },
                    said: "reviewing this code — the flags show when it's done",
                    failed: "the review didn't start", alone: true)
            }))
        r.register(Command(
            id: "branch.gates.waive", title: "Ship this exact code without the gates — the door says it was your call",
            scope: .branch, label: "waive gates", quiet: true,
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(
                    path: t.atRepo(v.b.repo, "/gates-waive"), body: ["branch": .string(v.b.name)],
                    settled: { true },
                    said: "gates waived for this code — p pushes it",
                    failed: "the waiver didn't take", alone: true)
            }))
        r.register(Command(
            id: "branch.push.arm", title: "Ready a push (the next press sends it)", scope: .branch, quiet: true,
            available: { id in m.branchView(id).map { ShipRules.canPush($0.b, $0.pr) } ?? false },
            local: { id, _ in if let id { try app.runner.arm(pushArm(id)) } }))
        r.register(Command(
            id: "branch.push.confirm", title: "Send the readied push", scope: .branch, budget: .gitWrite, v1: ["push-origin"], quiet: true,
            available: { id in id.map { app.runner.armed == pushArm($0) } ?? false },
            write: { id, _ in
                guard let v = m.branchView(id) else { return nil }
                return Write(
                    ops: [Op(type: .branch, id: id, fields: ["pending": "pushing"])],
                    path: t.atRepo(v.b.repo, "/push-origin"), body: ["branch": .string(v.b.name), "stay": true],
                    settled: { s.table(Branch.self)[id]?.pushed == .synced },
                    said: v.pr.map { "pushed \(v.b.ahead) follow-up\(v.b.ahead == 1 ? "" : "s") onto #\($0.number)" },
                    failed: "\(leaf(v.b.name)) didn't push",
                    answered: { ok, body in
                        // the children the push carried (P7) are said right after the push's own line
                        guard ok, let line = carriedLine(body) else { return }
                        DispatchQueue.main.async { app.runner.say(line) }
                    })
            }))

        // ── the one sanctioned force: replace origin's copy while nobody else has read it ──

        r.register(Command(
            id: "branch.force.arm", title: "Ready a force-with-lease over origin (the next press sends it)", scope: .branch, quiet: true,
            available: { id in m.branchView(id)?.b.diverged == true && forceScope(id, app)?.eligible == true },
            local: { id, _ in if let id { try app.runner.arm(forceArm(id)) } }))
        r.register(Command(
            id: "branch.force.confirm", title: "Send the readied force-with-lease", scope: .branch, budget: .gitWrite, v1: ["force-origin"], quiet: true,
            available: { id in id.map { app.runner.armed == forceArm($0) } == true && forceScope(id, app)?.eligible == true },
            write: { id, _ in
                let sc = forceScope(id, app)
                guard let v = m.branchView(id), let sc else { return nil }
                return Write(
                    ops: [Op(type: .branch, id: id, fields: ["pending": "pushing"])],
                    path: t.atRepo(v.b.repo, "/force-origin"), body: ["branch": .string(v.b.name), "lease": .string(sc.lease)],
                    settled: { s.table(Branch.self)[id]?.diverged == false },
                    said: "replaced origin's \(sc.lease.prefix(7))",
                    failed: "\(leaf(v.b.name)) didn't replace origin",
                    // the answer carries the scope as it now stands
                    answered: { _, body in
                        if let fs = body["forceScope"], let sc = try? fs.decode(ForceScope.self) { ShipState.of(app).putForceScope(app, id, sc) }
                    })
            }))

        r.register(Command(
            id: "branch.open", title: "Open the branch", scope: .branch, verb: .main, label: "open",
            available: { m.branchView($0) != nil },
            local: { id, _ in
                guard let b = m.branchView(id)?.b else { return }
                app.go(.review(repo: b.repo, branch: b.name))
            }))

        // ── its description: the branch's one human line ──

        r.register(Command(
            id: "branch.describe", title: "Save the branch's description", scope: .global, budget: .configWrite, needsArg: true, quiet: true,
            write: { id, arg in
                guard let b = s.view(Branch.self, id) else { return nil }
                let next = oneLine(arg as? String ?? "")
                if next == b.description { return nil }
                let before = b.description
                return Write(
                    ops: [Op(type: .branch, id: id, fields: ["description": .string(next)])],
                    path: t.atRepo(b.repo, "/outline"), body: ["branch": .string(b.name), "edits": [], "description": .string(next)],
                    settled: { s.table(Branch.self)[id]?.description == next },
                    said: "description saved · u undoes", failed: "couldn't save the description",
                    inverse: { _ in Inverse(id: "branch.describe", target: id, arg: before) })
            }))
        r.register(Command(
            id: "branch.describe.edit", title: "Edit the branch's description in place", scope: .branch, verb: .write, label: "describe",
            available: { id in app.router.surface.id == "forest" && m.face == .branches && m.branchView(id) != nil },
            local: { id, _ in
                guard let id, s.view(Branch.self, id) != nil else { return }
                LineEdit.of(app).open(app, describeField(id))
            }))
        r.register(Command(
            id: "branch.describe.save", title: "Save the description you're typing", scope: .forest, verb: .send, modes: [.insert],
            label: "save", quiet: true,
            available: { _ in describing(app) != nil },
            local: { _, _ in if let id = describing(app) { saveDescription(app, id) } }))

        // ── holding work for the morning ──

        /// What a hold on this row covers: the branch, or every branch of the forest not yet on GitHub.
        func holdable(_ row: String?) -> [BranchView] {
            guard let row else { return [] }
            if let id = RowKey.id(row, "b") {
                guard let v = m.branchView(id), v.pr == nil, v.st.ship != .landed, v.b.commits > 0 else { return [] }
                return [v]
            }
            return (m.forest(RowKey.id(row, "p"))?.unopened ?? []).filter { $0.b.commits > 0 }
        }
        func holdWrite(_ row: String, _ ids: [String], until: String?) -> Write? {
            guard let first = ids.first, let repo = s.view(Branch.self, first)?.repo else { return nil }
            let names = ids.compactMap { s.view(Branch.self, $0)?.name }
            let what = ids.count == 1 ? leaf(names.first ?? first) : "\(ids.count) branches"
            return Write(
                ops: ids.map { Op(type: .branch, id: $0, fields: ["holdUntil": until.map(JSONValue.string) ?? .null]) },
                path: t.atRepo(repo, "/outbox-hold"),
                body: ["branches": .array(names.map(JSONValue.string)), "until": .string(until ?? "")],
                settled: { ids.allSatisfy { s.table(Branch.self)[$0]?.holdUntil == until } },
                said: until.flatMap(parseISO).map { "holding \(what) for \(PushWindow.fmtMorning($0)) — u lets go" },
                failed: until != nil ? "couldn't hold \(what)" : "couldn't release \(what)",
                inverse: { _ in Inverse(id: until != nil ? "hold.release" : "hold.morning", target: row, arg: ids) })
        }
        r.register(Command(
            id: "hold.morning", title: "Hold for the morning", scope: .row, budget: .configWrite, leader: LocalKey(",b"), label: "hold", v1: ["outbox-hold"],
            available: { row in holdable(row).contains { $0.b.holdUntil == nil } },
            write: { row, arg in
                let ids = arg as? [String] ?? holdable(row).filter { $0.b.holdUntil == nil }.map(\.b.id)
                return holdWrite(row, ids, until: isoString(PushWindow.nextMorning(m.now)))
            }))
        r.register(Command(
            id: "hold.release", title: "Release the hold", scope: .row, budget: .configWrite, leader: LocalKey(",B"), label: "unhold",
            available: { row in holdable(row).contains { $0.b.holdUntil != nil } },
            write: { row, arg in
                let ids = arg as? [String] ?? holdable(row).filter { $0.b.holdUntil != nil }.map(\.b.id)
                return holdWrite(row, ids, until: nil)
            }))

        // esc backs out of a launch (commands/app.ts overlay.close)
        app.addCloser(isOpen: { m.launching != nil }, close: { m.launching = nil })
    }
}
