import Foundation
import CanopyCore

/// The fast judge: reads a prediction against the step's sealed reveal while the reveal plays, so the learner
/// never waits on the tutor between predicting and explaining. A tool-less Haiku call; its reading is stored
/// on the answer, and the tutor checks it when the explanation arrives.
enum TutorJudge {
    static let model = ProcessInfo.processInfo.environment["SHOW_JUDGE_MODEL"] ?? "haiku"

    static func prompt(_ step: TutorStep, prediction: String) -> String {
        let frames = (step.frames + (step.reveal?.frames ?? [])).map { "- \($0.t): \($0.event)" }.joined(separator: "\n")
        return """
        A learner predicted what a system would do. Judge only whether the prediction matches what happened.
        Setup: \(step.setup)
        Timeline:
        \(frames)
        What happened: \(step.reveal?.result ?? "")
        The question: \(step.predict)
        The learner's prediction: \(prediction)
        Reply with one JSON object and nothing else: {"verdict": "held" or "revised", "why": "one short sentence, addressed to the learner, naming where the prediction matched or went wrong; no praise"}
        "held" means the prediction's claim about the behavior is right, even if worded loosely.
        """
    }

    /// Parses the judge's reply; nil when it isn't the promised object.
    static func reading(_ text: String) -> (verdict: String, why: String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let verdict = object["verdict"] as? String, verdict == "held" || verdict == "revised" else { return nil }
        return (verdict, (object["why"] as? String) ?? "")
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
        You are the tutor for one Show Learn session, the file \(sessionPath). Teach by ~/.dotfiles/.claude/skills/tutor/SKILL.md; for an opening "re-test <concept>", by ~/.dotfiles/.claude/skills/retest/SKILL.md instead (`learn concept <id>` gives its history), one situation only.
        Show puts one step on screen at a time, asks the learner only the question of the phase they're in, and writes the session file itself. You never edit it: read it, and read the learner's answers in \(answers) (per step: "parts" with "predict" and "explain", "confidence", and "verdict" and "why", a fast judge's reading of the prediction against your reveal, which you check).
        Reply only in sections. Each opens with a line holding just its name; nothing outside a section is shown:
        @title — the session's name, one line
        @note — markdown to the learner: the opening map, or a reply to "learner says"
        @stations — a JSON list [{"name", "state": "done|current|todo"}], when it changes
        @consolidate — 2–4 plain sentences assembling the idea, set beside what the learner said
        @step — one new step, a single JSON object (schema below)
        @fix — a corrected existing step, a single JSON object with the same id
        @plan — your own notes for the next step; never shown or written
        @evidence — one JSON object per line, each a row for `learn evidence` ({concept or standard, level, credit, outcome, note, confidence, rung})
        Messages:
        - The opening ("/tutor <topic>" or "re-test <concept>"): @title (a short plain name for the session), @note (a short map), @stations, @step.
        - "tutor predicted: <file> step <id>" (with the prediction and the judge's reading): the learner is now writing their explanation. Reply with only @plan: a few lines on what the next step should test given this prediction. Show writes nothing from it; it's your head start.
        - "tutor explained: <file> step <id>" (with the prediction, the judge's reading and the explanation — everything you need, so don't read the answers file): write @consolidate FIRST — the learner reads it while you write the rest — then @evidence for the prediction and the explanation, @stations if a station is done, then @step: the next step, built from what they just said.
        - "learner says: <text>": @note.
        - "fix step <id> in <file>: <problems>" or "Show refused your reply …": reply again with the corrected sections; Show wrote nothing from the refused reply.
        A step is sealed: you write its reveal and its explain question now, with the step, and Show keeps both hidden until the learner has predicted. The reveal is what the system does, which never depends on the guess; that's why it can be written first.
        Step: {"id": "s1", "station", "title", "kind": "predict|invent", "setup": "markdown: the concrete system and the one action", "watch": ["key", …], "frames": [{"t": "the time as a person says it, e.g. Tue 02:00 or 02:01:30", "event", "state": {"key": "value"}}], "predict": "one question", "reveal": {"frames": [ … ], "result": "one or two sentences: what happened", "source": "sim-play <scenario>, when it played the reveal"}, "explain": "one question", "consolidate": null}
        - "frames" run up to the playhead, the moment just before what the learner predicts. Each frame's "state" names only the watched keys that moment changes; "watch" lists every key any frame sets (reveal frames too), in the order the panel shows them.
        - "predict" asks about one behavior with one question mark; "why" belongs to "explain". No "verdict": the judge gives it.
        - The reveal's frames continue the same timeline and keys. Where a `~/.dotfiles/scripts/sim-play` scenario plays the situation, take the reveal from it.
        """
    }
}

extension TutorAgent {
    /// Writes a finished staged reply through Show's checks. A refusal goes back to the tutor as the next turn, a few times at most.
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
        guard !applied.evidence.isEmpty else { return }
        let process = Zsh.process("exec \"$0\" evidence \"$1\"", [LearnDue.script, "[" + applied.evidence.joined(separator: ",") + "]"])
        var environment = ProcessInfo.processInfo.environment
        environment["LEARNING_MEMORY"] = environment["LEARNING_MEMORY"] ?? "1"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let why = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            queue.append(("learn refused your evidence rows (nothing recorded): \(why.trimmingCharacters(in: .whitespacesAndNewlines)). Reply with only @evidence, corrected.", false))
        }
    }
}
