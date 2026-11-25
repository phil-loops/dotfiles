import Foundation
import Testing
@testable import Show

private let reveal: [String: Any] = ["frames": [["t": "Wed 02:00", "event": "SET NX fails for A, B and C", "state": ["lock": "A"]]],
                                     "result": "Nobody runs digest again until someone deletes the key."]

private func stepJSON(_ extra: [String: Any] = [:]) -> [String: Any] {
    var raw: [String: Any] = [
        "id": "s1", "title": "The digest job after a crash",
        "setup": "croon's job lock has **no expiry**.",
        "watch": ["lock", "digest"],
        "frames": [["t": "Tue 02:00", "event": "A takes the lock", "state": ["lock": "A", "digest": "running"]],
                   ["t": "Tue 02:01", "event": "A's node is killed", "state": ["digest": "dead"]]],
        "predict": "Who holds the lock on Wednesday at 02:00?",
        "reveal": reveal, "explain": "Why does nobody get it?",
    ]
    raw.merge(extra) { $1 }
    return raw
}

private func step(_ extra: [String: Any] = [:]) throws -> TutorStep {
    try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject: stepJSON(extra)))
}

private func answer(_ parts: [String: String]) -> TutorAnswer {
    TutorAnswer(parts: parts, confidence: "medium", at: "2026-11-24T00:00:00Z")
}

@Test func aSealedStepWalksPredictExplainConsolidate() throws {
    #expect(stepPhase(try step(), nil) == .predict)
    #expect(stepPhase(try step(), answer(["predict": "nobody"])) == .explain)
    #expect(stepPhase(try step(), answer(["predict": "nobody", "explain": "no expiry"])) == .awaitingConsolidate)
    let closed = try step(["consolidate": "A lock with no expiry outlives its holder."])
    #expect(stepPhase(closed, answer(["predict": "nobody", "explain": "no expiry"])) == .done)
}

@Test func aStepArrivesSealedAndLeavesTheVerdictToTheJudge() throws {
    #expect(stepProblems(try step(), nil).isEmpty)
    var bare = stepJSON()
    bare["reveal"] = nil
    bare["explain"] = nil
    let unsealed = try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject: bare))
    #expect(stepProblems(unsealed, nil).contains("a step arrives sealed: its reveal and its explain question come with it"))
    #expect(stepPhase(unsealed, answer(["predict": "x"])) == .awaitingReveal)
    #expect(stepProblems(try step(["verdict": "held"]), nil).contains("the verdict is Show's judge's to give, after the prediction"))
}

@Test func theShapeKeepsOneQuestionPerPhase() throws {
    #expect(stepProblems(try step(["predict": "Who holds it? And why?"]), nil).contains("predict asks more than one question"))
    #expect(stepProblems(try step(["explain": "Why? And what then?"]), nil).contains("explain asks more than one question"))
    #expect(stepProblems(try step(["frames": [["t": "0", "event": "e", "state": ["queue": 3]]]]), nil)
        .contains("frames set queue, which isn't in watch"))
    #expect(stepProblems(try step(["consolidate": "early"]), answer(["predict": "x"])).contains("the consolidation arrived before the explanation"))
}

@Test func stateFoldsEachFramesChangesInOrder() throws {
    let s = try step()
    #expect(stepState(s.frames, through: 0) == [:])
    #expect(stepState(s.frames, through: 1) == ["lock": "A", "digest": "running"])
    #expect(stepState(s.frames, through: 2) == ["lock": "A", "digest": "dead"])
    let numeric = try step(["watch": ["n", "ok"], "frames": [["t": "0", "event": "e", "state": ["n": 3, "ok": true]]],
                            "reveal": ["frames": [], "result": "r"]])
    #expect(stepState(numeric.frames, through: 1) == ["n": "3", "ok": "yes"])
}

@Test func theCurrentStepIsTheFirstNotDone() throws {
    let raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks",
                              "steps": [stepJSON(["consolidate": "c"]), stepJSON(["id": "s2"])]]
    let session = try JSONDecoder().decode(TutorSession.self, from: JSONSerialization.data(withJSONObject: raw))
    #expect(currentStep(session, ["s1": answer(["predict": "a", "explain": "b"])])?.id == "s2")
    #expect(currentStep(session, [:])?.id == "s1")
}

@Test func aReplyIsReadBySectionsWithArguments() {
    let sections = tutorSections("@consolidate\nThe key outlives\nits holder.\n\n@frame 02:00 | A takes it | lock=A\nemail me @alice\n@evidence\n{\"a\":1}")
    #expect(sections.map(\.name) == ["consolidate", "frame", "evidence"])
    #expect(sections[0].body == "The key outlives\nits holder.")
    #expect(sections[1].argument == "02:00 | A takes it | lock=A" && sections[1].body == "email me @alice")   // an unknown @name is prose
    #expect(tutorSections("no sections here").isEmpty)
}

