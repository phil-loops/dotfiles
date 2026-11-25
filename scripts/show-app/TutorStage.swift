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
        if let strip = stationStrip(session) { add(strip, after: 28) }
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
        focusRungView = header
        add(header, after: 4)
        var tag = [step.station, step.isInvent ? "invent" : "predict"].compactMap { $0 }.joined(separator: " · ")
        if looking, current != nil || phase != .done { tag += " · earlier step — ⌥⌘] comes back" }
        add(smallCaps(tag), after: 18)
        add(tutorText(renderer.tutorMarkdown(step.setup), width: width), after: 20)

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
            if let verdict = step.verdict {
                add(smallCaps(verdict == "held" ? "your prediction held" : "your prediction was revised", color: verdict == "held" ? .secondaryLabelColor : .controlAccentColor), after: 6)
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
        if part == "predict", level == nil {
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
        if part == "explain" { stageViewing = step.id }   // stay on it for the idea, until the learner steps on
        saveDrafts()
        reload()
        deliver(part == "predict" ? "tutor predicted: \(path) step \(step.id)" : "tutor explained: \(path) step \(step.id)")
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
        field.delegate = self
        fields.append(field)
        add(field, 14)
        if part == "predict" {
            add(stageQuiet("How sure are you?  ⌃1 · ⌃2 · ⌃3"), 8)
            let control = NSSegmentedControl(labels: confidenceLevels.map(\.1), trackingMode: .selectOne, target: self, action: #selector(stagePicked))
            control.selectedSegment = confidence[step.id] ?? -1
            control.refusesFirstResponder = true
            picker = control
            add(control, 18)
        }
        let send = NSButton(title: part == "predict" ? "Send prediction" : "Send explanation", target: self, action: #selector(stageSend))
        send.bezelStyle = .rounded
        send.toolTip = "⌘↩"
        add(send, 8)
        let note = stageQuiet("")
        note.isHidden = true
        hint = note
        add(note, 0)
    }

    @objc private func stageSend() { sendStep() }
    @objc private func stagePicked(_ sender: NSSegmentedControl) { choose(confidence: sender.selectedSegment) }

    /// The stations as one quiet line: the current one in full weight, done ones dimmed.
    private func stationStrip(_ session: TutorSession) -> NSView? {
        guard let stations = session.stations, !stations.isEmpty else { return nil }
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
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 8
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = .zero
        box.contentView = panel
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.stagePanel).isActive = true
        box.setContentHuggingPriority(.required, for: .vertical)
        panel.setContentHuggingPriority(.required, for: .vertical)
        panel.distribution = .fill
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
        for note in session.notes ?? [] {
            guard let at = isoDate(note.at), at > start, at <= end else { continue }
            items.append((at, tutorText(renderer.tutorMarkdown(note.text), width: Self.column)))
        }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
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
