import CanopyCore
import Foundation

// commands/sync.ts — ⟲ sync: everything local that makes a branch pushable, in one motion and v1's
// order: a dirty tree is a decision (fold, stash or stop), a drifted branch is reseated on its
// parent, a branch behind main rebases (or its forest's restack is queued), the outgoing commits take
// one voiced shape (/prep-push), then the gates start detached and the related tests run as advice.
// A conflict or a divergence with no mechanical route goes to Claude — the server's own hand-offs —
// and the ship strip says so. Each step is a registered command posted through the runner, so every
// one is measured; the motion only sequences them. Also the rare repairs: reseat, detach a footgun
// upstream, inspect a divergence.

/// A step's argument: how the motion hears the step's answer.
final class StepArg {
    var done: ((Bool, JSONObject) -> Void)?
    var started = false
    var extra: JSONObject
    init(_ extra: JSONObject = [:], done: ((Bool, JSONObject) -> Void)? = nil) { self.extra = extra; self.done = done }
}

@MainActor
enum SyncCommands {
    static func install(_ app: AppModel) {
        let r = app.registry
        let ship = ShipState.of(app)
        let store = app.store
        let tr = app.transport
        func branch(_ id: String?) -> Branch? { id.flatMap { store.view(Branch.self, $0) } }

        /// A step's Write, wired so the motion hears its answer.
        func stepWrite(_ arg: Any?, _ w: Write) -> Write {
            guard let a = arg as? StepArg else { return w }
            a.started = true
            guard let done = a.done else { return w }
            var x = w
            x.silent = true
            x.answered = done
            return x
        }
        func step(_ id: String, path: String, body: @escaping (Branch, StepArg?) -> JSONObject, failed: String, title: String,
                  budget: Budget, v1: String, alone: Bool = false) {
            r.register(Command(id: id, title: title, scope: .branch, budget: budget, v1: [v1], quiet: true,
                               write: { id, arg in
                                   guard let b = branch(id) else { return nil }
                                   return stepWrite(arg, Write(path: tr.atRepo(b.repo, path), body: .object(body(b, arg as? StepArg)),
                                                               settled: { true }, failed: failed, alone: alone))
                               }))
        }
        step("branch.sync.dirt", path: "/dirty-resolve", body: { b, a in ["branch": .string(b.name), "action": a?.extra["action"] ?? .null] },
             failed: "the working tree didn't move", title: "Fold, stash or pop the uncommitted changes of the worktree holding the branch",
             budget: .gitWrite, v1: "dirty-resolve")
        step("branch.sync.rebase", path: "/sync", body: { b, _ in ["branch": .string(b.name)] },
             failed: "the rebase didn't run", title: "Rebase it onto origin/main (or say its forest needs a restack)", budget: .slowIO, v1: "sync")
        step("branch.sync.restack", path: "/restack", body: { _, a in ["project": a?.extra["project"] ?? .null] },
             failed: "the restack didn't start", title: "Queue its forest's restack onto origin/main", budget: .gitWrite, v1: "restack")
        step("branch.sync.prep", path: "/prep-push", body: { b, _ in ["branch": .string(b.name)] },
             failed: "prep failed", title: "Shape the outgoing commits — seal placeholders into one voiced commit", budget: .slowIO, v1: "prep-push")
        step("branch.sync.reconcile", path: "/reconcile", body: { b, _ in ["branch": .string(b.name)] },
             failed: "Claude didn't start", title: "Hand a divergence with no mechanical route to Claude, in the branch's worktree", budget: .slowIO, v1: "reconcile")
        step("branch.sync.tests", path: "/delta-tests", body: { b, _ in ["branch": .string(b.name)] },
             failed: "the tests didn't run", title: "Run the tests related to the branch's changes (advisory)", budget: .slowIO, v1: "delta-tests", alone: true)

        // ── the motion ──

        let running = { (id: String?) in ship.motionOf(id)?.phase == .running }
        let deciding = { (id: String?) in ship.motionOf(id)?.phase == .dirt }
        r.register(Command(
            id: "branch.sync", title: "Sync — fold or stash dirt, reseat, rebase, shape the commits, then gates and tests", scope: .branch,
            keys: ["s"], label: "sync", v1: ["prep-push"],
            available: { id in branch(id).map { !$0.tip.isEmpty } == true && !running(id) && !deciding(id) },
            local: { [weak app] id, _ in
                guard let app, let id else { return }
                let via: Via = .key
                Task { @MainActor in await SyncMotionDriver(app: app).start(id, via: via) }
            }))
        r.register(Command(
            id: "review.sync", title: "Sync this branch — fold or stash dirt, reseat, rebase, shape the commits, then gates and tests", scope: .review,
            keys: ["s"], label: "sync",
            route: { id in branch(id) != nil ? RouteTo("branch.sync", target: id) : nil }))

        // ── the dirt decision, on the branch page ──

        for (cid, label, title, action) in [
            ("review.sync.fold", "fold", "Fold the uncommitted changes into the commit, then sync", "include"),
            ("review.sync.stash", "stash", "Stash the uncommitted changes for the sync, and pop them after", "stash"),
            ("review.sync.stop", "stop", "Stop the sync — leave the working tree as it is", "abort"),
        ] {
            r.register(Command(id: cid, title: title, scope: .review, label: label, available: deciding,
                               local: { [weak app] id, _ in
                                   guard let app, let id else { return }
                                   Task { @MainActor in await SyncMotionDriver(app: app).decide(id, via: .menu, action: action) }
                               }))
        }
        r.register(Command(
            id: "review.sync.dirt.show", title: "Show the next dirty file's uncommitted change (or hide it)", scope: .review, quiet: true,
            available: { id in deciding(id?.split(separator: "|").first.map(String.init)) },
            local: { id, arg in
                guard let id = id?.split(separator: "|").first.map(String.init), let m = ship.motionOf(id) else { return }
                let files = m.dirt?.files ?? []
                if let path = arg as? String {
                    ship.dirtOpen = ship.dirtOpen == "\(id)|\(path)" ? nil : "\(id)|\(path)"
                    return
                }
                // no file named: walk them in turn, then close
                let open = ship.dirtOpen.flatMap { $0.hasPrefix("\(id)|") ? String($0.dropFirst(id.count + 1)) : nil }
                let i = open.flatMap { files.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                ship.dirtOpen = i < files.count ? "\(id)|\(files[i])" : nil
            }))
        r.register(Command(
            id: "review.sync.dismiss", title: "Put the sync's steps away", scope: .review, quiet: true,
            available: { id in ship.motionOf(id) != nil && !running(id) && !deciding(id) },
            local: { id, _ in if let id { ship.motions[id] = nil } }))

        // ── the rare repairs: in the menu only when they apply ──

        r.register(Command(
            id: "review.reseat", title: "Reseat it on its parent's tip (every drifted child of the parent moves back)", scope: .review,
            budget: .gitWrite, label: "reseat", v1: ["reseat-children"],
            available: { id in branch(id)?.drifted == true },
            write: { id, arg in
                guard let b = branch(id) else { return nil }
                return stepWrite(arg, Write(
                    ops: [Op(type: .branch, id: id, fields: ["drifted": false])],
                    path: tr.atRepo(b.repo, "/reseat-children"), body: ["branch": .string(b.parent)],
                    settled: { store.table(Branch.self)[id]?.drifted == false },
                    said: "reseated \(shipLeaf(b.name)) on \(shipLeaf(b.parent))",
                    failed: "\(shipLeaf(b.name)) didn't reseat — a conflict; the forest's restack resolves it"))
            }))
        r.register(Command(
            id: "review.upstream.detach", title: "Detach its upstream — it tracks the trunk, so a Pull would merge main into it", scope: .review,
            budget: .configWrite, label: "detach", v1: ["fix-upstream"],
            available: { id in branch(id)?.upstreamBad == true },
            write: { id, _ in
                guard let b = branch(id) else { return nil }
                return Write(
                    ops: [Op(type: .branch, id: id, fields: ["upstream": "", "upstreamBad": false])],
                    path: tr.atRepo(b.repo, "/fix-upstream"), body: ["branch": .string(b.name)],
                    settled: { store.table(Branch.self)[id]?.upstream == "" },
                    said: "\(shipLeaf(b.name)) tracks nothing now — a Pull can't merge main in",
                    failed: "couldn't detach \(shipLeaf(b.name))'s upstream")
            }))
        r.register(Command(
            id: "review.diverged.inspect", title: "Inspect the divergence — what's only here, what's only on origin, what the PR becomes", scope: .review,
            label: "divergence",
            available: { id in branch(id).map { $0.diverged && !$0.upstream.isEmpty } == true },
            local: { id, _ in
                ship.inspecting = ship.inspecting == id ? nil : id
                if let id { ship.forgetDivergence(id) }
            }))
    }
}

/// Runs one sync motion (commands/sync.ts start/decide/run/finish). Every step is a dispatch.
@MainActor
struct SyncMotionDriver {
    let app: AppModel
    var ship: ShipState { ShipState.of(app) }

