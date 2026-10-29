import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// lesson.test.ts, ported.
@Suite struct TutorLessonTests {
    let turn = [
        "Here is the setup.",
        "```tutor-rung",
        #"{"concept": "cursor-redelivery", "level": "predict", "rung": "predict", "confidence": true}"#,
        "```",
        "```tutor-pin",
        #"{"path": "scripts/srv/chat.py", "ref": "origin/main", "lines": [428, 470]}"#,
        "```",
        "The tick dies after 8. What does the next tick read first?",
        "```tutor-options",
        #"["4–8 again", "9 onward"]"#,
        "```",
    ].joined(separator: "\n")

    @Test func aTurnSplitsIntoProseAndTheBlocksThePageDraws() {
        let segs = Lesson.segments(turn)
        #expect(segs.map(\.kind) == [.prose, .rung, .prose, .pin, .prose, .options])
        #expect(segs.first { $0.kind == .pin } == .pin(Pin(path: "scripts/srv/chat.py", ref: "origin/main", lines: [428, 470])))
        guard case .rung(_, _, _, let confidence, _, _)? = segs.first(where: { $0.kind == .rung }) else { Issue.record("no rung"); return }
        #expect(confidence)
    }

    @Test func aFenceStillStreamingInIsHeldBack() {
        let half = "Setup.\n```tutor-evidence\n[{\"concept\": \"x\", \"lev"
        #expect(Lesson.segments(half) == [.prose("Setup.\n")])
    }

    @Test func aFenceThatIsntJSONStaysProseCalibrationIsQuiet() {
        #expect(Lesson.segments("```tutor-pin\nnot json\n```")[0].kind == .prose)
        #expect(Lesson.segments("```tutor-calibration\n[\"slow down\"]\n```")[0].kind == .quiet)
    }

    @Test func aFoldedRungShowsTheQuestionItAskedTheCardShowsItsParagraph() {
        #expect(Lesson.askOf(turn) == "What does the next tick read first?")
        #expect(Lesson.questionOf("Intro.\n\nSo: what happens **next**?\n\n") == "So: what happens next?")
    }

    @Test func rungsPairEachTutorTurnWithTheAnswerAfterItLatestFindsTheNewestBlock() {
        let msgs: [Msg] = [.tutor(turn), .me("9 onward"), .tutor("Not quite.")]
        #expect(Lesson.rungsOf(msgs) == [.init(n: 1, tutorIdx: 0, answer: "9 onward"), .init(n: 2, tutorIdx: 2, answer: nil)])
        guard case .rung(let c, _, _, _, _, _)? = Lesson.latest(msgs, .rung) else { Issue.record("no rung"); return }
        #expect(c == "cursor-redelivery")
        #expect(Lesson.latest(msgs, .map) == nil)
    }

    @Test func serverSentFramesComeOffWholeAPartialOneWaits() {
        let (frames, rest) = Lesson.sseFrames("event: token\ndata: {\"t\":\"a\"}\n\n: ping\n\nevent: done\ndata: {}\n\nevent: tok")
        #expect(frames == [SSEFrame(event: "token", data: #"{"t":"a"}"#), SSEFrame(event: "done", data: "{}")])
        #expect(rest == "event: tok")
    }

    @Test func aSimBlockNamesTheScenarioAndTheSafeguardsOffItsPlayedResultRoundTrips() {
        let ask = "Look.\n```tutor-sim\n{\"scenario\":\"crash-before-bookmark\",\"kernels\":{\"atomicCommit\":false,\"lock\":true},\"stopAt\":\"before-reveal\"}\n```\nWhat happens?"
        #expect(Lesson.segments(ask)[1] == .sim(scenario: "crash-before-bookmark", off: ["atomicCommit"]))
        let div = [Divergence(event: "e1", kind: "double")]
        let answer = "twice each (confidence: sure)\n\n" + Lesson.simResultFence(scenario: "crash-before-bookmark", off: ["atomicCommit"], outcome: "red", divergence: div)
        #expect(Lesson.segments(answer)[1] == .simResult(scenario: "crash-before-bookmark", off: ["atomicCommit"], outcome: "red", divergence: div))
        #expect(Lesson.spoken(answer) == "twice each (confidence: sure)")
    }

    // ── beyond the web tests: the blocks the page reads ──

    @Test func theFenceIsWhatJSONStringifyWrites() {
        #expect(Lesson.simResultFence(scenario: "s/x", off: ["lock"], outcome: "red", divergence: [Divergence(event: "e1", kind: "double")])
            == "```tutor-sim-result\n{\"scenario\":\"s/x\",\"kernels\":{\"lock\":false},\"outcome\":\"red\",\"divergence\":[{\"event\":\"e1\",\"kind\":\"double\"}]}\n```")
    }

    @Test func evidenceMapRestateAndQuestionBlocks() {
        let text = """
        ```tutor-evidence
        [{"concept":"a","level":"explain"},{"note":"no concept"}]
        ```
        ```tutor-map
        {"topic":{"id":"t1"},"stages":[{"concepts":["a","b"]},{"concepts":["c"]}]}
        ```
        ```tutor-restate
        [{"concept":"a","text":"mine"},"bare"]
        ```
        ```tutor-question
        {"concept":"b","text":"why?"}
        ```
        ```tutor-rung
        {"level":"predict"}
        ```
        """
        let segs = Lesson.segments(text).filter { $0.kind != .prose }
        #expect(segs == [
            .evidence([EvidenceBlock(concept: "a", level: "explain", credit: "unaided", outcome: "hit", note: "", confidence: "", contrast: "", via: "")]),
            .map(title: "t1", count: 3),
            .restate(concept: "a", text: "mine"),
            .restate(concept: "", text: "bare"),
            .question(concept: "b", text: "why?"),
            .quiet, // a rung with no concept draws nothing, as the web app
        ])
    }

    @Test func pipsTitleAndAgo() {
        var m = Mastery()
        m.depth = 2; m.assisted = 3; m.level = "explain"; m.held = 1; m.held_level = "predict"; m.open_miss = "x"; m.miss_confidence = "high"; m.due = true; m.reason = "overdue"
        #expect(Lesson.pipsTitle(m) == "held at predict (two days) · shown once at explain · transfer with help · open miss (confident) · due: overdue")
        #expect(Lesson.ago(1_000_000, now: 1_000_000 + 29_000) == "just now")
        #expect(Lesson.ago(1_000_000, now: 1_000_000 + 30_000) == "1 min ago", "Math.round(0.5) is 1")
        #expect(Lesson.ago(0, now: 5 * 60_000) == "5 min ago")
        #expect(Lesson.ago(0, now: 3 * 3_600_000) == "3 h ago")
    }
}

