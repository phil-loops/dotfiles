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
    /// The run this step varies, shown whole above the live timeline (a worked example's run, or the situation a
    /// contrast changes), and the one thing that's different this time.
    let example: Reveal?
    let change: String?
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
    /// A step that varies one thing about a run shown whole: what's the same and what changed is the lesson.
    var isVariation: Bool { form == "worked" || form == "contrast" }
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
    if step.isVariation, step.example?.frames.isEmpty != false || (step.example?.result ?? "").isEmpty || (step.change ?? "").isEmpty {
        out.append("a \(step.form ?? "") step shows the run it varies: its @example lines, its @outcome and the one @change")
    }
    if step.frames.isEmpty { out.append("the timeline has no frames to predict from") }
    if step.predict.filter({ $0 == "?" }).count > 1 { out.append("predict asks more than one question") }
    let watched = Set(step.rows)
    let frames = (step.example?.frames ?? []) + step.frames + (step.reveal?.frames ?? [])
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

/// The section names a staged reply may use. A line `@name` (or `@name <argument>`) opens one only when the name is
/// one of these, so an `@` inside prose stays prose.
let tutorSectionNames: Set<String> = [
    "title", "map", "stage", "concept", "topic", "note", "consolidate", "plan", "evidence",
    "prediction", "explanation", "misconception", "contrast",
    "step", "fix", "setup", "example", "outcome", "change", "frame", "predict", "reveal", "result", "explain", "source",
    "draft", "idea", "stations", "take",
]

/// One section of a staged reply: its name, what followed the name on its line, and the lines under it.
struct TutorSection {
    let name: String
    let argument: String
    var body: String
}

