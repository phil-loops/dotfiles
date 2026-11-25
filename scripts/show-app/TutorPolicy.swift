import Foundation
import CanopyCore

/// Where a staged session goes next is decided by `learn next` from the learner's evidence, never by the tutor:
/// Show asks it after every finished step, writes the stations and the assignment into the session file, and then
/// posts the step itself (recall, the card, a draft written for exactly this outcome) or asks the tutor to write it.
enum TutorPolicy {
    /// The words for each form, as the step's tag shows it.
    static let formNames = ["recall": "what you know", "worked": "worked example", "predict": "predict", "contrast": "contrast",
                            "explain": "predict and explain", "transfer": "transfer", "critique": "find the flaw", "card": "your card"]

    /// The session's id in the graph's evidence rows: the file's name.
    static func sessionID(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func raw(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
    }

    static func write(_ raw: [String: Any], _ path: String) throws {
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// `--topic <id>` or `--concept <id>`, from the session's scope.
    static func scopeArguments(_ raw: [String: Any]) -> [String]? {
        let scope = raw["scope"] as? [String: Any] ?? [:]
        if let topic = scope["topic"] as? String, !topic.isEmpty { return ["--topic", topic] }
        if let concept = scope["concept"] as? String, !concept.isEmpty { return ["--concept", concept] }
        return nil
    }

    /// What the session has posed so far, in order, as `learn next --asked` reads it.
    static func asked(_ raw: [String: Any]) -> [[String: String]] {
        (raw["steps"] as? [[String: Any]] ?? []).map { step in
            ["concept", "form", "level"].reduce(into: [:]) { $0[$1] = step[$1] as? String ?? "" }
        }
    }

    /// Runs `learn` and returns its stdout, or throws with its stderr.
    static func learn(_ arguments: [String]) throws -> Data {
        let process = Zsh.process("exec \"$0\" \"$@\"", [LearnDue.script] + arguments)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let why = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "learn", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: why, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return data
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// The next step for the session in `raw`: `learn next`'s object.
    static func next(_ raw: [String: Any], path: String) throws -> [String: Any] {
        guard let scope = scopeArguments(raw) else { throw NSError(domain: "learn", code: 1, userInfo: [NSLocalizedDescriptionKey: "the session has no topic yet"]) }
        let data = try learn(["next"] + scope + ["--session", sessionID(path), "--asked", json(asked(raw))])
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// The next step either way the open step lands: {"hit": …, "miss": …}. `raw` must not hold the step yet.
    static func branches(_ raw: [String: Any], step: [String: Any], path: String) throws -> [String: Any] {
        guard let scope = scopeArguments(raw) else { return [:] }
        let posed = ["concept", "form", "level"].reduce(into: [String: String]()) { $0[$1] = step[$1] as? String ?? "" }
        let data = try learn(["next"] + scope + ["--session", sessionID(path), "--asked", json(asked(raw)), "--branch", json(posed)])
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// An assignment in the words the tutor writes a step from.
    static func brief(_ a: [String: Any]) -> String {
        let form = a["form"] as? String ?? ""
        if showWrittenForms.contains(form) { return "Show writes it itself (\(formNames[form] ?? form)); this answer needs no next step" }
        var parts = ["form \(form)", "concept \(a["concept"] ?? "") — \(a["name"] ?? ""): \(a["statement"] ?? "")", "level \(a["level"] ?? "")"]
        if let via = a["via"] as? String, !via.isEmpty { parts.append("through the analog \(via)") }
        if let contrast = a["contrast"] as? String, !contrast.isEmpty { parts.append("the contrast to pose: \(contrast)") }
        if let missed = a["misconception"] as? String, !missed.isEmpty { parts.append("the misconception it answers: \(missed)") }
        return parts.joined(separator: " · ") + " (why: \(a["why"] ?? ""))"
    }

    /// A step Show writes itself: free recall at a topic's opening, the card at its close.
    static func writtenStep(_ a: [String: Any], id: String, title: String) -> [String: Any] {
        let form = a["form"] as? String ?? ""
        if form == "recall" {
            return ["id": id, "form": "recall", "concept": "", "level": "", "title": "What you already know", "frames": [],
                    "setup": "Before anything is taught, say everything you know about **\(title)**: what it does, how, why, and where it breaks. Rough is fine. What you leave out matters as much as what you say.",
                    "predict": "What do you know about it?"]
        }
        let name = a["name"] as? String ?? ""
        return ["id": id, "form": "card", "concept": a["concept"] ?? "", "conceptName": name, "level": "", "title": "Your card", "frames": [],
                "setup": "One sentence to keep from this session about **\(name)**, in your own words, the way you'd say it to a teammate. It's what the next re-test shows you first.",
                "predict": "What goes on the card?"]
    }

    static func newID(_ steps: [[String: Any]]) -> String {
        let taken = Set(steps.compactMap { $0["id"] as? String })
        var n = steps.count + 1
        while taken.contains("s\(n)") { n += 1 }
        return "s\(n)"
    }
}

extension TutorAgent {
    /// When the session owes its next step and nobody has asked for it yet: ask `learn next`, write the stations and the
    /// assignment, then post the step (Show's own forms, or the matched draft written for this outcome) or ask the tutor for it.
    func advanceStaged() {
        var raw = TutorPolicy.raw(sessionPath)
        guard raw["assigned"] == nil, let session = try? loadTutorSession(sessionPath), session.isStaged,
              currentStep(session, loadAnswers(sessionPath)) == nil, TutorPolicy.scopeArguments(raw) != nil else { return }
        let next: [String: Any]
        do {
            next = try TutorPolicy.next(raw, path: sessionPath)
        } catch {
            failure = "learn next couldn't pick the next step: \(error.localizedDescription)"
            onChange?()
            return
        }
        if let stations = next["stations"] as? [[String: Any]], !stations.isEmpty { raw["stations"] = stations }
        var steps = raw["steps"] as? [[String: Any]] ?? []
        let form = next["form"] as? String ?? ""
        let id = TutorPolicy.newID(steps)
        var posted: [String: Any]?
        if form == "done" {
            raw["assigned"] = next
        } else if showWrittenForms.contains(form) {
            posted = TutorPolicy.writtenStep(next, id: id, title: session.title)
        } else if var draft = Self.draftedNext(steps.last, matched: loadAnswers(sessionPath)[steps.last?["id"] as? String ?? ""]?.draft, for: next) {
            // the tutor wrote this step for exactly this outcome while the learner was still reading
            draft["id"] = id
            posted = draft
        } else {
            raw["assigned"] = next
        }
        if var step = posted {
            if !showWrittenForms.contains(form) { step["branches"] = try? TutorPolicy.branches(raw, step: step, path: sessionPath) }
            steps.append(step)
            raw["steps"] = steps
            posted = step
        }
        do {
            try TutorPolicy.write(raw, sessionPath)
        } catch {
            failure = "Couldn't write the next step into \(sessionPath): \(error)"
            onChange?()
            return
        }
        if let step = posted, !showWrittenForms.contains(form) {
            anticipate(step)
        } else if raw["assigned"] != nil, form != "done" {
            send("tutor step: \(sessionPath)\nWrite the next step: \(TutorPolicy.brief(next)).\nReply with only @step.")
        }
        onChange?()
    }

    /// The next step a finished step's drafts already hold for `next`: the judge-matched draft's, tailored to that answer,
    /// or, when either outcome led to the same step, the one draft that carries it.
    static func draftedNext(_ step: [String: Any]?, matched: String?, for next: [String: Any]) -> [String: Any]? {
        guard let step, let drafts = step["drafts"] as? [[String: Any]] else { return nil }
        let nexts = drafts.compactMap { $0["next"] as? [String: Any] }.filter { sameAssignment($0, next) }
        if let matched, let own = drafts.first(where: { $0["id"] as? String == matched })?["next"] as? [String: Any], sameAssignment(own, next) { return own }
        let branches = step["branches"] as? [String: [String: Any]] ?? [:]
        return sameAssignment(branches["hit"], branches["miss"]) ? nexts.first : nil
    }

    /// Asks the tutor to draft the posted step's likely answers, each with the next step its outcome will be assigned.
    func anticipate(_ step: [String: Any]) {
        let branches = step["branches"] as? [String: Any] ?? [:]
        var lines = ["tutor anticipate: \(sessionPath) step \(step["id"] ?? "")"]
        let hit = branches["hit"] as? [String: Any], miss = branches["miss"] as? [String: Any]
        if sameAssignment(hit, miss), let hit {
            lines.append("Either way the answer lands, the next step is: \(TutorPolicy.brief(hit)). Write it once, as the first draft's next; every other draft's next is null.")
        } else {
            if let hit { lines.append("If the answer holds, the next step is: \(TutorPolicy.brief(hit))") }
            if let miss { lines.append("If it misses, the next step is: \(TutorPolicy.brief(miss))") }
        }
        lines.append("Reply with only @drafts.")
        send(lines.joined(separator: "\n"))
    }

    /// Writes a tutor-written step's branches before asking for its drafts.
    func branchAndAnticipate(_ id: String) {
        var raw = TutorPolicy.raw(sessionPath)
        var steps = raw["steps"] as? [[String: Any]] ?? []
        guard let i = steps.firstIndex(where: { $0["id"] as? String == id }) else { return }
        var before = raw
        before["steps"] = Array(steps[..<i])
        if let branches = try? TutorPolicy.branches(before, step: steps[i], path: sessionPath) {
            steps[i]["branches"] = branches
            raw["steps"] = steps
            try? TutorPolicy.write(raw, sessionPath)
        }
        anticipate(steps[i])
    }
}