@Test func aFrameLineCarriesTimeEventAndState() {
    let frame = frameLine("Tue 02:00 | A takes the lock | lock=A; digest = running")!
    #expect(frame["t"] as? String == "Tue 02:00" && frame["event"] as? String == "A takes the lock")
    #expect(frame["state"] as? [String: String] == ["lock": "A", "digest": "running"] && frame["keys"] as? [String] == ["lock", "digest"])
    #expect((frameLine("02:01 | A's node is killed")!["state"] as? [String: String])?.isEmpty == true)
    #expect(frameLine("02:01 | x | y | lock=B")!["event"] as? String == "x | y")
    #expect(frameLine("just words") == nil)
}

private let assignment: [String: Any] = ["form": "explain", "concept": "lock-ttl", "level": "predict", "name": "Lock TTL", "why": "missed"]
private let branches: [String: [String: Any]] = ["hit": ["form": "explain", "concept": "lock-ttl", "level": "explain"],
                                                 "miss": ["form": "card", "concept": "lock-ttl", "level": ""]]

private func sessionFile(assigned: [String: Any]? = nil, answer: [String: Any]? = nil) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString).json").path
    var raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "notes": [], "agent": ["session": "x"],
                              "steps": [stepJSON(["concept": "lock-ttl", "level": "predict", "form": "predict"])]]
    if let assigned { raw["assigned"] = assigned }
    try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: path))
    if let answer { try JSONSerialization.data(withJSONObject: ["s1": answer]).write(to: answersURL(path)) }
    return path
}

private func text(_ object: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }

private func rawFile(_ path: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
}

private func row(_ line: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:] }

private let flatStep = """
@step The digest job after a crash
@setup
croon's job lock has **no expiry**.
@frame Tue 02:00 | A takes the lock | lock=A; digest=running
@frame Tue 02:01 | A's node is killed | digest=dead
@predict
Who holds the lock on Wednesday at 02:00?
@reveal Wed 02:00 | SET NX fails for A, B and C | lock=A
@result
Nobody runs digest again until someone deletes the key.
@explain
Why does nobody get it?
"""

@Test func aFlatStepBecomesASealedStepWithItsWatchDerived() throws {
    let path = try sessionFile(assigned: assignment)
    let applied = try applyStagedReply(flatStep, path: path, stepID: nil, now: "t")
    #expect(applied.refused.isEmpty && applied.posted == ["s2"])
    let posted = try loadTutorSession(path).steps[1]
    #expect(posted.title == "The digest job after a crash" && posted.frames.count == 2 && posted.reveal?.frames.count == 1)
    #expect(posted.rows == ["lock", "digest"])
    #expect(posted.concept == "lock-ttl" && posted.form == "explain" && posted.conceptName == "Lock TTL")
    #expect(stepProblems(posted, nil).isEmpty)
    #expect(rawFile(path)["assigned"] == nil)
}

private let variation = """
@example Mon 02:00 | A takes the lock | lock=A; digest=running
@example Mon 02:30 | A finishes and deletes the key | lock=none; digest=done
@outcome
B ran on Tuesday as usual.
@change
This time A's node dies before it deletes the key.
"""

@Test func aContrastShowsTheRunItVariesAndTheOneChange() throws {
    let contrast: [String: Any] = ["form": "contrast", "concept": "lock-ttl", "level": "predict"]
    #expect(try applyStagedReply(flatStep, path: try sessionFile(assigned: contrast), stepID: nil, now: "t").refused
        == ["step s2: a contrast step shows the run it varies: its @example lines, its @outcome and the one @change"])
    let path = try sessionFile(assigned: contrast)
    let withRun = flatStep.replacingOccurrences(of: "@frame Tue 02:00", with: variation + "\n@frame Tue 02:00")
    #expect(try applyStagedReply(withRun, path: path, stepID: nil, now: "t").refused.isEmpty)
    let posted = try loadTutorSession(path).steps[1]
    #expect(posted.example?.frames.count == 2 && posted.example?.result == "B ran on Tuesday as usual.")
    #expect(posted.change == "This time A's node dies before it deletes the key.")
    #expect(posted.rows == ["lock", "digest"])
    #expect(stepState(posted.example!.frames, through: 2) == ["lock": "none", "digest": "done"])
}

