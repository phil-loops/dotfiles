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

}

extension TutorAgent {
    /// When the session owes its next step and nobody has asked for it yet: ask `learn next`, then post the step (Show's
    /// own forms, or the matched draft written for this outcome) or record the assignment and ask the tutor for it.
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
        var steps = raw["steps"] as? [[String: Any]] ?? []
        let form = next["form"] as? String ?? ""
        let id = newStepID(steps)
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
        if let step = posted {
            steps.append(step)
            raw["steps"] = steps
        }
        do {
            try TutorPolicy.write(raw, sessionPath)
        } catch {
            failure = "Couldn't write the next step into \(sessionPath): \(error)"
            onChange?()
            return
        }
        if form == "done" {
            // the session's evidence is all in the graph now: keep it, without anyone tending the file
            let message = "learning: \(TutorPolicy.sessionID(sessionPath))"
            DispatchQueue.global(qos: .utility).async { _ = try? TutorPolicy.learn(["commit", message]) }
        } else if posted != nil, !showWrittenForms.contains(form) {
            anticipate(id)
        } else if raw["assigned"] != nil, form != "done" {
            send("tutor step: \(sessionPath)\nWrite the next step: \(TutorPolicy.brief(next)).\nReply with only the @step and its sections.")
        }
        onChange?()
    }

    /// The next step the judge-matched draft of a finished step holds, when it's the one `learn next` now assigns.
    static func draftedNext(_ step: [String: Any]?, matched: String?, for next: [String: Any]) -> [String: Any]? {
        guard let matched, let drafts = step?["drafts"] as? [[String: Any]],
              let own = drafts.first(where: { $0["id"] as? String == matched })?["next"] as? [String: Any], sameAssignment(own, next) else { return nil }
        return own
    }

    /// What `learn next` assigns after step `id` if it holds and if it misses, from the graph as it is now.
    func branches(of id: String) -> [String: [String: Any]] {
        let raw = TutorPolicy.raw(sessionPath)
        let steps = raw["steps"] as? [[String: Any]] ?? []
        guard let i = steps.firstIndex(where: { $0["id"] as? String == id }) else { return [:] }
        var before = raw
        before["steps"] = Array(steps[..<i])
        return (try? TutorPolicy.branches(before, step: steps[i], path: sessionPath)) as? [String: [String: Any]] ?? [:]
    }

    /// Asks the tutor to draft step `id`'s likely answers, each with the next step its outcome will be assigned.
    func anticipate(_ id: String) {
        let branches = branches(of: id)
        var lines = ["tutor anticipate: \(sessionPath) step \(id)"]
        let hit = branches["hit"], miss = branches["miss"]
        if sameAssignment(hit, miss), let hit {
            lines.append("Either way the answer lands, the next step is: \(TutorPolicy.brief(hit)). Write it once, after the first draft that needs it.")
        } else {
            if let hit { lines.append("If the answer holds, the next step is: \(TutorPolicy.brief(hit))") }
            if let miss { lines.append("If it misses, the next step is: \(TutorPolicy.brief(miss))") }
        }
        lines.append("Reply with only the @draft sections.")
        send(lines.joined(separator: "\n"))
    }
}

/// A topic's stations, derived from the graph and cached by everything they're computed from: the graph file as it is,
/// the topic and the concept on screen.
enum StationCache {
    private static var cached: (key: String, value: [TutorSession.Station])?

    static var graphPath: String {
        ProcessInfo.processInfo.environment["LEARNING_GRAPH"] ?? ("~/.dotfiles/learning/graph.json" as NSString).expandingTildeInPath
    }

    static func stations(topic: String, concept: String) -> [TutorSession.Station]? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: graphPath)
        let stamp = "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\(attributes?[.size] ?? 0)"
        let key = [graphPath, stamp, topic, concept].joined(separator: "|")
        if let cached, cached.key == key { return cached.value }
        guard let data = try? TutorPolicy.learn(["stations", "--topic", topic] + (concept.isEmpty ? [] : ["--concept", concept])),
              let value = try? JSONDecoder().decode([TutorSession.Station].self, from: data) else { return nil }
        cached = (key, value)
        return value
    }
}
