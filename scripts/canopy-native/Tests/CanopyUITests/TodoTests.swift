import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// tracker.test.ts, plus the tracker page and its commands over the installed app. Writes are
/// checked as the `Write` a command builds (path, body, overlay, inverse); the one dispatch that
/// posts goes to port 1, where nothing listens — never the live server.
@MainActor @Suite struct TodoTests {
    func t(_ id: String, kind: String = "build", state: String = "open", rank: Int? = nil, created: String? = nil, waiting: String? = nil) -> TodoItem {
        TodoItem(id: id, kind: kind, state: TodoState(rawValue: state), waiting: waiting, rank: rank, created: created)
    }

    func app() throws -> AppModel {
        var c = AppConfig()
        c.route = .todo
        let a = AppModel(config: c, port: 1, telemetry: false)
        a.store.hydrate(try Snapshot.decode(Data(MachineFixtures.todoState.utf8)))
        return a
    }

    // ── tracker.test.ts ──

    @Test func needsYouFirstThenDoingTheRankedQueueAndWaiting() {
        let items = [
            t("later", created: "2026-10-02"),
            t("first", rank: 1),
            t("call", kind: "decide"),
            t("busy", state: "doing"),
            t("hankles", state: "waiting", waiting: "next review"),
            t("old", state: "done"),
            t("earlier", created: "2026-10-01"),
        ]
        #expect(Tracker.queue(items).map { "\($0.section.rawValue): \($0.items.map(\.id).joined(separator: " "))" }
            == ["decide: call", "doing: busy", "next: first earlier later", "waiting: hankles"])
    }

    @Test func movingKeepsTheSectionsRanksAndNumbersTheUnrankedAfterAllRanks() {
        let items = [t("a", rank: 2), t("b", rank: 5), t("c", created: "1"), t("call", kind: "decide", rank: 9)]
        #expect(Tracker.rerank(items, id: "c", to: 0) == ["c": 2, "a": 5, "b": 10])
        #expect(Tracker.rerank(items, id: "a", to: 1) == ["b": 2, "a": 5])
        #expect(Tracker.rerank(items, id: "a", to: 0) == nil)
    }

    // ── the page over a real /state todo table ──

    @Test func aBrokenFileStillShowsUnderCantRead() throws {
        let a = try app()
        let q = Tracker.queue(a.store.trackerItems())
        #expect(q.first?.section == .broken)
        #expect(q.first?.items.first?.problems == ["line 3: expected = after key"])
        #expect(q.map(\.section) == [.broken, .decide, .doing, .next, .waiting])
        // done and dropped are gone; the ranked queue leads, the unranked trail it
        let next = q.first { $0.section == .next }!.items.map(\.id)
        #expect(next == ["honest-command-timing", "fix-o-key-line-by-line", "forests-cursor-latency", "gates-survive-rebase",
                         "restack-leaves-branch-b-stack-base-behind-so-the-branch-page"])
        #expect(a.rows.count == 9)
        #expect(a.rows.first == RowKey.todo("bad-file"))
    }

    @Test func scopesAndTargetsFollowTheCursor() throws {
        let a = try app()
        a.keys.handle("j"); a.keys.handle("j")
        #expect(a.selected == RowKey.todo("show-where-a-branch-is-in-the-dev-loop-and-the-one-next-step"))
        #expect(a.liveScopes() == [.item, .todo, .global])
        #expect(a.target(for: .item) == "show-where-a-branch-is-in-the-dev-loop-and-the-one-next-step")
    }

    @Test func retUnfoldsTheNotes() throws {
        let a = try app()
        let ui = a.state { TrackerUI() }
        a.setCursor(RowKey.todo("honest-command-timing"))
        a.keys.handle("ret")
        #expect(ui.open == ["honest-command-timing"])
        a.keys.handle("ret")
        #expect(ui.open.isEmpty)
    }

    @Test func availabilityFollowsTheState() throws {
        let a = try app()
        let can = { (id: String, cmd: String) in a.registry.command(cmd)!.available!(id) }
        #expect(can("honest-command-timing", "todo.start"))
        #expect(!can("show-where-a-branch-is-in-the-dev-loop-and-the-one-next-step", "todo.start"), "already doing")
        #expect(!can("bad-file", "todo.done") && !can("bad-file", "todo.drop") && !can("bad-file", "todo.up"))
        #expect(!can("address-thread", "todo.done"), "done stays done")
        #expect(can("dashboard-read-after-review", "todo.drop"))
    }

    @Test func startDoneAndDropBuildTheirWrites() throws {
        let a = try app()
        let start = try a.registry.command("todo.start")!.write!("honest-command-timing", nil)!
        #expect(start.path == "/todo-item")
        #expect(start.body == ["id": "honest-command-timing", "set": ["state": "doing"]])
        #expect(start.ops.first?.fields == ["state": "doing"])
        #expect(!start.settled())

        let done = try a.registry.command("todo.done")!.write!("honest-command-timing", nil)!
        #expect(done.ops.first?.fields == ["state": "done", "rank": .null], "closing drops the rank in the overlay")
        #expect(done.said?.hasPrefix("done: ") == true && done.said?.hasSuffix(" — u puts it back") == true)
        let inv = done.inverse?([:])
        #expect(inv?.id == "todo.state" && inv?.target == "honest-command-timing")
        let back = inv?.arg as? TodoStateArg
        #expect(back?.state == "open" && back?.rank == 2)

        let put = try a.registry.command("todo.state")!.write!("honest-command-timing", back)!
        #expect(put.body == ["id": "honest-command-timing", "set": ["state": "open", "rank": 2]])
        #expect(try a.registry.command("todo.start")!.write!("show-where-a-branch-is-in-the-dev-loop-and-the-one-next-step", nil) == nil,
                "a no-op move sends nothing")
    }

    @Test func doneShowsAtOnceAndSettlesOnThePatch() throws {
        let a = try app()
        a.setCursor(RowKey.todo("honest-command-timing"))
        a.keys.handle("m")
        #expect(a.store.trackerItem("honest-command-timing")?.state == "done", "the overlay shows it before the server answers")
        #expect(!a.rows.contains(RowKey.todo("honest-command-timing")))
        #expect(a.selected == RowKey.todo("fix-o-key-line-by-line"), "the cursor falls to the next row")
        var obj = a.store.raw["todo"]!["honest-command-timing"]!.object!
        obj["state"] = "done"
        obj["rank"] = nil
        a.store.applyPatch(try Patch.make(domain: "todo", version: 2, upserts: ["todo": ["honest-command-timing": .object(obj)]]))
        #expect(a.store.trackerServer("honest-command-timing", "state")?.string == "done")
    }

    @Test func ctrlJMovesDownTheQueueKeepingItsRanks() throws {
        let a = try app()
        a.setCursor(RowKey.todo("honest-command-timing"))
        let w = try a.registry.command("todo.down")!.write!("honest-command-timing", nil)!
        #expect(w.body == ["ranks": ["fix-o-key-line-by-line": 2, "honest-command-timing": 3]])
        #expect(Set(w.ops.map(\.id)) == ["fix-o-key-line-by-line", "honest-command-timing"])
        let inv = w.inverse?([:])
        #expect(inv?.id == "todo.ranks")
        let before = inv?.arg as? [String: Int?]
        #expect(before?["honest-command-timing"] == .some(2) && before?["fix-o-key-line-by-line"] == .some(3))
        #expect(a.selected == RowKey.todo("honest-command-timing"), "the cursor stays on the moved item")
        // the top of the section can't go up
        #expect(try a.registry.command("todo.up")!.write!("honest-command-timing", nil) == nil)
        // an unranked item moved above a ranked one gets a number after every rank in use
        let up = try a.registry.command("todo.up")!.write!("restack-leaves-branch-b-stack-base-behind-so-the-branch-page", nil)!
        #expect(up.body == ["ranks": ["restack-leaves-branch-b-stack-base-behind-so-the-branch-page": 9, "gates-survive-rebase": 10]])
    }

    @Test func overlayMovesTheRowAtOnce() throws {
        let a = try app()
        a.setCursor(RowKey.todo("honest-command-timing"))
        a.keys.handle("C-j")
        let next = Tracker.queue(a.store.trackerItems()).first { $0.section == .next }!.items.map(\.id)
        #expect(next.prefix(2) == ["fix-o-key-line-by-line", "honest-command-timing"])
    }

    @Test func keyboardRule() throws {
        let a = try app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("todo.") }.isEmpty, "\(KeyboardRule.violations(a) { $0.hasPrefix("todo.") })")
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }
}