    func branch(_ id: String) -> Branch? { app.store.view(Branch.self, id) }

    /// Post step `id` through the runner and resume with the server's answer (a refusal before it
    /// sends resumes at once).
    func step(_ id: String, _ target: String, _ via: Via, _ extra: JSONObject = [:]) async -> (ok: Bool, body: JSONObject) {
        await withCheckedContinuation { (k: CheckedContinuation<(ok: Bool, body: JSONObject), Never>) in
            var resumed = false
            let arg = StepArg(extra) { ok, body in
                guard !resumed else { return }
                resumed = true
                k.resume(returning: (ok, body))
            }
            app.runner.dispatch(id, via: via, target: target, arg: arg)
            if !arg.started && !resumed {
                resumed = true
                k.resume(returning: (false, ["err": "refused before it was sent"]))
            }
        }
    }

    func facts(_ b: Branch) async throws -> SyncFacts {
        try await app.transport.getJSON(app.transport.atRepo(b.repo, "/sync?branch=\(b.name.uriComponent)"), as: SyncFacts.self)
    }

    func start(_ id: String, via: Via) async {
        guard let b = branch(id) else { return }
        ship.motions[id] = SyncMotion(steps: [SyncStep(id: .dirt, label: "working tree", state: .run, t0: Date())], phase: .running, stashed: false, tip: b.tip)
        let f: SyncFacts
        do { f = try await facts(b) } catch {
            ship.setStep(id, .dirt, .fail, "couldn't read the branch — \(error)")
            ship.patch(id) { $0.phase = .stopped }
            return
        }
        ship.motions[id] = SyncMotion(steps: Syncing.planSteps(drifted: b.drifted, facts: f), phase: .running, stashed: false, tip: b.tip)
        if !f.dirty.isEmpty {
            ship.setStep(id, .dirt, .fail, "\(f.dirty.count) uncommitted in \(f.dirtyWorktree.isEmpty ? "the holding worktree" : f.dirtyWorktree) — fold them into the commit, stash them for the run, or stop")
            ship.patch(id) { $0.phase = .dirt; $0.dirt = (f.dirty, f.dirtyRows ?? [], f.dirtyWorktree) }
            app.runner.say("\(shipLeaf(b.name)): \(f.dirty.count) uncommitted — fold, stash or stop on its page")
            return
        }
        await run(id, via: via, facts: f, dirt: nil)
    }

