import Foundation

// The projection scenarios a tutor-sim block names (simScenarios.ts), each tied to its standard
// and concepts in the learner's graph (system ses-projection). Data only; Sim plays them.

private func insert(_ id: String, shard: Int? = nil) -> Step { Step(.insert(id: id, shard: shard)) }
private func tick(_ n: Int? = nil) -> Step { Step(.tick(n: n)) }
private func read(_ w: String, bookmark: String? = nil, group: Int? = nil, lag: Int? = nil) -> Step { Step(.read(worker: w, bookmark: bookmark, group: group, lag: lag)) }
private func apply(_ w: String) -> Step { Step(.apply(worker: w)) }
private func save(_ w: String) -> Step { Step(.save(worker: w)) }
private func page(_ w: String, bookmark: String? = nil, group: Int? = nil, lag: Int? = nil) -> [Step] {
    [read(w, bookmark: bookmark, group: group, lag: lag), apply(w), save(w)]
}

enum SimScenarios {
    static let all: [Scenario] = [
        Scenario(
            id: "crash-before-bookmark",
            title: "A crash between the counts and the bookmark",
            standard: "sesp-effects-once",
            concepts: ["cursor-redelivery", "counts-and-bookmark-atomic"],
            kernel: .atomicCommit,
            situation: "w1 read e1–e3 and added their counts, then crashed before saving its bookmark.",
            question: "w1 restarts and reads again. How many times is each event counted?",
            bookmarks: ["global"],
            steps: [insert("e1"), insert("e2"), insert("e3"), tick(3), read("w1", bookmark: "global"), apply("w1"), Step(.crash(worker: "w1"))]
                + page("w1", bookmark: "global"),
            revealAt: 7),
        Scenario(
            id: "slow-insert",
            title: "An insert stamped early, committed late",
            standard: "sesp-ordering",
            concepts: ["commit-order-not-stamp-order", "safety-lag"],
            kernel: .safetyLag,
            situation: "e2 was stamped t1 but its insert is slow; e3 (t2) already committed. w1 read a page at t3 and saved its bookmark. Now e2 commits.",
            question: "Does w1's next page count e2?",
            bookmarks: ["global"],
            steps: [insert("e1"), tick(), Step(.begin(id: "e2", shard: nil)), tick(), insert("e3"), tick()]
                + page("w1", bookmark: "global")
                + [Step(.commit(id: "e2")), tick(5)]
                + page("w1", bookmark: "global"),
            revealAt: 10),
        Scenario(
            id: "two-projectors",
            title: "Two projectors on one bookmark",
            standard: "sesp-coordination",
            concepts: ["pg-is-the-correctness-layer"],
            kernel: .lock,
            situation: "w1 has a page open on the global bookmark: e1 and e2.",
            question: "w2 starts a page on the same bookmark before w1 commits. What happens to the counts?",
            bookmarks: ["global"],
            steps: [insert("e1"), insert("e2"), tick(3), read("w1", bookmark: "global"), read("w2", bookmark: "global"),
                    apply("w1"), save("w1"), apply("w2"), save("w2")],
            revealAt: 4),
        Scenario(
            id: "lease-lost",
            title: "A lease vanishes mid-page",
            standard: "sesp-coordination",
            concepts: ["lock-guards-holders-not-execution", "pg-is-the-correctness-layer", "projection-worker-lease"],
            kernel: .lock,
            situation: "w1 leased group 0 and opened a page (e1, e2). Valkey restarted and w1's lease key is gone; w2 just leased group 0.",
            question: "w2 starts a page while w1's is still open. Do the counts stay right?",
            bookmarks: ["global"],
            steps: [insert("e1"), insert("e2"), tick(3), Step(.lease(worker: "w1", group: 0)), read("w1", bookmark: "global"),
                    Step(.leaseLost(worker: "w1")), Step(.lease(worker: "w2", group: 0)), read("w2", bookmark: "global"),
                    apply("w1"), save("w1"), apply("w2"), save("w2")],
            revealAt: 7),
        Scenario(
            id: "regroup",
            title: "Changing the group count mid-run",
            standard: "sesp-parallel",
            concepts: ["projection-shards", "projection-groups"],
            kernel: .shardBookmarks,
            situation: "4 shards in 2 groups; both groups projected e1–e4. e5–e8 landed at t4, one per shard, and the group count went from 2 to 4.",
            question: "Four workers now each project one group. Are e5–e8 counted?",
            shards: 4,
            groupCount: 2,
            bookmarks: ["layout"],
            steps: [insert("e1", shard: 0), insert("e2", shard: 1), insert("e3", shard: 2), insert("e4", shard: 3), tick(3)]
                + page("w1", group: 0) + page("w2", group: 1)
                + [tick(), insert("e5", shard: 0), insert("e6", shard: 1), insert("e7", shard: 2), insert("e8", shard: 3),
                   Step(.regroup(groupCount: 4)), tick(5)]
                + page("w1", group: 0) + page("w2", group: 1) + page("w3", group: 2) + page("w4", group: 3),
            revealAt: 17),
        Scenario(
            id: "handoff-live-writer",
            title: "Activating shards while the old writer still runs",
            standard: "sesp-handoff",
            concepts: ["fence-the-predecessor"],
            kernel: .fence,
            situation: "The old global writer runs on its schedule. Activation ran once while the writer had a page open, and again after it committed.",
            question: "e3 and e4 arrive after activation. Who counts them, and how many times?",
            shards: 2,
            bookmarks: ["global"],
            steps: [insert("e1", shard: 0), insert("e2", shard: 1), tick(3)]
                + page("g", bookmark: "global")
                + [tick(), read("g", bookmark: "global"), Step(.activate), save("g"), Step(.activate),
                   insert("e3", shard: 0), insert("e4", shard: 1), tick(4)]
                + page("g", bookmark: "global") + page("w1", group: 0),
            revealAt: 11),
        Scenario(
            id: "handoff-cutoff",
            title: "A cutoff behind the old writer's bookmark",
            standard: "sesp-handoff",
            concepts: ["cutoff-after-predecessor"],
            kernel: .cutoffCheck,
            situation: "The old global writer ran with no lag, counted e1 and e2 (up to t1), and was stopped at t2. A cutoff taken now would be t-1.",
            question: "Activation runs at t2 and again at t6, then the shard worker reads. How many times are e1 and e2 counted?",
            bookmarks: ["global"],
            steps: [insert("e1"), tick(), insert("e2"), tick()]
                + page("g", bookmark: "global", lag: 0)
                + [Step(.stopGlobal), Step(.activate), tick(4), Step(.activate)]
                + page("w1", group: 0),
            revealAt: 8),
        Scenario(
            id: "handoff-gap",
            title: "Every safeguard on, one event between writers",
            standard: "sesp-handoff",
            concepts: ["fresh-start-gap", "single-cutoff-start"],
            kernel: nil,
            situation: "Every safeguard is on. The old writer drained through t0 and was stopped at t3, just as e2 landed. Activation at t7 starts the shards at cutoff t4.",
            question: "Does e2 get counted?",
            bookmarks: ["global"],
            steps: [insert("e1"), tick(3)]
                + page("g", bookmark: "global")
                + [insert("e2"), Step(.stopGlobal), tick(4), Step(.activate), insert("e3"), tick(3)]
                + page("w1", group: 0),
            revealAt: 9),
        Scenario(
            id: "dropped-reader",
            title: "A removed reader's bookmark",
            standard: "sesp-retention",
            concepts: ["frozen-bookmark-pins-retention", "retention-slowest-reader"],
            kernel: .retireBookmark,
            situation: "The audit reader stopped at e2 and was removed. The metrics reader has since counted through e4.",
            question: "Cleanup runs. Which events does it remove?",
            bookmarks: ["global", "audit"],
            steps: [insert("e1"), insert("e2"), tick(3)]
                + page("a", bookmark: "audit")
                + [Step(.dropReader(bookmark: "audit")), insert("e3"), insert("e4"), tick(3)]
                + page("m", bookmark: "global")
                + [Step(.cleanup)],
            revealAt: 13),
    ]

    struct Missing: Error, CustomStringConvertible {
        var id: String
        var description: String { "no sim scenario \(id)" }
    }

    static func scenario(_ id: String) throws -> Scenario {
        guard let found = all.first(where: { $0.id == id }) else { throw Missing(id: id) }
        return found
    }

    /// A scenario under the safeguards a block switched off, or nil when it names no scenario.
    static func sim(_ id: String, off: [String]) -> Sim? {
        (try? scenario(id)).map { Sim($0, SimConst.kernels(off: off)) }
    }
}
