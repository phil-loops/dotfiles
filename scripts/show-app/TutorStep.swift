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
    /// What `learn next` assigned, stamped on by Show when it posts the step: the concept, the level it tests and its form.
    let concept: String?
    let level: String?
    let form: String?
    let conceptName: String?

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
    /// One answer and no timeline: free recall at a topic's start, the card at its end. Show writes both.
    var isSingle: Bool { form == "recall" || form == "card" }
    var rows: [String] { watch ?? [] }
}

enum StepPhase: Equatable {
    case predict, awaitingReveal, explain, awaitingConsolidate, done
}

/// Where a step stands, from what the tutor wrote and what the learner sent. A reveal written before the
/// prediction doesn't count: the step stays at predict.
func stepPhase(_ step: TutorStep, _ answer: TutorAnswer?) -> StepPhase {
    guard let predicted = answer?.parts["predict"], !predicted.isEmpty else { return .predict }
    if step.isSingle { return step.form == "card" || step.consolidate != nil ? .done : .awaitingConsolidate }
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
    if step.isSingle { return out }
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
    /// The opening's topic map, for `learn map`, or the id of a topic the graph already has.
    var map: String?
    var topic: String?
    /// A step was consolidated: once its evidence is recorded, the session owes its next step.
    var finished = false
}

/// The forms Show writes itself; the tutor writes the rest.
let showWrittenForms: Set<String> = ["recall", "card", "done"]

/// Whether two assignments ask for the same step.
func sameAssignment(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
    guard let a, let b else { return false }
    return ["concept", "form", "level"].allSatisfy { a[$0] as? String == b[$0] as? String }
}

/// Stamps an assignment from `learn next` onto a step the tutor wrote, so the step carries what it was for.
func stamp(_ step: inout [String: Any], with assignment: [String: Any]) {
    for key in ["concept", "level", "form"] { step[key] = assignment[key] ?? "" }
    if let name = assignment["name"] as? String, !name.isEmpty { step["conceptName"] = name }
    if let via = assignment["via"] as? String, !via.isEmpty { step["via"] = via }
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
    func step(_ body: String, stampedWith assignment: [String: Any]? = nil) -> [String: Any]? {
        let parsed = Result { try JSONSerialization.jsonObject(with: Data(body.utf8)) }
        guard case .success(let value) = parsed, var object = value as? [String: Any] else {
            let why = (try? parsed.get()) == nil ? parsed.failureReason : "it's not an object"
            result.refused.append("a @step or @fix wasn't one JSON object (\(why))")
            return nil
        }
        if let assignment { stamp(&object, with: assignment) }
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
        case "consolidate":
            guard let stepID, let i = steps.firstIndex(where: { $0["id"] as? String == stepID }) else {
                result.refused.append("@consolidate came for no open step")
                continue
            }
            steps[i]["consolidate"] = body
            result.finished = true
        case "step":
            guard let assigned = raw["assigned"] as? [String: Any], let form = assigned["form"] as? String, !showWrittenForms.contains(form) else {
                result.refused.append("no step is owed now; Show asks for one when the session is due its next")
                continue
            }
            guard var object = step(body, stampedWith: assigned) else { continue }
            stamp(&object, with: assigned)
            raw["assigned"] = nil
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
            // each draft's next step is the one `learn next` will assign if the answer lands that way
            let branches = steps[i]["branches"] as? [String: [String: Any]] ?? [:]
            let shared = sameAssignment(branches["hit"], branches["miss"])
            var stamped: [[String: Any]] = []
            for var draft in list {
                guard draft["id"] is String, draft["answer"] is String, draft["idea"] is String, let held = draft["held"] as? Bool else {
                    result.refused.append("each draft has id, answer, held and idea")
                    continue
                }
                let branch = branches[held ? "hit" : "miss"]
                if shared, draft["next"] is NSNull || draft["next"] == nil {
                    draft["next"] = nil   // either outcome leads to the same step: one draft carries it
                } else if let branch, let form = branch["form"] as? String, !showWrittenForms.contains(form) {
                    guard var next = draft["next"] as? [String: Any] else {
                        result.refused.append("draft \(draft["id"] ?? "?") needs a next step: the \(form) step for \(branch["concept"] ?? "?")")
                        continue
                    }
                    stamp(&next, with: branch)
                    checked(next)
                    draft["next"] = next
                } else {
                    draft["next"] = nil
                }
                stamped.append(draft)
            }
            if shared, let form = branches["hit"]?["form"] as? String, !showWrittenForms.contains(form), !stamped.contains(where: { $0["next"] != nil }) {
                result.refused.append("one draft needs the next step, which either outcome leads to: the \(form) step for \(branches["hit"]?["concept"] ?? "?")")
            }
            steps[i]["drafts"] = stamped
        case "fix":
            guard var object = step(body) else { continue }
            guard let i = steps.firstIndex(where: { $0["id"] as? String == object["id"] as? String }) else {
                result.refused.append("@fix names no existing step")
                continue
            }
            for key in ["concept", "conceptName", "level", "form", "via", "branches"] { object[key] = steps[i][key] }
            steps[i] = object
        case "map":
            guard let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                result.refused.append("@map wasn't one JSON object")
                continue
            }
            result.map = body
        case "topic":
            result.topic = body.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        case "plan":
            continue
        case "stations", "take":
            result.refused.append("@\(name) is Show's: it derives the stations and picks the next step from the learner's graph")
        case "title":
            if !body.isEmpty { raw["title"] = body.components(separatedBy: "\n")[0] }
        case "evidence":
            for line in body.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                guard let data = line.data(using: .utf8), var row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    result.refused.append("an @evidence line wasn't one JSON object: \(line)")
                    continue
                }
                if let stepID, steps.first(where: { $0["id"] as? String == stepID })?["form"] as? String == "recall" { row["rung"] = "recall" }
                guard let out = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
                result.evidence.append(String(decoding: out, as: UTF8.self))
            }
        default:
            result.refused.append("unknown section @\(name)")
        }
    }
    if result.finished, let stepID, let open = steps.first(where: { $0["id"] as? String == stepID }),
       let concept = open["concept"] as? String, !concept.isEmpty, let level = open["level"] as? String, !level.isEmpty {
        let rows = result.evidence.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if !rows.contains(where: { $0["concept"] as? String == concept && $0["level"] as? String == level }) {
            result.refused.append("@evidence needs the step's own row: concept \(concept) at level \(level), a hit only if the prediction and the explanation both held")
        }
    }
    guard result.refused.isEmpty else { return result }
    raw["steps"] = steps
    raw["notes"] = notes
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    return result
}

extension Result where Failure == Error {
    /// The parser's own words for where the text stopped being JSON.
    var failureReason: String {
        guard case .failure(let error) = self else { return "" }
        return (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
    }
}