    func decide(_ id: String, via: Via, action: String) async {
        if action == "abort" {
            ship.setStep(id, .dirt, .fail, "stopped — the working tree is untouched")
            ship.patch(id) { $0.phase = .stopped; $0.dirt = nil }
            return
        }
        ship.patch(id) { $0.phase = .running }
        ship.setStep(id, .dirt, .run, action == "include" ? "folding…" : "stashing…")
        let r = await step("branch.sync.dirt", id, via, ["action": .string(action)])
        if !r.ok {
            ship.setStep(id, .dirt, .fail, r.body["err"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "\(action) failed")
            ship.patch(id) { $0.phase = .dirt }
            return
        }
        ship.patch(id) { $0.dirt = nil; $0.stashed = action == "stash" }
        guard let b = branch(id) else { return }
        let f = (try? await facts(b)) ?? SyncFacts()
        await run(id, via: via, facts: f, dirt: action == "stash" ? "stashed for the run" : "folded into the commit")
    }

    func run(_ id: String, via: Via, facts f: SyncFacts, dirt: String?) async {
        guard let b = branch(id) else { return }
        ship.setStep(id, .dirt, .ok, dirt)
        let has = { (s: StepID) in ship.motionOf(id)?.steps.contains { $0.id == s } == true }

        if has(.reseat) {
            ship.setStep(id, .reseat, .run)
            let r = await step("review.reseat", id, via)
            if !r.ok {
                ship.setStep(id, .reseat, .fail, reseatWhy(r.body))
                return await finish(id, via: via, .stopped)
            }
            ship.setStep(id, .reseat, .ok, "back on \(b.parent)'s tip")
        }

        if has(.rebase) && Syncing.rebases(f) {
            ship.setStep(id, .rebase, .run)
            let r = await step("branch.sync.rebase", id, via)
            switch Syncing.rebaseOf(r.ok, r.body) {
            case .restack(let project):
                let q = await step("branch.sync.restack", id, via, ["project": .string(project)])
                if !q.ok {
                    ship.setStep(id, .rebase, .fail, q.body["err"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "the restack was refused")
                    return await finish(id, via: via, .stopped)
                }
                let queued = Syncing.truthy(q.body["queued"])
                let behind = q.body["behind"].flatMap { Syncing.truthy($0) ? ($0.string ?? $0.number.map { String(Int($0)) }) : nil } ?? "the running restack"
                ship.setStep(id, .rebase, .ok, queued ? "queued behind \(behind) — sync again once it lands" : "restacking \(project) in the background — sync again once it lands")
                return await finish(id, via: via, .restacking)
            case .contract:
                ship.setStep(id, .rebase, .fail, "already merged into origin/main — the restack walk drops it")
                return await finish(id, via: via, .stopped)
            case .conflict:
                ship.setStep(id, .rebase, .fail, "conflict — Claude is rebasing it in the branch's worktree (it never pushes); sync again once it lands")
                return await finish(id, via: via, .conflict)
            case .rebased(let note):
                ship.setStep(id, .rebase, .ok, note)
            case .refused(let note):
                ship.setStep(id, .rebase, .skip, note)
            }
        }

        ship.setStep(id, .prep, .run)
        let p = await step("branch.sync.prep", id, via)
        let shape = Syncing.prepOf(p.ok, p.body)
        switch shape {
        case .claude(let note):
            ship.setStep(id, .prep, .fail, note)
            let c = await step("branch.sync.reconcile", id, via)
            if !c.ok { ship.setStep(id, .prep, .fail, "\(note)\nClaude didn't start — \(c.body["err"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "refused")") }
            return await finish(id, via: via, .claude)
        case .fail(let note):
            ship.setStep(id, .prep, .fail, note)
            return await finish(id, via: via, .stopped)
        case .ok, .rest:
            ship.setStep(id, .prep, .ok, shape.note)
        }
        if Syncing.sealed(p.body) && ShipSeam.branchID(app) == id { app.runner.dispatch("review.words", via: via, target: id) }
        if case .rest = shape {
            ship.setStep(id, .gates, .skip)
            ship.setStep(id, .tests, .skip)
            return await finish(id, via: via, .done)
        }

        // the gates run detached on the shaped tip; the ship strip follows them from there
        if branch(id)?.gates == .running { ship.setStep(id, .gates, .ok, "already running") }
        else if app.registry.command("branch.gates.run") != nil {
            app.runner.dispatch("branch.gates.run", via: via, target: id)
            ship.setStep(id, .gates, .ok, "started — \(app.registry.keyOf("review.push")) pushes once they're green")
        } else {
            ship.setStep(id, .gates, .skip, "no gates command installed (area A's branch.gates.run)")
        }
        ship.setStep(id, .tests, .run)
        let t = await step("branch.sync.tests", id, via)
        let tests = Syncing.testsOf(t.body)
        ship.setStep(id, .tests, tests.state, tests.note)
        await finish(id, via: via, .done)
    }

    /// Bring a sync stash back once the motion is over, whatever stopped it.
    func finish(_ id: String, via: Via, _ phase: SyncPhase) async {
        ship.patch(id) { [tip = branch(id)?.tip] m in m.phase = phase; m.tip = tip ?? m.tip }
        let failed = ship.motionOf(id)?.steps.first { $0.state == .fail }
        let name = shipLeaf(branch(id)?.name ?? id)
        switch phase {
        case .done: app.runner.say("synced \(name)")
        case .stopped: app.runner.say("\(name): \(failed?.label ?? "sync") — \((failed?.note ?? "stopped").components(separatedBy: "\n")[0])")
        default: app.runner.say("\(name): \(phase.word ?? "")")
        }
        guard ship.motionOf(id)?.stashed == true else { return }
        let r = await step("branch.sync.dirt", id, via, ["action": "pop"])
        ship.patch(id) { $0.stashed = false }
        ship.setStep(id, .dirt, r.ok ? .ok : .fail, r.ok ? "stash popped — your uncommitted changes are back" : "the stash didn't pop (still stashed):\n\(r.body["err"]?.string ?? "")")
    }

    func reseatWhy(_ body: JSONObject) -> String {
        let c = body["conflicts"]?.array ?? []
        if !c.isEmpty { return "hit a conflict reseating \(c.compactMap { $0["branch"]?.string }.map(shipLeaf).joined(separator: ", ")) — the forest's restack resolves it" }
        return body["err"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "the reseat was refused"
    }
}
