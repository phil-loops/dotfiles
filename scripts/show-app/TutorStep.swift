import Foundation

/// One moment on a step's timeline. `state` holds only the watched keys this moment changes.
struct StepFrame: Decodable, Equatable {
    let t: String
    let event: String
    let state: [String: String]

    enum CodingKeys: String, CodingKey { case t, event, state }

    init(t: String, event: String, state: [String: String] = [:]) {
        self.t = t
        self.event = event
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(String.self, forKey: .t)
        event = try c.decode(String.self, forKey: .event)
        let raw = try c.decodeIfPresent([String: StateValue].self, forKey: .state) ?? [:]
        state = raw.mapValues(\.text)
    }
}

/// A state value as the tutor wrote it: a string, number, boolean or null, shown as text.
struct StateValue: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { text = "—" }
        else if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = String(d) }
        else if let b = try? c.decode(Bool.self) { text = b ? "yes" : "no" }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "a state value is a string, number, boolean or null") }
    }
}

struct TutorStep: Decodable, Equatable {
    let id: String
    let station: String?
    let title: String
    /// predict: one situation, one behavior. invent: the learner proposes a rule; no verdict.
    let kind: String?
    let setup: String
    /// The state panel's rows, in order.
    let watch: [String]?
    let frames: [StepFrame]
    let predict: String
    let reveal: Reveal?
    let explain: String?
    let verdict: String?
    let consolidate: String?

    struct Reveal: Decodable, Equatable {
        let frames: [StepFrame]
        let result: String
        /// Where the frames came from: "sim-play <scenario>" when the system played them.
        let source: String?
    }

    var isInvent: Bool { kind == "invent" }
    var rows: [String] { watch ?? [] }
}

enum StepPhase: Equatable {
    case predict, awaitingReveal, explain, awaitingConsolidate, done
}

/// Where a step stands, from what the tutor wrote and what the learner sent. A reveal written before the
/// prediction doesn't count: the step stays at predict.
func stepPhase(_ step: TutorStep, _ answer: TutorAnswer?) -> StepPhase {
    guard let predicted = answer?.parts["predict"], !predicted.isEmpty else { return .predict }
    guard step.reveal != nil, step.explain != nil else { return .awaitingReveal }
    guard let explained = answer?.parts["explain"], !explained.isEmpty else { return .explain }
    return step.consolidate == nil ? .awaitingConsolidate : .done
}

/// The step the learner is on: the first one not done, or nil while the tutor owes the next step.
func currentStep(_ session: TutorSession, _ answers: [String: TutorAnswer]) -> TutorStep? {
    session.steps.first { stepPhase($0, answers[$0.id]) != .done }
}

/// What makes a step unusable, in words the tutor can fix; empty when it's sound.
func stepProblems(_ step: TutorStep, _ answer: TutorAnswer?) -> [String] {
    var out: [String] = []
    if step.setup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("the setup is empty") }
    if step.frames.isEmpty { out.append("the timeline has no frames to predict from") }
    if step.predict.filter({ $0 == "?" }).count > 1 { out.append("predict asks more than one question") }
    let watched = Set(step.rows)
    let frames = step.frames + (step.reveal?.frames ?? [])
    let unwatched = Set(frames.flatMap(\.state.keys)).subtracting(watched).sorted()
    if !unwatched.isEmpty { out.append("frames set \(unwatched.joined(separator: ", ")), which isn't in watch") }
    let predicted = answer?.parts["predict"].map { !$0.isEmpty } ?? false
    if !predicted, step.reveal != nil || step.explain != nil { out.append("the reveal or the explain question arrived before the prediction") }
    if let reveal = step.reveal, reveal.frames.isEmpty, reveal.result.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append("the reveal has neither frames nor a result")
    }
    if (step.reveal == nil) != (step.explain == nil) { out.append("the reveal and the explain question come together") }
    if step.explain.map({ $0.filter { $0 == "?" }.count > 1 }) == true { out.append("explain asks more than one question") }
    if step.isInvent, step.verdict != nil { out.append("an invent step gets no verdict") }
    if let v = step.verdict, v != "held", v != "revised" { out.append("verdict is held or revised, not \(v)") }
    let explained = answer?.parts["explain"].map { !$0.isEmpty } ?? false
    if !explained, step.consolidate != nil { out.append("the consolidation arrived before the explanation") }
    return out
}