@Test func aStepIsWrittenOnlyWhenShowAssignedOne() throws {
    #expect(try applyStagedReply(flatStep, path: try sessionFile(), stepID: nil, now: "t").refused
        == ["no step is owed now; Show asks for one when the session is due its next"])
    let unsealed = flatStep.components(separatedBy: "\n@reveal")[0]
    let refused = try applyStagedReply(unsealed, path: try sessionFile(assigned: assignment), stepID: nil, now: "t").refused
    #expect(refused == ["step s2: a step arrives sealed: its reveal and its explain question come with it"])
    #expect(try applyStagedReply("@setup\nloose", path: try sessionFile(assigned: assignment), stepID: nil, now: "t").refused == ["@setup came outside a @step"])
    #expect(try applyStagedReply("@step T\n@frame nonsense", path: try sessionFile(assigned: assignment), stepID: nil, now: "t").refused
        .first?.hasPrefix("a @frame line isn't") == true)
}

@Test func showWritesTheStepsEvidenceRowFromBothReadings() throws {
    let answered: [String: Any] = ["parts": ["predict": "nobody", "explain": "no expiry"], "confidence": "high", "at": "t", "verdict": "held"]
    let held = try applyStagedReply("@consolidate\nA lock with no expiry outlives its holder.\n@explanation held",
                                    path: try sessionFile(answer: answered), stepID: "s1", now: "t")
    #expect(held.refused.isEmpty && held.finished)
    let own = row(held.evidence[0])
    #expect(own["concept"] as? String == "lock-ttl" && own["level"] as? String == "predict" && own["outcome"] as? String == "hit" && own["confidence"] as? String == "high")

    let missed = try applyStagedReply("@consolidate\nidea\n@explanation revised\n@misconception\nthinks the key expires\n@contrast\nsame, with a TTL",
                                      path: try sessionFile(answer: answered), stepID: "s1", now: "t")
    #expect(row(missed.evidence[0])["outcome"] as? String == "miss" && row(missed.evidence[0])["contrast"] as? String == "same, with a TTL")

    let path = try sessionFile(answer: answered)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(try applyStagedReply("@consolidate\nidea", path: path, stepID: "s1", now: "t").refused
        == ["@explanation held or revised is needed: it decides the step's evidence row with the judge's reading"])
    #expect(try applyStagedReply("@consolidate\nidea\n@explanation revised", path: path, stepID: "s1", now: "t").refused
        == ["a miss needs @misconception (what they believe) and @contrast (the same situation with one thing changed)"])
    #expect(try applyStagedReply("@consolidate\nidea\n@explanation held\n@evidence\n{\"concept\": \"lock-ttl\", \"level\": \"predict\"}", path: path, stepID: "s1", now: "t")
        .refused.first?.hasPrefix("the step's own row") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)

    var unjudged = answered
    unjudged["verdict"] = nil
    let asked = try applyStagedReply("@consolidate\nidea\n@explanation held", path: try sessionFile(answer: unjudged), stepID: "s1", now: "t")
    #expect(asked.refused == ["there was no judge reading, so give @prediction held or revised too"])
    let given = try applyStagedReply("@consolidate\nidea\n@prediction revised\n@explanation held\n@misconception\nm\n@contrast\nc",
                                     path: try sessionFile(answer: unjudged), stepID: "s1", now: "t")
    #expect(row(given.evidence[0])["outcome"] as? String == "miss")
}

@Test func theStationsAndTheNextStepAreShows() throws {
    let path = try sessionFile(assigned: assignment)
    for owned in ["@stations\nx", "@take\na1"] {
        #expect(try applyStagedReply(owned, path: path, stepID: "s1", now: "t").refused.first?.hasSuffix("picks the next step from the learner's graph") == true)
    }
}

@Test func theOpeningMapIsWrittenAsLines() throws {
    let reply = """
    @title Locks
    @map locks | Job locks | croon PR #9273
    @stage Why a lock
    @concept one-runner | One runner per tick | N copies share one schedule.
    @concept dead-holder | A dead holder blocks forever | Without expiry nobody runs again. | needs one-runner | like lock-ttl, cursor-stall
    """
    let mapped = try applyStagedReply(reply, path: try sessionFile(), stepID: nil, now: "t")
    #expect(mapped.refused.isEmpty)
    let map = row(mapped.map ?? "")
    #expect((map["topic"] as? [String: Any])?["source"] as? String == "croon PR #9273")
    let concepts = ((map["stages"] as? [[String: Any]])?.first?["concepts"] as? [[String: Any]]) ?? []
    #expect(concepts.count == 2 && concepts[1]["builds_on"] as? [String] == ["one-runner"] && concepts[1]["analogs"] as? [String] == ["lock-ttl", "cursor-stall"])
    #expect(try applyStagedReply("@map x | X\n@stage empty", path: try sessionFile(), stepID: nil, now: "t").refused == ["a @map needs @stage sections, each with its @concept lines"])
    #expect(try applyStagedReply("@topic croon-job-locks", path: try sessionFile(), stepID: nil, now: "t").topic == "croon-job-locks")
}

