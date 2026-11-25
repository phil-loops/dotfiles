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

private func sessionFile() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString).json").path
    let raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "steps": [stepJSON()], "notes": [],
                              "agent": ["session": "x"]]
    try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: path))
    return path
}

@Test func showWritesAnExplainedReplyAndTheNextStep() throws {
    let path = try sessionFile()
    let next = String(data: try JSONSerialization.data(withJSONObject: stepJSON(["id": "s2"])), encoding: .utf8)!
    let reply = "@title\nJob locks\n@consolidate\nA lock with no expiry outlives its holder.\n@evidence\n{\"concept\": \"c\", \"level\": \"explain\"}\n@step\n\(next)"
    let applied = try applyStagedReply(reply, path: path, stepID: "s1", now: "2026-11-24T00:00:00Z")
    #expect(applied.refused.isEmpty)
    #expect(applied.evidence == ["{\"concept\": \"c\", \"level\": \"explain\"}"])
    let session = try loadTutorSession(path)
    #expect(session.title == "Job locks")
    #expect(session.steps.map(\.id) == ["s1", "s2"])
    #expect(session.steps[0].consolidate == "A lock with no expiry outlives its holder.")
}

@Test func aRefusedReplyWritesNothing() throws {
    let path = try sessionFile()
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let bad = String(data: try JSONSerialization.data(withJSONObject: stepJSON(["id": "s2", "predict": "Who? Why?"])), encoding: .utf8)!
    let applied = try applyStagedReply("@consolidate\nidea\n@step\n\(bad)", path: path, stepID: "s1", now: "t")
    #expect(applied.refused == ["step s2: predict asks more than one question"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    #expect(try applyStagedReply("@step\n\(String(data: try JSONSerialization.data(withJSONObject: stepJSON()), encoding: .utf8)!)", path: path, stepID: nil, now: "t")
        .refused == ["step s1 already exists; a new step needs a new id"])
}

@Test func theJudgeReadingIsTheObjectItPromised() {
    #expect(TutorJudge.reading("{\"verdict\": \"held\", \"why\": \"Right: the key never expires.\"}")! == ("held", "Right: the key never expires."))
    #expect(TutorJudge.reading("Sure! {\"verdict\": \"revised\", \"why\": \"B gets it.\"} ")! == ("revised", "B gets it."))
    #expect(TutorJudge.reading("{\"verdict\": \"maybe\"}") == nil)
    #expect(TutorJudge.reading("held") == nil)
}
