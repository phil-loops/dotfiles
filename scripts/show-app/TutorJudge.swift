import Foundation
import CanopyCore

/// The fast judge: reads a prediction against the step's sealed reveal while the reveal plays, so the learner
/// never waits on the tutor between predicting and explaining. A tool-less Haiku call; its reading is stored
/// on the answer, and the tutor checks it when the explanation arrives.
enum TutorJudge {
    static let model = ProcessInfo.processInfo.environment["SHOW_JUDGE_MODEL"] ?? "haiku"

    static func prompt(_ step: TutorStep, prediction: String) -> String {
        let frames = (step.frames + (step.reveal?.frames ?? [])).map { "- \($0.t): \($0.event)" }.joined(separator: "\n")
        let likely = (step.drafts ?? []).map { "- \($0.id): \($0.answer)" }.joined(separator: "\n")
        let drafts = likely.isEmpty ? "" : "Likely answers drafted in advance:\n\(likely)\n"
        return """
        A learner predicted what a system would do. Judge only whether the prediction matches what happened.
        Setup: \(step.setup)
        Timeline:
        \(frames)
        What happened: \(step.reveal?.result ?? "")
        The question: \(step.predict)
        The learner's prediction: \(prediction)
        \(drafts)Reply with one JSON object and nothing else: {"verdict": "held" or "revised", "why": "one short sentence, addressed to the learner: what actually happens and the step in their reasoning that differs; credit only what they actually said; no praise", "draft": "the id of the likely answer the prediction amounts to, or null when none fits"}
        "held" means the prediction's claim about the behavior is right, even if worded loosely.
        """
    }

    /// Parses the judge's reply; nil when it isn't the promised object.
    static func reading(_ text: String) -> (verdict: String, why: String, draft: String?)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let verdict = object["verdict"] as? String, verdict == "held" || verdict == "revised" else { return nil }
        return (verdict, (object["why"] as? String) ?? "", object["draft"] as? String)
    }

    /// Judges `stepID`'s prediction off the main thread and writes the reading onto its answer; `done` runs on the main thread.
    static func judge(path: String, stepID: String, done: @escaping () -> Void) {
        guard let session = try? loadTutorSession(path), let step = session.steps.first(where: { $0.id == stepID }),
              let prediction = loadAnswers(path)[stepID]?.parts["predict"] else { return }
        let text = prompt(step, prediction: prediction)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let arguments = ["-p", "--model", model, "--tools", "", "--no-session-persistence", "--output-format", "json", "--", text]
            if let override = ProcessInfo.processInfo.environment["SHOW_JUDGE"] {
                process.executableURL = URL(fileURLWithPath: override)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: Zsh.path)
                process.arguments = Zsh.arguments("exec claude \"$@\"", ["claude"] + arguments)
            }
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var reply: String?
            if (try? process.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                reply = event?["result"] as? String
            }
            DispatchQueue.main.async {
                if let reading = reply.flatMap(reading), var sidecar = try? readSidecar(path), var answer = sidecar.answers[stepID] {
                    answer.verdict = reading.verdict
                    answer.why = reading.why
                    answer.draft = session.steps.first { $0.id == stepID }?.drafts?.contains { $0.id == reading.draft } == true ? reading.draft : nil
                    sidecar.answers[stepID] = answer
                    try? writeSidecar(sidecar, path)
                }
                done()
            }
        }
    }
}

extension TutorAgent {
    /// A staged tutor reads but never writes: Show writes what its reply's sections say.
    static let stagedTools = "Read,Grep,Glob,Bash(~/.dotfiles/scripts/learn:*),Bash(~/.dotfiles/scripts/sim-play:*)"