/// A staged tutor reply: sections opened by a line `@name [argument]`, in the order the tutor wrote them.
func tutorSections(_ text: String) -> [TutorSection] {
    var out: [TutorSection] = []
    for line in text.components(separatedBy: "\n") {
        let bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("@") {
            let head = bare.dropFirst().prefix { $0.isLetter }
            let rest = bare.dropFirst(1 + head.count)
            if tutorSectionNames.contains(String(head)), rest.isEmpty || rest.first == " " {
                out.append(TutorSection(name: String(head), argument: rest.trimmingCharacters(in: .whitespaces), body: ""))
                continue
            }
        }
        if !out.isEmpty { out[out.count - 1].body += (out[out.count - 1].body.isEmpty ? "" : "\n") + line }
    }
    return out.map { TutorSection(name: $0.name, argument: $0.argument, body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// A timeline line `<time> | <event> | key=value; key=value` (the state part is optional).
func frameLine(_ line: String) -> [String: Any]? {
    var parts = line.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 2, !parts[0].isEmpty else { return nil }
    var state: [String: String] = [:]
    var keys: [String] = []
    if parts.count >= 3, parts.last!.contains("=") {
        for pair in parts.removeLast().components(separatedBy: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, state[key] == nil { keys.append(key) }
            if !key.isEmpty { state[key] = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
    }
    let event = parts.dropFirst().joined(separator: " | ")
    guard !event.isEmpty else { return nil }
    return ["t": parts[0], "event": event, "state": state, "keys": keys]
}

/// What Show did with a staged reply: the evidence rows to record and the steps it posted, or why it refused the
/// whole reply (nothing written).
struct StagedApply {
    var evidence: [String] = []
    var refused: [String] = []
    var posted: [String] = []
    /// The opening's topic map, as `learn map` reads it, or the id of a topic the graph already has.
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

func newStepID(_ steps: [[String: Any]]) -> String {
    let taken = Set(steps.compactMap { $0["id"] as? String })
    var n = steps.count + 1
    while taken.contains("s\(n)") { n += 1 }
    return "s\(n)"
}

/// Writes a staged reply into the session file — Show is its only writer. `stepID` is the step the message was about;
/// `branches` is what `learn next` assigns after that step if it holds ("hit") and if it misses ("miss"), for its drafts.
/// Every new or fixed step is checked first; a refusal writes nothing.
func applyStagedReply(_ text: String, path: String, stepID: String?, now: String, branches: [String: [String: Any]] = [:]) throws -> StagedApply {
    var result = StagedApply()
    let sections = tutorSections(text)
    guard !sections.isEmpty else {
        result.refused.append("the reply had no @sections")
        return result
    }
    var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] ?? [:]
    var steps = raw["steps"] as? [[String: Any]] ?? []
    var notes = raw["notes"] as? [[String: Any]] ?? []
    let open = stepID.flatMap { id in steps.firstIndex { $0["id"] as? String == id } }

    func checked(_ object: [String: Any]) {
        do {
            let typed = try JSONDecoder().decode(TutorStep.self, from: JSONSerialization.data(withJSONObject: object))
            let problems = stepProblems(typed, nil)
            if !problems.isEmpty { result.refused.append("step \(typed.id): " + problems.joined(separator: "; ")) }
        } catch {
            result.refused.append("a step didn't match the schema: \(error)")
        }
    }

    // ── the walk: steps, drafts and the map are built from their sections
    enum Owner { case owed, fix(String), draft(Int) }
    var building: (owner: Owner, fields: [String: Any], frames: [[String: Any]], reveal: [[String: Any]], example: [[String: Any]])?
    var drafts: [[String: Any]] = []
    var draftOpen: Int?
    var verdicts: [String: String] = [:]
    var mapTopic: [String: Any]?
    var stages: [[String: Any]] = []
    var told: [[String: Any]] = []

    func finishStep() {
        guard let b = building else { return }
        building = nil
        var step = b.fields
        var watch: [String] = []
        // the panel lists keys in the order the frames first set them
        for frame in b.example + b.frames + b.reveal {
            for key in frame["keys"] as? [String] ?? [] where !watch.contains(key) { watch.append(key) }
        }
        let bare = { (frames: [[String: Any]]) in frames.map { $0.filter { $0.key != "keys" } } }
        step["watch"] = watch
        step["frames"] = bare(b.frames)
        let result_ = (step.removeValue(forKey: "result") as? String) ?? ""
        let source = step.removeValue(forKey: "source") as? String
        let outcome = (step.removeValue(forKey: "outcome") as? String) ?? ""
        if !b.example.isEmpty || !outcome.isEmpty { step["example"] = ["frames": bare(b.example), "result": outcome] }
        if !b.reveal.isEmpty || !result_.isEmpty {
            var reveal: [String: Any] = ["frames": bare(b.reveal), "result": result_]
            if let source, !source.isEmpty { reveal["source"] = source }
            step["reveal"] = reveal
        }
        switch b.owner {
        case .owed:
            guard let assigned = raw["assigned"] as? [String: Any], let form = assigned["form"] as? String, !showWrittenForms.contains(form) else {
                result.refused.append("no step is owed now; Show asks for one when the session is due its next")
                return
            }
            step["id"] = newStepID(steps)
            stamp(&step, with: assigned)
            checked(step)
            raw["assigned"] = nil
            steps.append(step)
            result.posted.append(step["id"] as! String)
        case .fix(let id):
            guard let i = steps.firstIndex(where: { $0["id"] as? String == id }) else {
                result.refused.append("@fix \(id) names no step")
                return
            }
            for key in ["id", "concept", "conceptName", "level", "form", "via", "drafts"] { step[key] = steps[i][key] }
            checked(step)
            steps[i] = step
        case .draft(let i):
            drafts[i]["next"] = step
        }
    }

    func stepField(_ section: TutorSection) {
        guard building != nil else {
            result.refused.append("@\(section.name) came outside a @step")
            return
        }
        switch section.name {
        case "frame", "reveal", "example":
            let lines = ([section.argument] + section.body.components(separatedBy: "\n")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for line in lines {
                guard let frame = frameLine(line) else {
                    result.refused.append("a @\(section.name) line isn't `<time> | <event> | key=value; …`: \(line)")
                    continue
                }
                switch section.name {
                case "frame": building!.frames.append(frame)
                case "example": building!.example.append(frame)
                default: building!.reveal.append(frame)
                }
            }
        case "source":
            building!.fields["source"] = section.argument.isEmpty ? section.body : section.argument
        default:
            building!.fields[section.name] = [section.argument, section.body].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    for section in sections {
        switch section.name {
        case "setup", "example", "outcome", "change", "frame", "predict", "reveal", "result", "explain", "source":
            stepField(section)
            continue
        case "step":
            finishStep()
            building = (draftOpen.map { .draft($0) } ?? .owed, ["title": section.argument, "consolidate": NSNull()], [], [], [])
            continue
        case "fix":
            finishStep()
            draftOpen = nil
            let words = section.argument.split(separator: " ", maxSplits: 1).map(String.init)
            building = (.fix(words.first ?? ""), ["title": words.count > 1 ? words[1] : "", "consolidate": NSNull()], [], [], [])
            continue
        case "draft":
            finishStep()
            guard section.argument == "held" || section.argument == "missed" else {
                result.refused.append("@draft takes held or missed, not \(section.argument.isEmpty ? "nothing" : section.argument)")
                continue
            }
            draftOpen = drafts.count
            drafts.append(["id": "a\(drafts.count + 1)", "held": section.argument == "held", "answer": section.body])
            continue
        case "idea" where draftOpen != nil, "misconception" where draftOpen != nil:
            finishStep()
            drafts[draftOpen!][section.name] = [section.argument, section.body].filter { !$0.isEmpty }.joined(separator: "\n")
            continue
        default:
            finishStep()
            draftOpen = nil
        }
        let text = [section.argument, section.body].filter { !$0.isEmpty }.joined(separator: "\n")
        switch section.name {
        case "note":
            if !text.isEmpty { notes.append(["at": now, "text": text]) }
        case "consolidate":
            guard let open else {
                result.refused.append("@consolidate came for no open step")
                continue
            }
            steps[open]["consolidate"] = text
            result.finished = true
        case "prediction", "explanation":
            guard section.argument == "held" || section.argument == "revised" else {
                result.refused.append("@\(section.name) takes held or revised")
                continue
            }
            verdicts[section.name] = section.argument
        case "misconception", "contrast":
            verdicts[section.name] = text
        case "map":
            let parts = section.argument.components(separatedBy: " | ")
            mapTopic = ["id": parts[0], "title": parts.count > 1 ? parts[1] : parts[0], "source": parts.count > 2 ? parts[2] : ""]
        case "stage":
            stages.append(["name": text, "concepts": [[String: Any]]()])
        case "concept":
            let parts = section.argument.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !stages.isEmpty, parts.count >= 3 else {
                result.refused.append("a @concept is `<id> | <name> | <statement> | needs <ids> | like <ids>`, under a @stage: \(section.argument)")
                continue
            }
            var concept: [String: Any] = ["id": parts[0], "name": parts[1], "statement": parts[2]]
            for extra in parts.dropFirst(3) {
                let ids = { (p: String) in extra.dropFirst(p.count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                if extra.hasPrefix("needs ") { concept["builds_on"] = ids("needs ") }
                if extra.hasPrefix("like ") { concept["analogs"] = ids("like ") }
            }
            var stage = stages.removeLast()
            stage["concepts"] = (stage["concepts"] as! [[String: Any]]) + [concept]
            stages.append(stage)
        case "topic":
            result.topic = text.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        case "plan":
            continue
        case "stations", "take":
            result.refused.append("@\(section.name) is Show's: it derives the stations and picks the next step from the learner's graph")
        case "title":
            if !text.isEmpty { raw["title"] = text.components(separatedBy: "\n")[0] }
        case "evidence":
            for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                guard let data = line.data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    result.refused.append("an @evidence line wasn't one JSON object: \(line)")
                    continue
                }
                told.append(row)
            }
        default:
            result.refused.append("@\(section.name) belongs inside a @step or a @draft")
        }
    }
    finishStep()

    // ── the map
    if let mapTopic {
        if stages.isEmpty || stages.contains(where: { ($0["concepts"] as? [[String: Any]])?.isEmpty != false }) {
            result.refused.append("a @map needs @stage sections, each with its @concept lines")
        } else if let data = try? JSONSerialization.data(withJSONObject: ["topic": mapTopic, "stages": stages], options: [.sortedKeys, .withoutEscapingSlashes]) {
            result.map = String(decoding: data, as: UTF8.self)
        }
    }

    // ── drafts: Show numbers them, and each carries the step its outcome is assigned
    if !drafts.isEmpty {
        if let open {
            let shared = sameAssignment(branches["hit"], branches["miss"])
            let sharedNext = shared ? drafts.compactMap({ $0["next"] as? [String: Any] }).first : nil
            for i in drafts.indices {
                guard drafts[i]["idea"] is String, !(drafts[i]["answer"] as? String ?? "").isEmpty else {
                    result.refused.append("draft \(i + 1) needs its answer under @draft and an @idea")
                    continue
                }
                let branch = branches[(drafts[i]["held"] as? Bool) == true ? "hit" : "miss"]
                guard let branch, let form = branch["form"] as? String, !showWrittenForms.contains(form) else {
                    drafts[i]["next"] = nil
                    continue
                }
                guard var next = drafts[i]["next"] as? [String: Any] ?? sharedNext else {
                    result.refused.append("draft \(i + 1) needs a @step after it: the \(form) step for \(branch["concept"] ?? "?")")
                    continue
                }
                next["id"] = "next"
                stamp(&next, with: branch)
                checked(next)
                drafts[i]["next"] = next
            }
            steps[open]["drafts"] = drafts
        } else {
            result.refused.append("@draft came for no open step")
        }
    }

    // ── evidence: the step's own row is Show's, from the judge's reading of the prediction and the tutor's of the explanation
    let rung = open.flatMap { steps[$0]["form"] as? String } == "recall" ? "recall" : nil
    if let open, result.finished, let concept = steps[open]["concept"] as? String, !concept.isEmpty,
       let level = steps[open]["level"] as? String, !level.isEmpty {
        let answer = loadAnswers(path)[stepID!]
        guard let prediction = answer?.verdict ?? verdicts["prediction"] else {
            result.refused.append("there was no judge reading, so give @prediction held or revised too")
            return result
        }
        guard let explanation = verdicts["explanation"] else {
            result.refused.append("@explanation held or revised is needed: it decides the step's evidence row with the judge's reading")
            return result
        }
        let hit = prediction == "held" && explanation == "held"
        var row: [String: Any] = ["concept": concept, "level": level, "credit": "unaided", "outcome": hit ? "hit" : "miss"]
        if let confidence = answer?.confidence { row["confidence"] = confidence }
        if let via = steps[open]["via"] as? String { row["via"] = via }
        if hit {
            row["note"] = "held: " + String((answer?.parts["explain"] ?? "").prefix(160))
        } else {
            guard let misconception = verdicts["misconception"], let contrast = verdicts["contrast"] else {
                result.refused.append("a miss needs @misconception (what they believe) and @contrast (the same situation with one thing changed)")
                return result
            }
            row["note"] = misconception
            row["contrast"] = contrast
        }
        if told.contains(where: { $0["concept"] as? String == concept && $0["level"] as? String == level }) {
            result.refused.append("the step's own row (\(concept) at \(level)) is Show's to write; @evidence is for other concepts the answer showed")
        }
        told.insert(row, at: 0)
    }
    for var row in told {
        if let rung { row["rung"] = rung }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) {
            result.evidence.append(String(decoding: data, as: UTF8.self))
        }
    }

    guard result.refused.isEmpty else { return result }
    raw["steps"] = steps
    raw["notes"] = notes
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    return result
}