/// The watched state after the first `count` frames: each frame changes only the keys it names.
func stepState(_ frames: [StepFrame], through count: Int) -> [String: String] {
    var state: [String: String] = [:]
    for frame in frames.prefix(count) { state.merge(frame.state) { $1 } }
    return state
}

extension TutorAgent {
    /// The protocol for a format-2 session: the tutor writes typed steps, and each message names the one phase it owes.
    func stagedBootPrompt(_ answers: String) -> String {
        """
        You are the tutor for one Show Learn session, the file \(sessionPath). Teach by ~/.dotfiles/.claude/skills/tutor/SKILL.md; for an opening "re-test <concept>", by ~/.dotfiles/.claude/skills/retest/SKILL.md instead (`learn concept <id>` gives its history), one situation only.
        Show puts one step on screen at a time and only ever asks the learner the question of the phase they're in, so write only what the message below asks for.
        - Reply only by editing the session file (Edit, or Write for a whole rewrite). Keep it valid JSON and leave "mode", "format" and "agent" alone. The learner never sees your chat text, so keep it to a line.
        - The learner's answers and messages arrive in \(answers) (per step: "predict", "explain", "confidence"). Read it; never write it.
        - Record evidence with `~/.dotfiles/scripts/learn evidence '<json>'`, called by exactly that path, as is `~/.dotfiles/scripts/learn state`. Never touch the graph another way.
        - Show asks for confidence itself; don't ask for it.
        - After every edit run `~/.dotfiles/scripts/show --tutor-check \(sessionPath)`. It prints each step's phase, or why Show refuses the file or a step; fix what it names before you stop.
        - Every entry in "notes" is {"at": <`date -u +%Y-%m-%dT%H:%M:%SZ`>, "text": "<markdown>"}, never a bare string.
        Messages:
        - The opening ("/tutor <topic>" or "re-test <concept>"): set "stations" (the map, a few names) and append the first step with "reveal", "explain", "verdict" and "consolidate" all null. Put a short map in "notes" (as a note entry) if it helps.
        - "tutor predicted: <file> step <id>": read the prediction, then on that step set "reveal" {"frames": [...], "result": "one or two sentences: what happened"}, "explain" (one question: why it happened, or what the learner would now change) and "verdict" ("held" or "revised"; null on an invent step). Record evidence for the prediction. Where a `~/.dotfiles/scripts/sim-play` scenario plays this situation, run it and take the reveal from its log, with "source": "sim-play <scenario>". Add no new step.
        - "tutor explained: <file> step <id>": record evidence for the explanation, set that step's "consolidate" (2–4 plain sentences assembling the idea, set beside what the learner said), move "stations" on if a station is done, then append the next step built from what they just said, with its later fields null.
        - "learner says: <text>": append {"at": <`date -u +%Y-%m-%dT%H:%M:%SZ`>, "text": "<reply, markdown>"} to "notes".
        - "fix step <id> in <file>: <problems>": Show refused that step's shape. Rewrite exactly what the problems name; keep everything the learner has already seen.
        Schema: {"mode": "tutor", "format": 2, "title", "stations": [{"name", "state": "done|current|todo"}], "steps": [{"id": "s1", "station", "title", "kind": "predict|invent", "setup": "markdown: the concrete system and the one action", "watch": ["key", …], "frames": [{"t": "the time as a person says it, e.g. Tue 02:00 or 02:01:30, never cut short", "event", "state": {"key": "value"}}], "predict": "one question", "reveal": null, "explain": null, "verdict": null, "consolidate": null}], "notes": [], "agent": {…}}
        - "frames" run up to the playhead: the moment just before what the learner predicts. Each frame's "state" names only the watched keys that moment changes; "watch" lists every key any frame (reveal frames too) sets, in the order the panel shows them.
        - "predict" asks about one behavior and has one question mark. No "why" before the reveal: why belongs to "explain".
        - The reveal's frames continue the same timeline and keys from the playhead.
        """
    }
}
