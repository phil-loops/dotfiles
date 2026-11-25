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
    /// The tutor's drafts of the likely answers, written while the learner reads; never shown. Each draft's
    /// follow-up step stays raw JSON in the file until the tutor takes it.
    let drafts: [StepDraft]?

    struct StepDraft: Decodable, Equatable {
        let id: String
        let answer: String
        let held: Bool?
        let misconception: String?
    }

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
    if step.reveal == nil || step.explain == nil { out.append("a step arrives sealed: its reveal and its explain question come with it") }
    if let reveal = step.reveal, reveal.frames.isEmpty, reveal.result.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append("the reveal has neither frames nor a result")
    }
    if step.explain.map({ $0.filter { $0 == "?" }.count > 1 }) == true { out.append("explain asks more than one question") }
    if step.verdict != nil { out.append("the verdict is Show's judge's to give, after the prediction") }
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

/// A staged tutor reply: sections opened by a line `@name`, in the order the tutor wrote them.
func tutorSections(_ text: String) -> [(name: String, body: String)] {
    var out: [(name: String, body: String)] = []
    for line in text.components(separatedBy: "\n") {
        let bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("@"), bare.dropFirst().allSatisfy({ $0.isLetter }), bare.count > 1 {
            out.append((String(bare.dropFirst()), ""))
        } else if !out.isEmpty {
            out[out.count - 1].body += (out[out.count - 1].body.isEmpty ? "" : "\n") + line
        }
    }
    return out.map { ($0.name, $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// What Show did with a staged reply: the evidence rows to record and the steps it posted, or why it refused the
/// whole reply (nothing written).
struct StagedApply {
    var evidence: [String] = []
    var refused: [String] = []
    var posted: [String] = []
}

/// Writes a staged reply into the session file — Show is its only writer. `stepID` is the step the message was about.
/// Every new or fixed step is checked first; a refusal writes nothing.
func applyStagedReply(_ text: String, path: String, stepID: String?, now: String) throws -> StagedApply {
    var result = StagedApply()
    let sections = tutorSections(text)
    guard !sections.isEmpty else {
        result.refused.append("the reply had no @sections")
        return result
    }
    var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] ?? [:]
    var steps = raw["steps"] as? [[String: Any]] ?? []
    var notes = raw["notes"] as? [[String: Any]] ?? []
    func checked(_ object: [String: Any]) {
        do {
            let typed = try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject: object))
            let problems = stepProblems(typed, nil)
            if !problems.isEmpty { result.refused.append("step \(typed.id): " + problems.joined(separator: "; ")) }
        } catch {
            result.refused.append("a step didn't match the schema: \(error)")
        }
    }
    func step(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.refused.append("a @step or @fix wasn't one JSON object")
            return nil
        }
        checked(object)
        return object
    }
    func post(_ object: [String: Any]) {
        if steps.contains(where: { $0["id"] as? String == object["id"] as? String }) {
            result.refused.append("step \(object["id"] ?? "?") already exists; a new step needs a new id")
        }
        steps.append(object)
        if let id = object["id"] as? String { result.posted.append(id) }
    }
    for (name, body) in sections {
        switch name {
        case "note":
            if !body.isEmpty { notes.append(["at": now, "text": body]) }
        case "stations":
            guard let data = body.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                result.refused.append("@stations wasn't a JSON list")
                continue
            }
            raw["stations"] = list
        case "consolidate":
            guard let stepID, let i = steps.firstIndex(where: { $0["id"] as? String == stepID }) else {
                result.refused.append("@consolidate came for no open step")
                continue
            }
            steps[i]["consolidate"] = body
        case "step":
            guard let object = step(body) else { continue }
            post(object)
        case "drafts":
            guard let stepID, let i = steps.firstIndex(where: { $0["id"] as? String == stepID }) else {
                result.refused.append("@drafts came for no open step")
                continue
            }
            guard let data = body.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else {
                result.refused.append("@drafts wasn't a JSON list of drafts")
                continue
            }
            for draft in list {
                guard draft["id"] is String, draft["answer"] is String, draft["idea"] is String, let next = draft["next"] as? [String: Any] else {
                    result.refused.append("each draft has id, answer, idea and next")
                    continue
                }
                checked(next)
            }
            steps[i]["drafts"] = list
        case "take":
            let id = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let stepID, let i = steps.firstIndex(where: { $0["id"] as? String == stepID }),
                  let next = (steps[i]["drafts"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id })?["next"] as? [String: Any] else {
                result.refused.append("@take \(id) names no draft of this step")
                continue
            }
            post(next)
        case "fix":
            guard let object = step(body) else { continue }
            guard let i = steps.firstIndex(where: { $0["id"] as? String == object["id"] as? String }) else {
                result.refused.append("@fix names no existing step")
                continue
            }
            steps[i] = object
        case "plan":
            continue
        case "title":
            if !body.isEmpty { raw["title"] = body.components(separatedBy: "\n")[0] }
        case "evidence":
            result.evidence += body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            result.refused.append("unknown section @\(name)")
        }
    }
    guard result.refused.isEmpty else { return result }
    raw["steps"] = steps
    raw["notes"] = notes
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    return result
}
