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

@Test func aReplyIsReadBySections() {
    let sections = tutorSections("@consolidate\nThe key outlives\nits holder.\n\n@evidence\n{\"a\":1}\n{\"b\":2}\nstray")
    #expect(sections.map(\.name) == ["consolidate", "evidence"])
    #expect(sections[0].body == "The key outlives\nits holder.")
    #expect(sections[1].body == "{\"a\":1}\n{\"b\":2}\nstray")
    #expect(tutorSections("no sections here").isEmpty)
}

private let assignment: [String: Any] = ["form": "contrast", "concept": "lock-ttl", "level": "predict", "why": "missed"]
private let branches: [String: Any] = ["hit": ["form": "explain", "concept": "lock-ttl", "level": "explain"],
                                       "miss": ["form": "card", "concept": "lock-ttl", "level": ""]]

private func sessionFile(assigned: [String: Any]? = nil) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString).json").path
    var raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "notes": [], "agent": ["session": "x"],
                              "steps": [stepJSON(["concept": "lock-ttl", "level": "predict", "form": "predict", "branches": branches])]]
    if let assigned { raw["assigned"] = assigned }
    try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: path))
    return path
}

private func text(_ object: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }

private func rawFile(_ path: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
}

@Test func anExplainedReplyClosesTheStepWithItsOwnEvidenceRow() throws {
    let path = try sessionFile()
    let row = "{\"concept\": \"lock-ttl\", \"level\": \"predict\", \"outcome\": \"hit\"}"
    let applied = try applyStagedReply("@title\nJob locks\n@consolidate\nA lock with no expiry outlives its holder.\n@evidence\n\(row)",
                                       path: path, stepID: "s1", now: "2026-11-24T00:00:00Z")
    #expect(applied.refused.isEmpty && applied.finished)
    #expect(applied.evidence == ["{\"concept\":\"lock-ttl\",\"level\":\"predict\",\"outcome\":\"hit\"}"])
    let session = try loadTutorSession(path)
    #expect(session.title == "Job locks" && session.steps[0].consolidate == "A lock with no expiry outlives its holder.")
    let other = try sessionFile()
    #expect(try applyStagedReply("@consolidate\nidea\n@evidence\n{\"concept\": \"other\", \"level\": \"predict\"}", path: other, stepID: "s1", now: "t")
        .refused == ["@evidence needs the step's own row: concept lock-ttl at level predict, a hit only if the prediction and the explanation both held"])
}

@Test func aStepIsWrittenOnlyWhenShowAssignedOneAndCarriesTheAssignment() throws {
    let unasked = try sessionFile()
    #expect(try applyStagedReply("@step\n\(text(stepJSON(["id": "s2"])))", path: unasked, stepID: nil, now: "t").refused
        == ["no step is owed now; Show asks for one when the session is due its next"])
    let path = try sessionFile(assigned: assignment)
    let applied = try applyStagedReply("@step\n\(text(stepJSON(["id": "s2", "concept": "something-else"])))", path: path, stepID: nil, now: "t")
    #expect(applied.refused.isEmpty && applied.posted == ["s2"])
    let posted = try loadTutorSession(path).steps[1]
    #expect(posted.concept == "lock-ttl" && posted.form == "contrast" && posted.level == "predict")
    #expect(rawFile(path)["assigned"] == nil)
    #expect(try applyStagedReply("@step\n\(text(stepJSON(["id": "s3"])))", path: path, stepID: nil, now: "t").refused.count == 1)
}

@Test func aRefusedReplyWritesNothing() throws {
    let path = try sessionFile(assigned: assignment)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let applied = try applyStagedReply("@consolidate\nidea\n@step\n\(text(stepJSON(["id": "s2", "predict": "Who? Why?"])))", path: path, stepID: "s1", now: "t")
    #expect(applied.refused.contains("step s2: predict asks more than one question"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    #expect(try applyStagedReply("@step\n\(text(stepJSON()))", path: path, stepID: nil, now: "t").refused == ["step s1 already exists; a new step needs a new id"])
    for owned in ["@stations\n[]", "@take\na1"] {
        #expect(try applyStagedReply(owned, path: path, stepID: "s1", now: "t").refused.first?.hasSuffix("picks the next step from the learner's graph") == true)
    }
}

