import AppKit

/// The Learn stage: a format-2 session one step at a time. Only the current phase's input exists — the
/// prediction, then (after the reveal has played) the explanation — so nothing can be asked out of turn.
extension TutorController {
    static let stageTimeline: CGFloat = 350
    static let stagePanel: CGFloat = 210
    static let stageBeat: TimeInterval = 0.9

    /// The step on screen: one looked back at, else the one the learner is on, else the last (the tutor owes the next).
    func stagedStep(_ session: TutorSession) -> TutorStep? {
        stageViewing.flatMap { id in session.steps.first { $0.id == id } } ?? currentStep(session, answers) ?? session.steps.last
    }

    func rebuildStage(_ session: TutorSession) {
        stagePlayer?.invalidate()
        stagePlayer = nil
        viewController.splitViewItems.first?.isCollapsed = true
        composerBar?.isHidden = !stageAsking
        title = session.title
        subtitle = ""
        onTitleChange?()
        let width = Self.column
        func add(_ view: NSView, after gap: CGFloat) {
            column.addArrangedSubview(view)
            column.setCustomSpacing(gap, after: view)
        }
        let strip = stationStrip(session, concept: stagedStep(session)?.concept ?? "")
        if let strip { add(strip, after: 28) }
        let finished = path.map { (TutorPolicy.raw($0)["assigned"] as? [String: Any])?["form"] as? String == "done" } ?? false
        guard let step = stagedStep(session) else {
            add(stageQuiet(agent?.isBusy == true ? "The tutor is writing the first step." : "No steps yet."), after: 0)
            refreshAgentRow()
            return
        }
        let current = currentStep(session, answers)
        let looking = step.id != current?.id
        let answer = answers[step.id]
        let phase = stepPhase(step, answer)
        let problems = looking ? [] : stepProblems(step, answer)

        let header = tutorText(renderer.tutorInline(step.title, font: .systemFont(ofSize: 21, weight: .bold)), width: width)
        focusRungView = strip ?? header
        add(header, after: 4)
        var tag = [step.conceptName ?? step.concept.flatMap { $0.isEmpty ? nil : LearnDue.name($0) } ?? step.station,
                   step.form.flatMap { TutorPolicy.formNames[$0] } ?? (step.isInvent ? "invent" : "predict")].compactMap { $0 }.joined(separator: " · ")
        if looking, current != nil || phase != .done { tag += " · earlier step — ⌥⌘] comes back" }
        add(smallCaps(tag), after: 18)
        add(tutorText(renderer.tutorMarkdown(step.setup), width: width), after: 20)
        if step.isSingle { return rebuildSingle(session, step, looking: looking, finished: finished, add: add) }

        let predicted = phase != .predict
        let reveal = predicted ? step.reveal : nil
        let total = reveal?.frames.count ?? 0
        if predicted, step.reveal == nil { stageAwaiting.insert(step.id) }
        // a reveal plays once, when it arrives while the learner waits for it; reopening a session shows it whole
        let animate = !looking && stageAwaiting.contains(step.id) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let played = reveal == nil ? 0 : animate ? min(stagePlayed[step.id] ?? 0, total) : total
        add(stage(step, revealed: Array((reveal?.frames ?? []).prefix(played))), after: 26)

        if !problems.isEmpty {
            add(stageQuiet("This step doesn't fit Learn's shape, so the tutor was asked to fix it: \(problems.joined(separator: "; ")).", color: .systemRed), after: 16)
            let key = step.id + "|" + problems.joined(separator: "|")
            if !stageAsked.contains(key), agent?.isBusy != true, let path {
                stageAsked.insert(key)
                deliver("fix step \(step.id) in \(path): \(problems.joined(separator: "; "))")
            }
        }

        if !problems.isEmpty, phase == .predict || phase == .explain {
            for view in conversation(session, since: step) { add(view, after: 18) }
            return refreshAgentRow()   // nothing to answer until the tutor rewrites the step
        }
        add(tutorText(renderer.tutorInline(step.predict, font: .systemFont(ofSize: 14.5, weight: .semibold)), width: width), after: 8)
        if phase == .predict, !looking {
            addInput(step, part: "predict", add: add)
        } else {
            add(lockedAnswer(answer?.parts["predict"], level: answer?.confidence), after: 22)
        }
        if phase == .awaitingReveal, agent?.isBusy != true, agent?.failure == nil {
            add(stageQuiet("Waiting for the tutor's reveal."), after: 16)
        }

        let playedOut = reveal != nil && played >= total
        if let reveal, playedOut {
            if let verdict = answer?.verdict ?? step.verdict {
                add(smallCaps(verdict == "held" ? "your prediction held" : "your prediction was revised", color: verdict == "held" ? .secondaryLabelColor : .controlAccentColor), after: 6)
                if let why = answer?.why, !why.isEmpty { add(stageQuiet(why), after: 10) }
            }
            add(tutorText(renderer.tutorMarkdown(reveal.result), width: width), after: 24)
            if let explain = step.explain {
                add(tutorText(renderer.tutorInline(explain, font: .systemFont(ofSize: 14.5, weight: .semibold)), width: width), after: 8)
                if phase == .explain, !looking {
                    addInput(step, part: "explain", add: add)
                } else {
                    add(lockedAnswer(answer?.parts["explain"], level: nil), after: 22)
                }
            }
        }
        if phase == .awaitingConsolidate, agent?.isBusy != true, agent?.failure == nil {
            add(stageQuiet("Waiting for the tutor."), after: 16)
        }
        if let idea = step.consolidate, phase == .done {
            add(smallCaps("the idea"), after: 6)
            add(tutorText(renderer.tutorMarkdown(idea), width: width), after: 22)
            if finished, current == nil { add(stageQuiet("That's the session."), after: 16) }
            if looking, current != nil {
                let next = NSButton(title: "Next step", target: self, action: #selector(stageNext))
                next.bezelStyle = .rounded
                next.toolTip = "⌘↩"
                add(next, after: 22)
            }
        }
        for view in conversation(session, since: step) { add(view, after: 18) }
        refreshAgentRow()

        if let reveal, animate, played < reveal.frames.count, !problems.contains(where: { $0.hasPrefix("the reveal") }) {
            let id = step.id
            stagePlayer = Timer.scheduledTimer(withTimeInterval: Self.stageBeat, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.stagePlayed[id] = played + 1
                if played + 1 >= total { self.stageAwaiting.remove(id) }
                self.reload()
            }
        }
    }

    /// ⌘↩ on the stage: send the open phase's answer, or step on from a finished step.
    func sendStep() {
        guard let path, let session, session.isStaged else { return }
        if let viewing = stageViewing, let current = currentStep(session, answers), current.id != viewing {
            return stageNext()
        }
        guard let step = currentStep(session, answers) else { return NSSound.beep() }
        let part: String
        switch stepPhase(step, answers[step.id]) {
        case .predict: part = "predict"
        case .explain where !stageAwaiting.contains(step.id): part = "explain"
        default: return NSSound.beep()
        }
        let text = (drafts[step.id]?[part] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return showHint("Write your answer first.") }
        let level = confidence[step.id]
        if part == "predict", level == nil, !step.isSingle {
            return showHint("Pick how sure you are first: ⌃1 Guessing · ⌃2 Fairly sure · ⌃3 Certain.")
        }
        var all = loadSidecar(path)
        let now = ISO8601DateFormatter().string(from: Date())
        var entry = all.answers[step.id] ?? TutorAnswer(parts: [:], confidence: nil, at: now)
        entry.parts[part] = text
        entry.at = now
        if part == "predict" { entry.confidence = level.map { confidenceLevels[$0].0 } }
        all.answers[step.id] = entry
        do {
            try writeSidecar(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your answer"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        drafts[step.id]?[part] = nil
        if part == "predict" { confidence[step.id] = nil }
        if step.isSingle {
            saveDrafts()
            reload()
            return sendSingle(step, text: text, path: path)
        }
        if part == "explain" { stageViewing = step.id }   // stay on it for the idea, until the learner steps on
        saveDrafts()
        guard part == "explain" else {
            // the reveal is sealed in the step: it plays now, and the fast judge reads the prediction while it does
            stageAwaiting.insert(step.id)
            reload()
            TutorJudge.judge(path: path, stepID: step.id) { [weak self] in
                guard let self else { return }
                self.reload()
                // a matched draft already holds the plan; otherwise the tutor plans while the learner works out the explanation
                if loadAnswers(path)[step.id]?.draft == nil {
                    self.deliver(stagedBrief("tutor predicted", path: path, step: step.id) + "\nReply with only @plan.")
                }
            }
            return
        }
        reload()
        deliver(stagedBrief("tutor explained", path: path, step: step.id))
    }

    /// Recall goes to the tutor to be read against the topic; the card is the learner's own sentence, saved straight to the graph.
    private func sendSingle(_ step: TutorStep, text: String, path: String) {
        guard step.form == "card" else {
            return deliver("tutor recalled: \(path) step \(step.id)\nwhat they know: \(text)")
        }
        if let concept = step.concept, !concept.isEmpty {
            do {
                _ = try TutorPolicy.learn(["restate", concept, text])
            } catch {
                showHint("Couldn't save the card: \(error.localizedDescription)")
            }
        }
        TutorAgent.agent(for: path).advanceStaged()
        reload()
    }

    @objc func stageNext() {
        stageViewing = nil
        stageAsking = false
        reload(forceScroll: true)
        focusFirstField()
    }

    /// ⌥⌘[ and ⌥⌘]: look at the step before or after the one on screen; past the learner's own step comes back to it.
    func stageLook(_ delta: Int) {
        guard let session, session.isStaged, let shown = stagedStep(session),
              let i = session.steps.firstIndex(where: { $0.id == shown.id }) else { return NSSound.beep() }
        let target = i + delta
        guard session.steps.indices.contains(target) else { return NSSound.beep() }
        let id = session.steps[target].id
        stageViewing = id == currentStep(session, answers)?.id ? nil : id
        reload(forceScroll: true)
    }

    /// ⌘L: the one place to ask the tutor something, shown only when asked for.
    func stageAsk() {
        stageAsking = true
        composerBar?.isHidden = false
        window?.makeFirstResponder(composer)
    }

    private func addInput(_ step: TutorStep, part: String, add: (NSView, CGFloat) -> Void) {
        let field = AnswerField(partID: part, text: drafts[step.id]?[part] ?? "", width: Self.column, editable: true)
        field.ruled = true
        field.delegate = self
        fields.append(field)
        add(field, 14)
        if part == "predict", !step.isSingle {
            let line = confidenceLine(confidence[step.id])
            confidenceLabel = line
            add(line, 8)
        } else {
            add(stageQuiet("⌘↩ sends", color: .tertiaryLabelColor), 8)
        }
        let note = stageQuiet("")
        note.isHidden = true
        hint = note
        add(note, 0)
    }

    /// How sure the learner is, as one quiet line: the chosen level in full weight, the keys beside it.
    func confidenceLine(_ chosen: Int?) -> NSTextField {
        let line = NSMutableAttributedString()
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
        for (i, level) in confidenceLevels.enumerated() {
            if i > 0 { line.append(NSAttributedString(string: "   ", attributes: quiet)) }
            line.append(NSAttributedString(string: "⌃\(i + 1) ", attributes: quiet))
            line.append(NSAttributedString(string: level.1, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: chosen == i ? .semibold : .regular),
                .foregroundColor: chosen == i ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        }
        line.append(NSAttributedString(string: chosen == nil ? "      how sure, then ⌘↩" : "      ⌘↩ sends", attributes: quiet))
        return NSTextField(labelWithAttributedString: line)
    }

    /// A one-answer step: recall at the opening (the tutor's reading of it follows), the card at the close.
    private func rebuildSingle(_ session: TutorSession, _ step: TutorStep, looking: Bool, finished: Bool, add: (NSView, CGFloat) -> Void) {
        let answer = answers[step.id]
        let phase = stepPhase(step, answer)
        add(tutorText(renderer.tutorInline(step.predict, font: .systemFont(ofSize: 14.5, weight: .semibold)), width: Self.column), 8)
        if phase == .predict, !looking {
            addInput(step, part: "predict", add: add)
        } else {
            add(lockedAnswer(answer?.parts["predict"], level: nil), 22)
        }
        if phase == .awaitingConsolidate, agent?.failure == nil { add(stageQuiet("The tutor is reading what you said."), 16) }
        if let idea = step.consolidate, step.form == "recall" {
            add(smallCaps("what you have, what's missing"), 6)
            add(tutorText(renderer.tutorMarkdown(idea), width: Self.column), 22)
        }
        if step.form == "card", phase == .done {
            add(stageQuiet(finished ? "Saved as your sentence for \(step.conceptName ?? LearnDue.name(step.concept ?? "")). That's the session." : "Saving."), 16)
        }
        for view in conversation(session, since: step) { add(view, 18) }
        refreshAgentRow()
    }

    /// The stations as one quiet line: the current one in full weight, done ones dimmed.
    private func stationStrip(_ session: TutorSession, concept: String) -> NSView? {
        // derived from the graph for a session with a topic; stored only in sessions from before stations were derived
        let topic = path.flatMap { (TutorPolicy.raw($0)["scope"] as? [String: Any])?["topic"] as? String }
        guard let stations = topic.flatMap({ StationCache.stations(topic: $0, concept: concept) }) ?? session.stations, !stations.isEmpty else { return nil }
        let line = NSMutableAttributedString()
        for (i, station) in stations.enumerated() {
            if i > 0 { line.append(NSAttributedString(string: "   ·   ", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.quaternaryLabelColor])) }
            let current = station.state == "current"
            line.append(NSAttributedString(string: station.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: current ? .semibold : .regular),
                .foregroundColor: current ? NSColor.labelColor : station.state == "done" ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]))
        }
        return tutorText(line, width: Self.column)
    }

    /// The timeline beside the watched state. The setup's frames run to the playhead; revealed frames follow it in the accent color,
    /// and the state panel marks what the newest frame changed.
    private func stage(_ step: TutorStep, revealed: [StepFrame]) -> NSView {
        let rows = step.rows
        let timelineWidth = rows.isEmpty ? Self.column : Self.stageTimeline
        let frames = step.frames + revealed
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let gutter = min(140, ceil((step.frames + (step.reveal?.frames ?? [])).map { ($0.t as NSString).size(withAttributes: [.font: timeFont]).width }.max() ?? 0) + 14)
        let timeline = NSStackView()
        timeline.orientation = .vertical
        timeline.alignment = .leading
        timeline.spacing = 10
        func row(_ frame: StepFrame, accent: Bool) -> NSView {
            let time = NSTextField(wrappingLabelWithString: frame.t)
            time.font = timeFont
            time.textColor = accent ? .controlAccentColor : .secondaryLabelColor
            time.translatesAutoresizingMaskIntoConstraints = false
            time.widthAnchor.constraint(equalToConstant: gutter).isActive = true
            let event = tutorText(renderer.tutorInline(frame.event, font: renderer.base), width: timelineWidth - gutter - 8)
            let line = NSStackView(views: [time, event])
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 8
            return line
        }
        step.frames.forEach { timeline.addArrangedSubview(row($0, accent: false)) }
        let playhead = smallCaps(revealed.isEmpty ? "▸ predict from here" : "▸ what happened", color: .controlAccentColor)
        timeline.addArrangedSubview(playhead)
        revealed.forEach { timeline.addArrangedSubview(row($0, accent: true)) }
        guard !rows.isEmpty else { return timeline }

        let state = stepState(frames, through: frames.count)
        let changed = Set(revealed.last?.state.keys.map { $0 } ?? [])
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 6
        panel.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.addArrangedSubview(smallCaps(revealed.isEmpty ? "state" : "state now"))
        for key in rows {
            let name = NSTextField(labelWithString: key)
            name.font = .systemFont(ofSize: 11.5)
            name.textColor = .secondaryLabelColor
            let value = NSTextField(wrappingLabelWithString: state[key] ?? "—")
            value.font = .monospacedSystemFont(ofSize: 12.5, weight: changed.contains(key) ? .semibold : .regular)
            value.textColor = changed.contains(key) ? .controlAccentColor : .labelColor
            value.preferredMaxLayoutWidth = Self.stagePanel - 24
            let pair = NSStackView(views: [name, value])
            pair.orientation = .vertical
            pair.alignment = .leading
            pair.spacing = 1
            panel.addArrangedSubview(pair)
        }
        let box = StatePanel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: box.leadingAnchor), panel.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            panel.topAnchor.constraint(equalTo: box.topAnchor), panel.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: Self.stagePanel),
        ])
        // pinned to the rows' own height: beside a taller timeline the stack would otherwise stretch it and spread the rows
        box.heightAnchor.constraint(equalToConstant: panel.fittingSize.height).isActive = true
        let both = NSStackView(views: [timeline, box])
        both.orientation = .horizontal
        both.alignment = .top
        both.spacing = Self.column - Self.stageTimeline - Self.stagePanel
        return both
    }

    private func lockedAnswer(_ text: String?, level: String?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let level = confidenceLevels.first(where: { $0.0 == level })?.1 { stack.addArrangedSubview(smallCaps(level)) }
        stack.addArrangedSubview(AnswerField(partID: "locked", text: text ?? "—", width: Self.column, editable: false))
        return stack
    }

    /// What the learner and the tutor said to each other while this step was the open one.
    private func conversation(_ session: TutorSession, since step: TutorStep) -> [NSView] {
        guard let i = session.steps.firstIndex(where: { $0.id == step.id }) else { return [] }
        let start = i == 0 ? Date.distantPast : answers[session.steps[i - 1].id].flatMap { isoDate($0.at) } ?? .distantPast
        let end = i + 1 < session.steps.count ? answers[step.id].flatMap { isoDate($0.at) } ?? .distantFuture : .distantFuture
        var items: [(Date, NSView)] = []
        for message in sidecar.messages {
            guard let at = isoDate(message.at), at > start, at <= end else { continue }
            let p = NSMutableParagraphStyle()
            p.alignment = .right
            items.append((at, tutorText(NSAttributedString(string: message.text, attributes: [.font: inkFont, .foregroundColor: inkColor, .paragraphStyle: p]), width: Self.column)))
        }
        // the opening map is the tutor's plan, not part of the step: the station strip already says where this goes
        let firstSaid = sidecar.messages.compactMap { isoDate($0.at) }.min() ?? .distantFuture
        let map = (session.notes ?? []).first.flatMap { isoDate($0.at) }.flatMap { $0 < firstSaid ? $0 : nil }
        for note in session.notes ?? [] {
            guard let at = isoDate(note.at), at > start, at <= end, at != map else { continue }
            items.append((at, tutorText(renderer.tutorMarkdown(note.text), width: Self.column)))
        }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The tutor's reply as it streams: the idea or the note in place, never the raw sections.
    func stagedPreview(_ text: String) -> NSView? {
        guard let live = tutorSections(text).last(where: { $0.name == "consolidate" || $0.name == "note" }), !live.body.isEmpty else { return nil }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        if live.name == "consolidate" { stack.addArrangedSubview(smallCaps("the idea")) }
        stack.addArrangedSubview(tutorText(renderer.tutorMarkdown(live.body), width: Self.column))
        return stack
    }

    private func smallCaps(_ text: String, color: NSColor = .tertiaryLabelColor) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color, .kern: 0.6,
        ]))
    }

    private func stageQuiet(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.column
        return label
    }
}

