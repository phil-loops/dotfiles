import Foundation
import Testing
@testable import Show

private func step(_ extra: [String: Any] = [:]) throws -> TutorStep {
    var raw: [String: Any] = [
        "id": "s1", "title": "The digest job after a crash",
        "setup": "croon's job lock has **no expiry**.",
        "watch": ["lock", "digest"],
        "frames": [["t": "Tue 02:00", "event": "A takes the lock", "state": ["lock": "A", "digest": "running"]],
                   ["t": "Tue 02:01", "event": "A's node is killed", "state": ["digest": "dead"]]],
        "predict": "Who holds the lock on Wednesday at 02:00?",
    ]
    raw.merge(extra) { $1 }
    return try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject: raw))
}

private let reveal: [String: Any] = ["frames": [["t": "Wed 02:00", "event": "SET NX fails for A, B and C", "state": ["lock": "A"]]],
                                     "result": "Nobody runs digest again until someone deletes the key."]

private func answer(_ parts: [String: String]) -> TutorAnswer {
    TutorAnswer(parts: parts, confidence: "medium", at: "2026-11-24T00:00:00Z")
}

@Test func aStepWalksPredictRevealExplainConsolidate() throws {
    #expect(stepPhase(try step(), nil) == .predict)
    #expect(stepPhase(try step(), answer(["predict": "nobody"])) == .awaitingReveal)
    let revealed = try step(["reveal": reveal, "explain": "Why does nobody get it?", "verdict": "held"])
    #expect(stepPhase(revealed, answer(["predict": "nobody"])) == .explain)
    #expect(stepPhase(revealed, answer(["predict": "nobody", "explain": "no expiry"])) == .awaitingConsolidate)
    let closed = try step(["reveal": reveal, "explain": "Why?", "verdict": "held", "consolidate": "A lock with no expiry outlives its holder."])
    #expect(stepPhase(closed, answer(["predict": "nobody", "explain": "no expiry"])) == .done)
}

@Test func aRevealWrittenBeforeThePredictionIsNeitherShownNorAccepted() throws {
    let early = try step(["reveal": reveal, "explain": "Why?"])
    #expect(stepPhase(early, nil) == .predict)
    #expect(stepProblems(early, nil).contains("the reveal or the explain question arrived before the prediction"))
}

@Test func theShapeKeepsOneQuestionPerPhase() throws {
    #expect(stepProblems(try step(), nil).isEmpty)
    #expect(stepProblems(try step(["predict": "Who holds it? And why?"]), nil).contains("predict asks more than one question"))
    #expect(stepProblems(try step(["reveal": reveal]), answer(["predict": "x"])).contains("the reveal and the explain question come together"))
    #expect(stepProblems(try step(["kind": "invent", "reveal": reveal, "explain": "Which held?", "verdict": "held"]), answer(["predict": "x"]))
        .contains("an invent step gets no verdict"))
    #expect(stepProblems(try step(["frames": [["t": "0", "event": "e", "state": ["queue": 3]]]]), nil)
        .contains("frames set queue, which isn't in watch"))
}

@Test func stateFoldsEachFramesChangesInOrder() throws {
    let s = try step()
    #expect(stepState(s.frames, through: 0) == [:])
    #expect(stepState(s.frames, through: 1) == ["lock": "A", "digest": "running"])
    #expect(stepState(s.frames, through: 2) == ["lock": "A", "digest": "dead"])
    let numeric = try step(["watch": ["n", "ok"], "frames": [["t": "0", "event": "e", "state": ["n": 3, "ok": true]]]])
    #expect(stepState(numeric.frames, through: 1) == ["n": "3", "ok": "yes"])
}

@Test func theCurrentStepIsTheFirstNotDone() throws {
    let raw: [String: Any] = ["mode": "tutor", "format": 2, "title": "Locks", "steps": [
        ["id": "s1", "title": "a", "setup": "x", "frames": [["t": "0", "event": "e"]], "predict": "p?",
         "reveal": reveal, "explain": "w?", "verdict": "revised", "consolidate": "c"],
        ["id": "s2", "title": "b", "setup": "y", "frames": [["t": "0", "event": "e"]], "predict": "q?"],
    ]]
    let session = try JSONDecoder().decode(TutorSession.self, from: JSONSerialization.data(withJSONObject: raw))
    #expect(currentStep(session, ["s1": answer(["predict": "a", "explain": "b"])])?.id == "s2")
    #expect(currentStep(session, [:])?.id == "s1")
    #expect(currentStep(session, ["s1": answer(["predict": "a", "explain": "b"]), "s2": answer(["predict": "a"])])?.id == "s2")
}