    /// The protocol for a format-2 session: the tutor answers in sections, Show checks and writes them.
    func stagedBootPrompt(_ answers: String) -> String {
        """
        You are the tutor for one Show Learn session, the file \(sessionPath). Teach by the tutor skill below.
        Show runs the session. What comes next is decided by `learn next` from the learner's evidence, not by you: Show tells you which step to write (its concept, the level it tests and its form) and you write it well. Show puts one step on screen at a time, asks only the question of the phase the learner is in, writes the session file itself (you never edit it) and records your evidence rows. Each message carries what you need; the session file and \(answers) are there to read if you must.
        Reply only in sections. Each opens with a line holding just its name; nothing outside a section is shown:
        @title — the session's name, one line
        @map — the opening only, for a topic the graph lacks: one JSON object for `learn map` (below)
        @topic — the opening only, instead of @map: the id of the graph topic this session is
        @note — markdown to the learner, only in reply to "learner says"
        @consolidate — 2–4 plain sentences assembling the idea, set beside what the learner said
        @step — the step Show asked for, a single JSON object (schema below)
        @drafts — a JSON list of the open step's likely answers (below)
        @fix — a corrected existing step, a single JSON object with the same id
        @plan — your own notes; never shown or written
        @evidence — one JSON object per line, each a row for `learn evidence` ({concept, level, credit, outcome, note, confidence, contrast, via})
        Messages:
        - The opening "/tutor <topic>": @title, then @topic when the graph below already has this topic, else @map: {"topic": {"id", "title", "source"}, "stages": [{"name", "concepts": [{"id", "name", "statement": "one line, the idea itself", "builds_on": [ids it needs], "analogs": [ids of the same idea elsewhere in the graph]}]}]}. Stages in teaching order, 2–4 of them, 2–4 concepts each; reuse existing concept ids wherever the idea is the same. Nothing else: be quick, the learner is waiting.
        - "tutor step: <file>" with the assignment: reply with only @step, written for exactly that concept, level and form.
        - "tutor anticipate: <file> step <id>" with the next step for a hit and for a miss: reply with only @drafts: 2–3 likely answers (the right one and the traps the step was built to spring), each {"id": "a1", "answer": "what the learner would say, in a line", "held": true|false, "misconception": "what a wrong answer shows, or null", "idea": "the draft consolidation for a learner who answered this", "next": the complete sealed step its outcome is assigned (held → the hit's, else the miss's), or null when Show writes that step itself}.
        - "tutor recalled: <file> step <id>" with what the learner said they know: @consolidate (what they have and what's missing, plainly; don't teach yet), then @evidence: a row per concept of the topic they spoke to: level predict when they said what happens, explain when they said why; credit unaided; outcome miss, with the misconception in the note, when what they said is wrong. A concept they never mentioned gets no row.
        - "tutor predicted: <file> step <id>" (no draft matched): reply with only @plan.
        - "tutor explained: <file> step <id>" (the prediction, the judge's reading, the matched draft if any, and the explanation): @consolidate FIRST (the learner reads it while you write the rest; with a matched draft, tailor its idea to their words), then @evidence: the step's own row (its concept at its level; a hit only if the prediction and the explanation both held; the confidence they gave; on a miss a note naming the misconception and a contrast: the same situation with one thing changed that separates it from the idea; on a transfer, via), plus a row for any other concept the answer showed.
        - "learner says: <text>": @note.
        - "fix step <id> in <file>: <problems>" or "Show refused your reply …": reply again with the corrected sections; Show wrote nothing from the refused reply.
        Forms (what the step is, given its concept and level):
        - worked: a concept the learner has never shown. The setup walks one complete run of the mechanism, start to end, nothing to guess; the frames are the same system with one thing changed, and predict asks about that variant.
        - predict: a cold situation; predict asks what the system does.
        - contrast: the situation the learner missed, with one thing changed (the contrast given, when there is one); the setup says plainly what differs from before.
        - explain: predict the behavior, then explain asks for the mechanism behind it.
        - transfer: the concept's situation set in the analog's world, so the same idea has to be recognized in other clothes.
        - critique: a design with a flaw, or two designs; predict asks where it breaks or which survives, and the reveal plays the failure.
        A step is sealed: you write its reveal and its explain question now, with the step, and Show keeps both hidden until the learner has predicted. The reveal is what the system does, which never depends on the guess; that's why it can be written first.
        Step: {"id": "s1", "title", "setup": "markdown: the concrete system and the one action", "watch": ["key", …], "frames": [{"t": "the time as a person says it, e.g. Tue 02:00 or 02:01:30", "event", "state": {"key": "value"}}], "predict": "one question", "reveal": {"frames": [ … ], "result": "one or two sentences: what happened", "source": "sim-play <scenario>, when it played the reveal"}, "explain": "one question", "consolidate": null}. Show stamps the concept, level and form on.
        - "frames" run up to the playhead, the moment just before what the learner predicts. Each frame's "state" names only the watched keys that moment changes; "watch" lists every key any frame sets (reveal frames too), in the order the panel shows them.
        - "predict" asks about one behavior with one question mark; "why" belongs to "explain". No "verdict": the judge gives it.
        - The reveal's frames continue the same timeline and keys. Where a `~/.dotfiles/scripts/sim-play` scenario plays the situation, take the reveal from it.

        ===== The tutor skill (~/.dotfiles/.claude/skills/tutor/SKILL.md) =====
        \(Self.read(("~/.dotfiles/.claude/skills/tutor/SKILL.md" as NSString).expandingTildeInPath))

        ===== The learner's state now (`learn state`) =====
        \(Self.learnState())
        """
    }

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(couldn't read \(path); read it yourself)"
    }