/// A staged message with the learner's answers in it, so the tutor can reply without reading a file first.
func stagedBrief(_ kind: String, path: String, step id: String) -> String {
    let answer = loadAnswers(path)[id]
    let level = answer?.confidence.map { raw in "confidence \(raw): \(confidenceLevels.first { $0.0 == raw }?.1 ?? raw)" } ?? "no confidence given"
    var lines = ["\(kind): \(path) step \(id)", "prediction (\(level)): \(answer?.parts["predict"] ?? "")"]
    if let verdict = answer?.verdict { lines.append("judge: \(verdict) — \(answer?.why ?? "")") } else { lines.append("judge: no reading") }
    if let draft = answer?.draft {
        let answered = (try? loadTutorSession(path))?.steps.first { $0.id == id }?.drafts?.first { $0.id == draft }?.answer ?? ""
        lines.append("matched draft: \(draft) — \(answered)")
    } else if (try? loadTutorSession(path))?.steps.first(where: { $0.id == id })?.drafts != nil {
        lines.append("matched draft: none")
    }
    if let explained = answer?.parts["explain"] { lines.append("explanation: \(explained)") }
    return lines.joined(separator: "\n")
}

/// The state panel's ground: a rounded fill exactly as tall as its rows, drawn so it follows the appearance.
final class StatePanel: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 12, width: 1, height: max(0, bounds.height - 24)).fill()
    }
}
