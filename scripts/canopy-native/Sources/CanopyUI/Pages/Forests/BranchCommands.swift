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

    /// The id the description field's ModalTextField types into.
    static let describeField = "forest.describe"

    /// What `p` does: arm, then send — or, when only the gates stand in the way, run them. A branch
    /// diverged from origin can't push; inside the force scope `p` arms a force-with-lease instead.
    static func pushRoute(_ id: String?, _ app: AppModel) -> String? {
        let m = app.forestModel
        guard let v = m.branchView(id) else { return nil }
        if v.b.diverged {
            guard let s = forceScope(id, app), v.b.pending == nil else { return nil }
            if s.eligible { return m.armed == id ? "branch.force.confirm" : "branch.force.arm" }
            if !s.guards.allSatisfy({ $0.ok || $0.k == "gates" }) { return nil }
            return v.b.gates == .running ? "branch.gates.wait" : "branch.gates.run"
        }
        if ShipRules.canPush(v.b, v.pr) { return m.armed == id ? "branch.push.confirm" : "branch.push.arm" }
        if !ShipRules.pushableButGates(v.b, v.pr) { return nil }
        return v.b.gates == .running ? "branch.gates.wait" : "branch.gates.run"
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

        func gatesWrite(_ v: BranchView, skip: [String]) -> Write {
            let id = v.b.id, was = v.b.gates
            var body: JSONObject = ["branch": .string(v.b.name), "detach": true]
            if !skip.isEmpty { body["skip"] = .array(skip.map(JSONValue.string)) }
            return Write(
                ops: [Op(type: .branch, id: id, fields: ["gates": "running"])],
                path: t.atRepo(v.b.repo, "/gates"), body: .object(body),
                settled: { s.table(Branch.self)[id]?.gates != was },
                said: skip.isEmpty ? "running the gates — p pushes once they're green" : "skipping \(skip.joined(separator: ", ")) for this code — the rest re-run",
                failed: "the gates didn't start")
        }
        r.register(Command(
            id: "branch.gates.run", title: "Run the push gates", scope: .branch, label: "gates", quiet: true,
            available: { id in m.branchView(id).map { $0.b.gates != .running } ?? false },
            write: { id, _ in m.branchView(id).map { gatesWrite($0, skip: []) } }))
        r.register(Command(
            id: "branch.gates.show", title: "Show a gate's output in the gates strip (again to go back to the running one)",
            scope: .branch, needsArg: true, quiet: true,
            local: { target, _ in m.gateShown = m.gateShown == target ? nil : target }))
        r.register(Command(
            id: "branch.gates.skip", title: "Skip a red gate for this code and re-run the rest", scope: .branch, needsArg: true, quiet: true,
            write: { target, _ in
                let parts = target.split(separator: " ", maxSplits: 1).map(String.init)
                let skip = (parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
                guard let v = m.branchView(parts.first), !skip.isEmpty else { return nil }
                return gatesWrite(v, skip: skip)
            }))
        r.register(Command(
            id: "branch.gates.wait", title: "The gates are running", scope: .branch, quiet: true,
            local: { _, _ in throw Refusal("the gates are running — p pushes once they're green") }))
        r.register(Command(
            id: "branch.push.arm", title: "Ready a push (the next press sends it)", scope: .branch, quiet: true,
            available: { id in m.branchView(id).map { ShipRules.canPush($0.b, $0.pr) } ?? false },
            local: { id, _ in m.armed = id }))
        r.register(Command(
            id: "branch.push.confirm", title: "Send the readied push", scope: .branch, budget: .gitWrite, v1: ["push-origin"], quiet: true,
            available: { id in id != nil && m.armed == id },
            write: { id, _ in
                m.armed = nil
                guard let v = m.branchView(id) else { return nil }
                return Write(
                    ops: [Op(type: .branch, id: id, fields: ["pending": "pushing"])],
                    path: t.atRepo(v.b.repo, "/push-origin"), body: ["branch": .string(v.b.name), "stay": true],
                    settled: { s.table(Branch.self)[id]?.pushed == .synced },
                    said: v.pr.map { "pushed \(v.b.ahead) follow-up\(v.b.ahead == 1 ? "" : "s") onto #\($0.number)" },
                    failed: "\(leaf(v.b.name)) didn't push")
            }))

        // ── the one sanctioned force: replace origin's copy while nobody else has read it ──

        r.register(Command(
            id: "branch.force.arm", title: "Ready a force-with-lease over origin (the next press sends it)", scope: .branch, quiet: true,
            available: { id in m.branchView(id)?.b.diverged == true && forceScope(id, app)?.eligible == true },
            local: { id, _ in m.armed = id }))
        r.register(Command(
            id: "branch.force.confirm", title: "Send the readied force-with-lease", scope: .branch, budget: .gitWrite, v1: ["force-origin"], quiet: true,
            available: { id in id != nil && m.armed == id && forceScope(id, app)?.eligible == true },
            write: { id, _ in
                let sc = forceScope(id, app)
                m.armed = nil
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
            id: "branch.open", title: "Open the branch", scope: .branch, verb: .into, label: "open",
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
                guard let id, let b = s.view(Branch.self, id) else { return }
                m.describing = id
                m.draft = b.description
                app.beginInsert(describeField)
            }))
        r.register(Command(
            id: "branch.describe.save", title: "Save the description you're typing", scope: .forest, verb: .send, modes: [.insert],
            label: "save", quiet: true,
            available: { _ in m.describing != nil && app.insertField == describeField },
            local: { _, _ in
                guard let id = m.describing else { return }
                let text = m.draft
                m.describing = nil
                app.keys.setMode(.normal)
                app.runner.dispatch("branch.describe", via: .key, target: id, arg: text)
            }))

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

        // esc backs out of an armed push, a launch, a description being typed (commands/app.ts overlay.close)
        app.addCloser(isOpen: { m.armed != nil || m.launching != nil || m.describing != nil }, close: {
            if m.describing != nil { m.describing = nil }
            else if m.armed != nil { m.armed = nil }
            else { m.launching = nil }
        })
    }
}