/// sim.test.ts, ported.
@Suite struct TutorSimTests {
    func run(_ id: String, _ kernels: Kernels = [:]) -> SimResult { Sim(try! SimScenarios.scenario(id), kernels).runToEnd() }
    func kinds(_ d: [Divergence]) -> [String] { d.map { "\($0.event):\($0.kind)" }.sorted() }

    @Test func everyScenarioWithAKernelStaysGreenWithItAndGoesRedWithoutIt() {
        for s in SimScenarios.all where s.kernel != nil {
            #expect(run(s.id).outcome == "green", "\(s.id) with every kernel")
            #expect(run(s.id, [s.kernel!: false]).outcome == "red", "\(s.id) without \(s.kernel!)")
        }
    }

    @Test func aCrashBetweenCountsAndBookmarkDoubleCountsOnlyWhenTheyCommitApart() {
        #expect(kinds(run("crash-before-bookmark", [.atomicCommit: false]).divergence) == ["e1:double", "e2:double", "e3:double"])
        let r = run("crash-before-bookmark")
        #expect(r.actual == 3)
        #expect(r.truth == 3)
    }

    @Test func withoutTheLagASlowInsertIsSkippedForever() {
        #expect(kinds(run("slow-insert", [.safetyLag: false]).divergence) == ["e2:skipped"])
    }

    @Test func theAdvisoryLockTurnsTheSecondProjectorAway() {
        #expect(run("two-projectors").busy == 1)
        #expect(kinds(run("two-projectors", [.lock: false]).divergence) == ["e1:double", "e2:double"])
    }

    @Test func aLostLeaseCostsNothingWhileTheLockHolds() {
        let r = run("lease-lost")
        #expect(r.outcome == "green")
        #expect(r.busy == 1)
        #expect(kinds(run("lease-lost", [.lock: false]).divergence) == ["e1:double", "e2:double"])
    }

    @Test func regroupingWithGroupOwnedBookmarksSkipsWhatLandedBeforeTheirStart() {
        #expect(kinds(run("regroup", [.shardBookmarks: false]).divergence) == ["e5:skipped", "e6:skipped", "e7:skipped", "e8:skipped"])
        #expect(run("regroup").actual == 8)
    }

    @Test func anUnfencedOldWriterCountsAlongsideTheShards() throws {
        #expect(kinds(run("handoff-live-writer", [.fence: false]).divergence) == ["e3:double", "e4:double"])
        let sim = Sim(try SimScenarios.scenario("handoff-live-writer"))
        _ = sim.runToEnd()
        #expect(sim.state().log.joined(separator: "\n").contains("activation is busy: g holds global"))
    }

    @Test func aCutoffBehindTheOldWriterRecountsWhatItAlreadyCounted() {
        #expect(kinds(run("handoff-cutoff", [.cutoffCheck: false]).divergence) == ["e1:double", "e2:double"])
    }

    @Test func theHandoffSkipsTheEventBetweenWritersEvenWithEveryKernelOn() {
        #expect(kinds(run("handoff-gap").divergence) == ["e2:skipped"])
    }

    @Test func aRemovedReadersLeftoverBookmarkPinsRetention() throws {
        #expect(kinds(run("dropped-reader", [.retireBookmark: false]).divergence) == ["e2:pinned", "e3:pinned"])
        let sim = Sim(try SimScenarios.scenario("dropped-reader"))
        _ = sim.runToEnd()
        #expect(sim.state().events.filter(\.retained).map(\.id) == ["e4"])
    }

    @Test func toRevealFreezesTheSetupAndTheRestPlaysFromThere() throws {
        let sim = Sim(try SimScenarios.scenario("crash-before-bookmark"))
        let frozen = sim.toReveal()
        #expect(frozen.workers.map { "\($0.id):\($0.status)" } == ["w1:crashed"])
        #expect(frozen.log.count == 7)
        #expect(!sim.done)
        #expect(sim.runToEnd().outcome == "green")
    }

    @Test func aRunIsDeterministicAndItsStateIsACopy() throws {
        let a = Sim(try SimScenarios.scenario("regroup"))
        let b = Sim(try SimScenarios.scenario("regroup"))
        #expect(a.runToEnd() == b.runToEnd())
        var s = a.state()
        s.events[0].applied["metrics"] = 99
        #expect(a.state().events[0].applied["metrics"] == 1)
    }

    @Test func revealAtSitsInsideEveryScript() {
        for s in SimScenarios.all { #expect(s.revealAt > 0 && s.revealAt < s.steps.count, "\(s.id)") }
    }

    @Test func anUnknownScenarioIsNoSim() {
        #expect(SimScenarios.sim("nope", off: []) == nil)
        #expect(throws: SimScenarios.Missing.self) { try SimScenarios.scenario("nope") }
    }
}
