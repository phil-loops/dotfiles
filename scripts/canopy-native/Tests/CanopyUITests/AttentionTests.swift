import CanopyCore
import CanopyTestSupport
import Foundation
import Testing
@testable import CanopyUI

/// The few things sessions pin for Phil on a forest (`stack-attention`): listed above the branches, ↵ goes there,
/// X signs one off as Phil, ]d / [d step through the branches that need his eyes.
@MainActor
@Suite struct AttentionTests {
    static func store(_ items: [[String: Any]]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "items": items])
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("stack-attention.json"))
        return dir
    }

    static func item(_ id: String, branch: String, forest: String = "tree", file: String? = "m/x.ts", line: Int? = 12, tip: String = "t",
                     done: Bool = false) -> [String: Any] {
        ["id": id, "forest": forest, "branch": branch, "file": file as Any? ?? NSNull(), "line": line as Any? ?? NSNull(), "ask": "decide",
         "text": "\(id) wants you", "tip": tip, "by": "7eba910c", "at": "2026-11-25T15:00:00-0800",
         "done": done ? ["at": "2026-11-25T15:01:00-0800", "by": "phil"] : NSNull()]
    }

    /// A forest page whose repo's store holds these items; sign-offs land in `ran`.
    static func page(_ items: [[String: Any]], ran: @escaping @Sendable ([String], [String: String]) -> Void = { _, _ in }) async throws -> AppModel {
        let a = world(.forest(repo: "r", project: "tree"))
        let dir = try store(items)
        var io = AttentionIO(gitDir: dir, repo: "r", repoPath: dir)
        io.run = { args, env in ran(args, env); return .success(()) }
        Attention.of(a).io = io
        await Attention.of(a).read()
        return a
    }

    @Test func aForestsOpenItemsAreAPaneAboveItsBranches() async throws {
        let a = try await Self.page([Self.item("a-1", branch: "c"), Self.item("a-2", branch: "a", done: true),
                                     Self.item("a-3", branch: "s", forest: "solo"), Self.item("a-4", branch: "d")])
        #expect(a.panes.map(\.id) == ["attention", "main"])
        #expect(a.panes.first?.rows == [RowKey.attention("a-1"), RowKey.attention("a-4")], "open ones on this forest, in the order written")
        #expect(a.provider?.primary(for: RowKey.attention("a-1"), a)?.id == "attention.open")
        #expect(Attention.of(a).on(repo: "elsewhere", forest: "tree").isEmpty, "another repo's forest has no items canopy can read")
    }

    @Test func anItemSaysWhereItPointsAndLandsThere() throws {
        let i = AttentionItem(id: "a-1", forest: "f", branch: "feat/word-notices", file: "models/x y.ts", line: 118, ask: "look", text: "t", tip: "t1")
        #expect(i.place == "word-notices · x y.ts:118")
        #expect(i.address(repo: "loops") == "/v2/b/loops/feat/word-notices?file=models/x%20y.ts&line=118")
        #expect(AttentionItem(id: "a", forest: "f", branch: "b", file: nil, line: nil, ask: "act", text: "t", tip: "t1").address(repo: "r") == "/v2/b/r/b")
        #expect(i.stale(tip: "t2") && !i.stale(tip: "t1"), "the branch moved since it was written")
    }

    @Test func xOnAnItemSignsItOffAsPhilAndNotTheForest() async throws {
        nonisolated(unsafe) var ran: [([String], [String: String])] = []
        let a = try await Self.page([Self.item("a-1", branch: "c")]) { ran.append(($0, $1)) }
        a.focus(pane: "attention")
        a.setCursor(RowKey.attention("a-1"))
        a.keys.handle("X")
        #expect(a.runner.fired?.id == "attention.done", "the item's X, never the forest's archive")
        #expect(await until("the sign-off ran") { !ran.isEmpty })
        #expect(ran.first?.0 == ["done", "a-1", "--by", "phil"])
        #expect(a.store.view(Project.self, "r:tree")?.state == .focus)
    }

    @Test func aSignOffRunsWithoutTheMarksOfTheSessionThatLaunchedCanopy() {
        let env = AttentionIO.asPhil(["PATH": "/bin", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDECODE": "1", "CODEX_HOME": "/c", "TMUX_PANE": "%3"])
        #expect(env == ["PATH": "/bin", "TMUX_PANE": "%3"])
    }

    @Test func bracketDStepsThroughTheBranchesThatNeedYourEyes() async throws {
        let a = try await Self.page([Self.item("a-1", branch: "d"), Self.item("a-2", branch: "b")])
        #expect(Attention.eyesRows(a) == [RowKey.branch("r:b"), RowKey.branch("r:d")], "in merge order, not the order written")
        a.focus(pane: "main")
        a.setCursor(RowKey.branch("r:a"))
        a.keys.handle("]"); a.keys.handle("d")
        #expect(a.runner.fired?.id == "attention.next" && a.selected == RowKey.branch("r:b"))
        a.keys.handle("]"); a.keys.handle("d")
        #expect(a.selected == RowKey.branch("r:d"))
        a.keys.handle("]"); a.keys.handle("d")
        #expect(a.selected == RowKey.branch("r:d") && a.runner.note == "no branch below needs your eyes")
        a.keys.handle("["); a.keys.handle("d")
        #expect(a.selected == RowKey.branch("r:b"))
    }

    @Test func aCardShowsTheFileAroundTheLineAndSaysWhereTheCodeWent() throws {
        #expect(ReviewSinceView.window(count: 0, line: 5) == [], "an empty file shows nothing, never a backwards range")
        #expect(ReviewSinceView.window(count: 100, line: 1) == Array(1...40), "a note on line 1 is about the file: its start")
        #expect(ReviewSinceView.window(count: 100, line: 50) == Array(44...64))
        #expect(ReviewSinceView.window(count: 10, line: 99) == Array(1...10), "a line past the end shows the file's start")
        let item = AttentionItem(id: "a", forest: "f", branch: "owners", file: "m.ts", line: 3, ask: "decide", text: "t", tip: "t1")
        let note = ReviewNote(id: "n7", branch: "wording", file: "m.ts", line: 1, commit: "c1", text: "why fourteen?")
        #expect(ReviewSinceView.nowTitle(item, note: note) == "what it is now · moved from wording to owners")
        #expect(ReviewSinceView.nowTitle(item, note: ReviewNote(id: "n7", branch: "owners", file: nil, line: nil, commit: nil, text: "")) == "what it is now")
    }

    @Test func anItemsNoteIsReadFromTheReviewItNames() throws {
        let reviews = FileManager.default.temporaryDirectory.appendingPathComponent("reviews-\(UUID().uuidString)")
        let folder = reviews.appendingPathComponent("2026-11-25T133320-f")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"[{"id": "n7", "branch": "w", "file": "m.ts", "line": 1, "commit": "c1", "text": "the words"}, {"id": "n1", "branch": null, "file": null, "line": null, "commit": null, "text": "hi"}]"#.utf8)
            .write(to: folder.appendingPathComponent("notes.json"))
        #expect(ReviewNote.read(.init(review: "2026-11-25T133320-f", id: "n7"), reviews: reviews)?.text == "the words", "by folder name")
        #expect(ReviewNote.read(.init(review: folder.path, id: "n7"), reviews: reviews)?.commit == "c1", "or by its path")
        #expect(ReviewNote.read(.init(review: folder.path, id: "n9"), reviews: reviews) == nil)
    }

    @Test func commaAOpensAndFoldsTheCardsOnTheBranchPage() async throws {
        let a = try await Self.page([Self.item("a-1", branch: "c"), Self.item("a-2", branch: "d")])
        #expect(a.registry.command("attention.cards")?.keys == [", A"])
        a.go(.review(repo: "r", branch: "c"))
        try a.registry.command("attention.cards")?.local?(nil, nil)
        #expect(Attention.of(a).opened == ["a-1"], "only this branch's items")
        try a.registry.command("attention.cards")?.local?(nil, nil)
        #expect(Attention.of(a).opened.isEmpty)
    }
}
