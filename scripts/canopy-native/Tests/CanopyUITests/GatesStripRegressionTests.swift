import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// canopy-todo `keep-the-gates-strip-on-screen-from-p-until-the-run-ends`, fixed by pushing the run
/// (srv/state.py `gaterun`): the strip, the forest row and the door read one copy of a branch's
/// gates run, and no view polls for it. Before, the strip polled once after `p`, read the previous
/// run's finished journal, stopped polling and went blank; the door never flipped to "push".
@MainActor @Suite struct GatesStripRegressionTests {
    let id = ShipTests.branch

    func run(tree: String, running: Bool, events: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "branch": .string(id), "tree": .string(tree), "running": .bool(running),
                 "started": .number(Date().timeIntervalSince1970 - 12), "events": .array(events)])
    }

    let plan: JSONValue = .object(["event": "plan", "gates": .array(["env", "tests"])])

    func app(gates: String, gaterun: (String) -> JSONValue) throws -> (AppModel, Int) {
        let ship = ShipTests()
        return try ship.app { s in
            ship.entity(&s, "branch", ShipTests.branch) { $0["gates"] = .string(gates) }
            let tree = s["entities"]?.object?["branch"]?.object?[ShipTests.branch]?.object?["tree"]?.string ?? ""
            var ents = s["entities"]!.object!
            ents["gaterun"] = .object([ShipTests.branch: gaterun(tree)])
            s["entities"] = .object(ents)
        }
    }

    @Test func aFinishedRunForAnOlderTreeIsNotThisBranchsProgress() throws {
        // p over a new commit: the store still holds the last run, for the old tree, finished
        let (a, _) = try app(gates: "running") { _ in
            run(tree: "an-older-tree", running: false, events: [plan, .object(["event": "result", "ok": true])])
        }
        #expect(ShipState.of(a).progressOf(id) == nil, "another tree's run is history, not this branch's progress")
        #expect(GatesRun.waiting(ShipState.of(a).progressOf(id), rows: [], inFlight: true, now: 0)?.text == "gates starting",
                "so the strip says the run is starting instead of going blank")
    }

    @Test func aPreviousTreesGreenChecksAreHistoryBesideTheNewRunsSetup() throws {
        // two commits landed: the new tree's run waits for a slot while the read still holds the
        // old tree's six green ticks — they must not read as this code's checks (2026-11-18)
        let six = ["env", "fresh", "typecheck", "format", "lint", "tests"]
        let old = GateProgress(running: false, events: [GateEvent(event: "plan", planned: six)]
            + six.map { GateEvent(event: "done", gate: $0, ok: true) } + [GateEvent(event: "result", ok: true)], tree: "old-tree")
        let queued = GateProgress(running: true, events: [GateEvent(event: "setup", step: "queue", position: 1, behind: "other")], tree: "new-tree")
        let (current, previous) = GatesRun.split(pushed: queued, read: old, tree: "new-tree")
        #expect(current == queued && previous == old)
        #expect(GatesRun.rows(current, now: 0).isEmpty, "no green tick is drawn as the branch's checks")
        #expect(GatesRun.waiting(current, rows: [], inFlight: true, now: 0)?.text == "waiting on other", "the new run's setup stays the status")
        #expect(GatesRun.previousRows(current: current, previous: previous, inFlight: true, now: 0).map(\.state) == Array(repeating: .green, count: 6))
        #expect(GatesRun.previousRows(current: current, previous: previous, inFlight: false, now: 0).isEmpty, "history shows only while the re-run readies")

        // the store alone holding the old tree's run: never current, kept as the previous commit's
        let (a, _) = try app(gates: "running") { _ in
            run(tree: "an-older-tree", running: false, events: [plan, .object(["event": "result", "ok": true])])
        }
        #expect(ShipState.of(a).progressOf(id) == nil)
        #expect(ShipState.of(a).previousOf(id)?.tree == "an-older-tree")
        #expect(GatesRun.split(pushed: nil, read: GateProgress(running: false, events: old.events), tree: "new-tree").current == nil,
                "a read that doesn't say its tree is never this code's checks")
    }

    @Test func theStripReadsThePushedRunWithoutPollingAndTheDoorFlipsOnTheVerdict() throws {
        let (a, port) = try app(gates: "running") { tree in
            run(tree: tree, running: true, events: [plan, .object(["event": "start", "gate": "env", "ts": .number(Date().timeIntervalSince1970 - 3)])])
        }
        let live = ShipState.of(a).progressOf(id)
        #expect(live?.running == true && live?.elapsed != nil)
        #expect(GatesRun.rows(live, now: Date().timeIntervalSince1970).first?.state == .running)
        let reads = ShipStub.lock.withLock { (ShipStub.seen["\(port)"] ?? []).filter { $0.path.hasSuffix("/gates-progress") }.count }
        #expect(reads == 0, "the run came pushed; nothing polled for it")

        // the verdict lands as one git-domain patch: the branch's gates and its run, together
        let tree = try #require(a.store.view(Branch.self, id)?.tree)
        var branch = try #require(a.store.rawView("branch", id))
        branch["gates"] = "green"
        #expect(a.store.applyPatch(try Patch.make(domain: Domain.git, version: (a.store.versions[Domain.git] ?? 0) + 1, upserts: [
            "branch": [id: .object(branch)],
            "gaterun": [id: run(tree: tree, running: false, events: [plan, .object(["event": "result", "ok": true])])],
        ])) == .ok)
        #expect(ShipState.of(a).progressOf(id)?.running == false)
        #expect(a.store.view(Branch.self, id)?.gates == .green, "the door reads green the moment the verdict is pushed")
    }
}