    /// The learner digest, read once at the opening so the tutor needn't spend tool calls on it.
    static func learnState() -> String {
        let process = Zsh.process("exec \"$0\" state", [LearnDue.script])
        var environment = ProcessInfo.processInfo.environment
        environment["LEARNING_MEMORY"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "(run `learn state` yourself)" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? "(run `learn state` yourself)"
    }
}

extension TutorAgent {
    /// Writes a finished staged reply through Show's checks. A refusal goes back to the tutor as the next turn, a few times at most.
    /// Then: the opening's map goes to the graph, the evidence is recorded, and a session owed its next step gets it.
    func applyStaged(_ text: String, message: String) {
        let head = message.components(separatedBy: "\n").first ?? message
        let stepID = head.range(of: #"step \S+$"#, options: .regularExpression).map { String(head[$0].dropFirst("step ".count)) }
        let applied: StagedApply
        do {
            applied = try applyStagedReply(text, path: sessionPath, stepID: stepID, now: ISO8601DateFormatter().string(from: Date()))
        } catch {
            failure = "Couldn't write the tutor's reply into \(sessionPath): \(error)"
            return
        }
        if !applied.refused.isEmpty {
            stagedRefusals += 1
            guard stagedRefusals <= 2 else {
                failure = "Show refused the tutor's reply three times in a row:\n" + applied.refused.joined(separator: "\n")
                return
            }
            queue.append(("Show refused your reply; nothing was written: \(applied.refused.joined(separator: "; ")). Reply again in full with the corrected sections.", false))
            return
        }
        stagedRefusals = 0
        if applied.map != nil || applied.topic != nil {
            do {
                let topic = try applied.map.map { String(decoding: try TutorPolicy.learn(["map", $0]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? applied.topic!
                var raw = TutorPolicy.raw(sessionPath)
                raw["scope"] = ["topic": topic]
                try TutorPolicy.write(raw, sessionPath)
            } catch {
                queue.append(("learn refused the topic (nothing recorded): \(error.localizedDescription). Reply with only the corrected @map, or @topic with an id the graph has.", false))
                return
            }
        }
        for id in applied.posted { branchAndAnticipate(id) }
        if !applied.evidence.isEmpty {
            var arguments = ["evidence", "[" + applied.evidence.joined(separator: ",") + "]", "--session", TutorPolicy.sessionID(sessionPath)]
            if let topic = (TutorPolicy.raw(sessionPath)["scope"] as? [String: Any])?["topic"] as? String { arguments += ["--topic", topic] }
            do {
                _ = try TutorPolicy.learn(arguments)
            } catch {
                queue.append(("learn refused your evidence rows (nothing recorded): \(error.localizedDescription). Reply with only @evidence, corrected.", false))
                return
            }
        }
        advanceStaged()
    }
}