@Test func theOpeningNamesItsTopic() throws {
    let path = try sessionFile()
    let mapped = try applyStagedReply("@title\nLocks\n@map\n{\"topic\": {\"id\": \"locks\"}, \"stages\": []}", path: path, stepID: nil, now: "t")
    #expect(mapped.map != nil && mapped.refused.isEmpty)
    #expect(try applyStagedReply("@topic\ncroon-job-locks\n", path: path, stepID: nil, now: "t").topic == "croon-job-locks")
    #expect(try applyStagedReply("@map\nnot json", path: path, stepID: nil, now: "t").refused == ["@map wasn't one JSON object"])
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

@Test func recallEvidenceIsStampedAsRecall() throws {
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

@Test func eachDraftsNextIsTheStepItsOutcomeWillBeAssigned() throws {
    let path = try sessionFile()
    let held = ["id": "a1", "answer": "nobody runs it", "held": true, "idea": "the key outlives its holder", "next": stepJSON(["id": "s2"])] as [String: Any]
    let missed = ["id": "a2", "answer": "B takes over", "held": false, "idea": "x", "next": stepJSON(["id": "s3"])] as [String: Any]
    let bare = ["id": "a3", "answer": "it expires", "held": true, "idea": "y"] as [String: Any]
    #expect(try applyStagedReply("@drafts\n\(text([bare]))", path: path, stepID: "s1", now: "t").refused
        == ["draft a3 needs a next step: the explain step for lock-ttl"])
    let bad = ["id": "a1", "answer": "x", "held": true, "idea": "x", "next": stepJSON(["id": "s2", "predict": "Who? Why?"])] as [String: Any]
    #expect(try applyStagedReply("@drafts\n\(text([bad]))", path: path, stepID: "s1", now: "t").refused == ["step s2: predict asks more than one question"])
    #expect(try applyStagedReply("@drafts\n\(text([held, missed]))", path: path, stepID: "s1", now: "t").refused.isEmpty)
    let drafts = (rawFile(path)["steps"] as? [[String: Any]])?.first?["drafts"] as? [[String: Any]] ?? []
    #expect((drafts[0]["next"] as? [String: Any])?["form"] as? String == "explain")
    #expect(drafts[1]["next"] == nil)   // a miss closes on the card, which Show writes
}

@Test func aNextStepBothOutcomesShareIsWrittenOnceAndTakenWhicheverWayItLands() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json").path
    let same: [String: Any] = ["form": "worked", "concept": "key-is-convention", "level": "predict"]
    let raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "notes": [], "agent": ["session": "x"],
                              "steps": [stepJSON(["concept": "lock-ttl", "level": "predict", "form": "contrast", "branches": ["hit": same, "miss": same]])]]
    try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: path))
    let carrier = ["id": "a1", "answer": "x", "held": true, "idea": "i", "next": stepJSON(["id": "s2"])] as [String: Any]
    let bare = ["id": "a2", "answer": "y", "held": false, "idea": "j", "next": NSNull()] as [String: Any]
    #expect(try applyStagedReply("@drafts\n\(text([bare]))", path: path, stepID: "s1", now: "t").refused.count == 1)
    #expect(try applyStagedReply("@drafts\n\(text([carrier, bare]))", path: path, stepID: "s1", now: "t").refused.isEmpty)
    let step = (rawFile(path)["steps"] as? [[String: Any]])?.first
    #expect(TutorAgent.draftedNext(step, matched: "a2", for: same)?["form"] as? String == "worked")
    #expect(TutorAgent.draftedNext(step, matched: nil, for: ["form": "explain", "concept": "lock-ttl", "level": "explain"]) == nil)
}