@Test func recallAndTheCardTakeOneAnswer() throws {
    let recall = try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject:
        TutorPolicy.writtenStep(["form": "recall"], id: "s1", title: "Locks")))
    #expect(stepProblems(recall, nil).isEmpty)
    #expect(stepPhase(recall, nil) == .predict)
    #expect(stepPhase(recall, answer(["predict": "a lock is a key in redis"])) == .awaitingConsolidate)
    let card = try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject:
        TutorPolicy.writtenStep(["form": "card", "concept": "lock-ttl", "name": "Lock TTL"], id: "s9", title: "Locks")))
    #expect(card.concept == "lock-ttl" && stepPhase(card, answer(["predict": "it dies on its own"])) == .done)
}

@Test func recallEvidenceIsTheTutorsAndStampedAsRecall() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString).json").path
    let raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "notes": [], "agent": ["session": "x"],
                              "steps": [TutorPolicy.writtenStep(["form": "recall"], id: "s1", title: "Locks")]]
    try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: path))
    let applied = try applyStagedReply("@consolidate\nYou have the key.\n@evidence\n{\"concept\": \"lock-ttl\", \"level\": \"predict\"}", path: path, stepID: "s1", now: "t")
    #expect(applied.refused.isEmpty && applied.evidence == ["{\"concept\":\"lock-ttl\",\"level\":\"predict\",\"rung\":\"recall\"}"])
}

@Test func theJudgeReadingIsTheObjectItPromised() {
    let held = TutorJudge.reading("{\"verdict\": \"held\", \"why\": \"Right: the key never expires.\", \"draft\": null}")!
    #expect(held.verdict == "held" && held.why == "Right: the key never expires." && held.draft == nil)
    let revised = TutorJudge.reading("Sure! {\"verdict\": \"revised\", \"why\": \"B gets it.\", \"draft\": \"a2\"} ")!
    #expect(revised.verdict == "revised" && revised.draft == "a2")
    #expect(TutorJudge.reading("{\"verdict\": \"maybe\"}") == nil)
    #expect(TutorJudge.reading("held") == nil)
}

private func draftsReply(_ held: String, next: Bool) -> String {
    "@draft \(held)\nnobody runs it\n@idea\nthe key outlives its holder\n" + (next ? flatStep : "")
}

@Test func eachDraftCarriesTheStepItsOutcomeIsAssigned() throws {
    let path = try sessionFile()
    #expect(try applyStagedReply(draftsReply("held", next: false), path: path, stepID: "s1", now: "t", branches: branches).refused
        == ["draft 1 needs a @step after it: the explain step for lock-ttl"])
    #expect(try applyStagedReply("@draft maybe\nx\n@idea\ny", path: path, stepID: "s1", now: "t", branches: branches).refused.first
        == "@draft takes held or missed, not maybe")
    let both = draftsReply("held", next: true) + "\n" + draftsReply("missed", next: false) + "@misconception\nthinks B takes over"
    #expect(try applyStagedReply(both, path: path, stepID: "s1", now: "t", branches: branches).refused.isEmpty)
    let drafts = (rawFile(path)["steps"] as? [[String: Any]])?.first?["drafts"] as? [[String: Any]] ?? []
    #expect(drafts.map { $0["id"] as? String } == ["a1", "a2"])
    #expect((drafts[0]["next"] as? [String: Any])?["form"] as? String == "explain")
    #expect(drafts[1]["next"] == nil && drafts[1]["misconception"] as? String == "thinks B takes over")   // a miss closes on the card, Show's
    let step = (rawFile(path)["steps"] as? [[String: Any]])?.first
    #expect(TutorAgent.draftedNext(step, matched: "a1", for: branches["hit"]!)?["form"] as? String == "explain")
    #expect(TutorAgent.draftedNext(step, matched: "a2", for: branches["hit"]!) == nil)
}

@Test func aNextStepBothOutcomesShareIsWrittenOnceAndCarriedByEveryDraft() throws {
    let path = try sessionFile()
    let same: [String: Any] = ["form": "worked", "concept": "key-is-convention", "level": "predict"]
    let reply = (draftsReply("held", next: true) + "\n" + draftsReply("missed", next: false))
        .replacingOccurrences(of: "@frame Tue 02:00", with: variation + "\n@frame Tue 02:00")
    #expect(try applyStagedReply(reply, path: path, stepID: "s1", now: "t", branches: ["hit": same, "miss": same]).refused.isEmpty)
    let step = (rawFile(path)["steps"] as? [[String: Any]])?.first
    #expect(TutorAgent.draftedNext(step, matched: "a2", for: same)?["concept"] as? String == "key-is-convention")
}
