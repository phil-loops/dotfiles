import AppKit

struct TutorSession: Decodable {
    let mode: String?
    let kind: String?
    let title: String
    let replyTo: String?
    let stations: [Station]?
    let due: [Due]?
    let rungs: [Rung]
    let agent: Agent?
    let notes: [Note]?

    struct Agent: Decodable {
        let session: String?
    }

    struct Note: Decodable {
        let at: String
        let text: String
    }

    /// Answers go to the session's own headless tutor, except in a file still driven by a `replyTo` terminal session.
    var usesAgent: Bool { agent != nil || replyTo == nil }

    struct Station: Decodable {
        let name: String
        let state: String
    }

    struct Due: Decodable {
        let concept: String
        let why: String?
    }
}

struct Rung: Decodable {
    let id: String
    let station: String?
    let title: String
    let situation: String?
    let ask: String
    let timeline: [Event]?
    let parts: [Part]?
    let reveal: Reveal?
    let verdicts: [String: String]?
    let followup: String?

    struct Event: Decodable {
        let t: String
        let event: String
    }

    struct Part: Decodable {
        let id: String
        let at: String?
        let ask: String?
    }

    enum Reveal: Decodable {
        case whole(String)
        case byPart([String: String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .whole(text)
            } else {
                self = .byPart(try container.decode([String: String].self))
            }
        }
    }

    /// The fields to answer: one per part, or the single part `_` when the rung has none.
    var answerParts: [Part] {
        guard let parts, !parts.isEmpty else { return [Part(id: "_", at: nil, ask: nil)] }
        return parts
    }

    var isPredict: Bool { ask == "predict" }

    func reveal(for part: String) -> String? {
        if case .byPart(let byPart) = reveal { return byPart[part] }
        return nil
    }

    var wholeReveal: String? {
        if case .whole(let text) = reveal { return text }
        return nil
    }
}

struct TutorAnswer: Codable {
    var parts: [String: String]
    var confidence: String?
    var at: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parts, forKey: .parts)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(at, forKey: .at)
    }
}

let tutorDirectory = (decksDirectory as NSString).appendingPathComponent("tutor")
let confidenceLevels = [("low", "Guessing"), ("medium", "Fairly sure"), ("high", "Certain")]

let inkColor = NSColor(name: "show.ink") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x8D / 255, green: 0xB3 / 255, blue: 0xF0 / 255, alpha: 1)
        : NSColor(srgbRed: 0x2F / 255, green: 0x5F / 255, blue: 0xB0 / 255, alpha: 1)
}

let inkFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 16)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 16) } ?? base
}()

func loadTutorSession(_ path: String) throws -> TutorSession {
    let session = try JSONDecoder().decode(TutorSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard (session.mode ?? session.kind) == "tutor" else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(path) is not a tutor session (needs \"mode\": \"tutor\")"])
    }
    return session
}

func isTutorFile(_ path: String) -> Bool {
    struct Mode: Decodable {
        let mode: String?
        let kind: String?
    }
    let file = try? JSONDecoder().decode(Mode.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    return (file?.mode ?? file?.kind) == "tutor"
}

func answersURL(_ sessionPath: String) -> URL {
    URL(fileURLWithPath: sessionPath).deletingPathExtension().appendingPathExtension("answers.json")
}

struct LearnerMessage: Codable {
    let at: String
    let text: String
}

/// The answers sidecar: one entry per answered rung, plus the learner's free messages under `messages`.
struct Sidecar {
    var answers: [String: TutorAnswer] = [:]
    var messages: [LearnerMessage] = []
}

func readSidecar(_ sessionPath: String) throws -> Sidecar {
    let url = answersURL(sessionPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return Sidecar() }
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    var sidecar = Sidecar()
    for (key, value) in raw {
        let data = try JSONSerialization.data(withJSONObject: value)
        if key == "messages" {
            sidecar.messages = try JSONDecoder().decode([LearnerMessage].self, from: data)
        } else {
            sidecar.answers[key] = try JSONDecoder().decode(TutorAnswer.self, from: data)
        }
    }
    return sidecar
}

func loadSidecar(_ sessionPath: String) -> Sidecar {
    (try? readSidecar(sessionPath)) ?? Sidecar()
}

func loadAnswers(_ sessionPath: String) -> [String: TutorAnswer] {
    loadSidecar(sessionPath).answers
}

func writeSidecar(_ sidecar: Sidecar, _ sessionPath: String) throws {
    let encoder = JSONEncoder()
    var raw: [String: Any] = [:]
    for (id, answer) in sidecar.answers {
        raw[id] = try JSONSerialization.jsonObject(with: encoder.encode(answer))
    }
    if !sidecar.messages.isEmpty {
        raw["messages"] = try JSONSerialization.jsonObject(with: encoder.encode(sidecar.messages))
    }
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: answersURL(sessionPath), options: .atomic)
}

func isoDate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

/// The Learn workspace's own tutor: one headless `claude -p` session per tutor file, one turn at a time, later sends queued.
final class TutorAgent {
    static var all: [String: TutorAgent] = [:]
    static let allowedTools = "Read,Edit,Write,Grep,Glob,Bash(~/.dotfiles/scripts/learn:*),Bash(~/.dotfiles/scripts/sim-play:*),Bash(date:*)"
    static let workingDirectory = ("~/.dotfiles" as NSString).expandingTildeInPath
    /// Passed through to the tutor when set, so a test can point `learn` at a scratch graph.
    static let passedEnvironment = ["LEARNING_GRAPH", "LEARNING_MEMORY"]

    static func agent(for sessionPath: String) -> TutorAgent {
        if let existing = all[sessionPath] { return existing }
        let agent = TutorAgent(sessionPath: sessionPath)
        all[sessionPath] = agent
        return agent
    }

    let sessionPath: String
    private var queue: [(message: String, boot: Bool)] = []
    private(set) var running: Process?
    private(set) var failure: String?
    private(set) var preview = ""
    var onChange: (() -> Void)?
    var onDelta: ((String) -> Void)?

    init(sessionPath: String) {
        self.sessionPath = sessionPath
    }

    var isBusy: Bool { running != nil || (!queue.isEmpty && failure == nil) }

    /// Queues a message for the tutor, minting its session the first time. A session Claude has never seen boots on this turn.
    func send(_ message: String) {
        if Self.sessionID(sessionPath) == nil, !mintSession() {
            failure = "Couldn't write agent.session into \(sessionPath)"
            onChange?()
            return
        }
        let booted = queue.contains(where: \.boot) || Self.sessionID(sessionPath).map(Self.hasTranscript) == true
        queue.append(booted ? (message, false) : (bootPrompt + "\n\nOpening message: " + message, true))
        startNext()
    }

    func retry() {
        failure = nil
        startNext()
    }

    static func sessionID(_ sessionPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (raw["agent"] as? [String: Any])?["session"] as? String
    }

    private func mintSession() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var agent = raw["agent"] as? [String: Any] ?? [:]
        agent["session"] = UUID().uuidString.lowercased()
        raw["agent"] = agent
        guard let out = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: sessionPath), options: .atomic)) != nil
    }

    /// Whether Claude already has this session's transcript, so the next turn resumes it instead of booting it.
    static func hasTranscript(_ session: String) -> Bool {
        let project = String(workingDirectory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ("~/.claude" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: "\(home)/projects/\(project)/\(session).jsonl")
    }

    private var bootPrompt: String {
        let answers = answersURL(sessionPath).path
        return """
        You are the tutor for one Show worksheet, the session file \(sessionPath). Teach by ~/.dotfiles/.claude/skills/tutor/SKILL.md; for an opening "re-test <concept>", by ~/.dotfiles/.claude/skills/retest/SKILL.md instead (`learn concept <id>` gives its history), one situation only.
        Every turn:
        - Reply only by editing the session file (Edit, or Write for a whole rewrite). Keep it valid JSON and leave "mode" and "agent" alone. The learner never sees your chat text, so keep it to a line.
        - One rung per turn: add at most one new rung, then stop.
        - The learner's answers and messages arrive in \(answers). Read it; never write it.
        - Record evidence after each answer with `~/.dotfiles/scripts/learn evidence '<json>'`, called by exactly that path, as is `~/.dotfiles/scripts/learn state`. Never touch the graph another way.
        - Show asks for confidence itself; don't ask for it in the rung.
        Messages: "tutor answer: <file> rung <id>" → set that rung's "reveal" and "verdicts", record evidence, append the next rung. "learner says: <text>" → append {"at": <`date -u +%Y-%m-%dT%H:%M:%SZ`>, "text": "<reply, markdown>"} to "notes". "learner wants station <name>" → make it the current station and append its first rung.
        Schema: {"mode": "tutor", "title", "stations": [{"name", "state": "done|current|todo"}], "rungs": [{"id": "r1", "station", "title", "situation": "markdown: concrete state, one action", "ask": "predict|explain|restate|invent", "timeline": [{"t": "0", "event"}], "parts": [{"id": "a", "at": "20", "ask"}], "reveal": null, "verdicts": {"a": "held|revised"}, "followup": null}], "notes": [], "agent": {…}}. "timeline" and "parts" are optional; a part with "at" sits on the timeline at that time; "reveal" is markdown, or {"<part id>": "markdown"}.
        """
    }

    private func startNext() {
        guard running == nil, failure == nil, let next = queue.first, let session = Self.sessionID(sessionPath) else {
            onChange?()
            return
        }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", "acceptEdits", "--allowedTools", Self.allowedTools]
        arguments += next.boot && !Self.hasTranscript(session) ? ["--session-id", session] : ["--resume", session]
        arguments += ["--add-dir", (sessionPath as NSString).deletingLastPathComponent, "--", next.message]
        let process = Process()
        let parent = ProcessInfo.processInfo.environment
        var exports = ""
        for name in Self.passedEnvironment {
            guard let value = parent[name] else { continue }
            exports += "export \(name)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'; "
        }
        if let override = ProcessInfo.processInfo.environment["SHOW_CLAUDE"] {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", exports + "export PATH=\"$HOME/.local/bin:$PATH\"; exec claude \"$@\"", "claude"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: Self.workingDirectory)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var pending = Data()
        var stderrTail = Data()
        var resultError: String?
        let handleLine: (Data) -> Void = { [weak self] line in
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if event["type"] as? String == "result", event["is_error"] as? Bool == true {
                resultError = event["result"] as? String ?? event["subtype"] as? String
            }
            guard event["type"] as? String == "stream_event", let inner = event["event"] as? [String: Any] else { return }
            var piece: String?
            if inner["type"] as? String == "content_block_delta", let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                piece = delta["text"] as? String
            } else if inner["type"] as? String == "message_start" {
                piece = "\n\n"
            }
            guard let piece else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preview = (self.preview + piece).trimmingCharacters(in: .newlines) == "" ? "" : self.preview + piece
                self.onDelta?(piece)
                self.onChange?()
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending.removeSubrange(pending.startIndex...newline)
            }
            lock.unlock()
            lines.forEach(handleLine)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            stderrTail.append(chunk)
            if stderrTail.count > 8192 { stderrTail = stderrTail.suffix(8192) }
            lock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            pending.append(rest)
            let last = pending
            stderrTail.append(errors.fileHandleForReading.readDataToEndOfFile())
            let tail = String(data: stderrTail, encoding: .utf8) ?? ""
            lock.unlock()
            if !last.isEmpty { handleLine(last) }
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                self.preview = ""
                LearnDue.refresh()
                if status == 0, resultError == nil {
                    self.queue.removeFirst()
                } else {
                    let lines = tail.split(separator: "\n").suffix(6).joined(separator: "\n")
                    self.failure = [resultError, lines.isEmpty ? nil : lines, "exit \(status)"].compactMap { $0 }.joined(separator: "\n")
                }
                self.startNext()
            }
        }
        do {
            try process.run()
            running = process
            preview = ""
        } catch {
            failure = "\(error)"
        }
        onChange?()
    }
}

/// The rung awaiting an answer: the first one after the last answered rung, or nil while Claude owes the next rung.
func currentRung(_ session: TutorSession, _ answers: [String: TutorAnswer]) -> Rung? {
    let start = session.rungs.lastIndex { answers[$0.id] != nil }.map { $0 + 1 } ?? 0
    return start < session.rungs.count ? session.rungs[start] : nil
}

/// JSON files in a directory, newest first, leaving out sign-off and answer sidecars.
func newestJSON(in directory: String, where keep: (String) -> Bool) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") && !$0.hasSuffix(".answers.json") }
        .map { (directory as NSString).appendingPathComponent($0) }
        .filter(keep)
        .map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}

enum RailItem {
    case event(Rung.Event)
    case part(Rung.Part)

    var t: String {
        switch self {
        case .event(let event): return event.t
        case .part(let part): return part.at ?? ""
        }
    }
}

func railTime(_ t: String) -> Double? {
    t.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression).flatMap { Double(t[$0]) }
}

/// The timeline with each `at` part slotted in after the last item at or before its time.
func railItems(_ rung: Rung) -> [RailItem] {
    var items = (rung.timeline ?? []).map(RailItem.event)
    for part in rung.parts ?? [] {
        guard let at = part.at else { continue }
        let time = railTime(at)
        let earlier = items.lastIndex { item in
            if let time, let value = railTime(item.t) { return value <= time }
            return item.t == at
        }
        if let earlier {
            items.insert(.part(part), at: earlier + 1)
        } else if time != nil, items.contains(where: { railTime($0.t) != nil }) {
            items.insert(.part(part), at: 0)
        } else {
            items.append(.part(part))
        }
    }
    return items
}


/// Read-only tutor text sized to its content at a fixed width.
func tutorText(_ text: NSAttributedString, width: CGFloat) -> NSTextView {
    let trimmed = NSMutableAttributedString(attributedString: text)
    while trimmed.string.hasSuffix("\n") {
        trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1))
    }
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(trimmed)
    var height: CGFloat = 0
    if let layout = view.layoutManager, let container = view.textContainer {
        layout.ensureLayout(for: container)
        height = ceil(layout.usedRect(for: container).height)
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
    return view
}

/// The learner's pen: a serif, ink-blue field that grows with its text.
final class AnswerField: NSTextView {
    let partID: String
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    private var height: NSLayoutConstraint?

    init(partID: String, text: String, width: CGFloat, editable: Bool) {
        self.partID = partID
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40), textContainer: container)
        isRichText = false
        allowsUndo = true
        isEditable = editable
        isSelectable = true
        font = inkFont
        textColor = inkColor
        insertionPointColor = inkColor
        drawsBackground = false
        textContainerInset = NSSize(width: editable ? 10 : 0, height: editable ? 8 : 2)
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        string = text
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: 40)
        self.height = height
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), height])
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func didChangeText() {
        super.didChangeText()
        fitHeight()
    }

    override func drawBackground(in rect: NSRect) {
        guard isEditable else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    private func fitHeight() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height) + textContainerInset.height * 2
        height?.constant = min(max(used, isEditable ? 64 : 0), maximumHeight)
    }
}

/// A part's margin mark: a filled dot when the prediction held, a ring when it was revised.
final class VerdictMark: NSView {
    let held: Bool

    init(held: Bool) {
        self.held = held
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = held ? "held" : "revised"
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if held {
            NSColor.secondaryLabelColor.setFill()
            dot.fill()
        } else {
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }
}

/// One row of a timeline rail: the time in the gutter, a dot on the line, the content to its right.
final class RailRow: NSView {
    static let dotX: CGFloat = 60
    static let contentX: CGFloat = 80
    let hollow: Bool
    var isFirst = false
    var isLast = false

    init(t: String, hollow: Bool, content: NSView) {
        self.hollow = hollow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let time = NSTextField(labelWithString: t)
        time.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        time.lineBreakMode = .byTruncatingHead
        for view in [time, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor),
            time.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Self.dotX - 14),
            time.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentX),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dotY: CGFloat = 10
        let line = NSBezierPath()
        line.move(to: NSPoint(x: Self.dotX, y: isFirst ? dotY : 0))
        line.line(to: NSPoint(x: Self.dotX, y: isLast ? dotY : bounds.height))
        line.lineWidth = 1.5
        NSColor.tertiaryLabelColor.setStroke()
        line.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: Self.dotX - 4.5, y: dotY - 4.5, width: 9, height: 9))
        if hollow {
            NSColor.textBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            dot.stroke()
        } else {
            NSColor.secondaryLabelColor.setFill()
            dot.fill()
        }
    }
}

/// The Learn workspace's document: one session as a worksheet — rungs oldest first, the current rung's fields answered in place.
final class TutorController: NSObject, NSTextViewDelegate {
    static let column: CGFloat = 580
    static let margin: CGFloat = 64
    var path: String?
    var session: TutorSession?
    var answers: [String: TutorAnswer] = [:]
    var drafts: [String: [String: String]] = [:]
    var confidence: [String: Int] = [:]
    var shownReveals: Set<String> = []
    var lastCurrent: String?
    var hasRendered = false
    var stamp = ""
    var timer: Timer?
    let renderer = Renderer()
    let viewController = NSSplitViewController()
    var title = "Show"
    var subtitle = ""
    var onTitleChange: (() -> Void)?
    let sidebar = TutorSidebar()
    /// Starts a re-test session for a concept; the workspace that owns this controller opens it.
    var onStartRetest: ((String) -> Void)?
    let scroll = NSScrollView()
    let document = FlippedView()
    let column = NSStackView()
    var fields: [AnswerField] = []
    var focusRungView: NSView?
    weak var picker: NSSegmentedControl?
    weak var hint: NSTextField?
    let composer = AnswerField(partID: "__composer", text: "", width: TutorController.column, editable: true)
    var sidecar = Sidecar()
    var agentRow: NSView?
    var agent: TutorAgent?

    var window: NSWindow? { viewController.view.window }
    var currentRungID: String? { session.flatMap { currentRung($0, answers)?.id } }

    override init() {
        super.init()

        KeyTable.register(learnKeys)
        sidebar.onStation = { [weak self] station in self?.deliver("learner wants station \(station.name)") }
        sidebar.onDue = { [weak self] due in self?.onStartRetest?(due.concept) }
        let sidebarVC = NSViewController()
        sidebarVC.view = sidebar.scroll

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.margin),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 64),
            column.widthAnchor.constraint(equalToConstant: Self.column),
            document.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: 160),
        ])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        composer.delegate = self
        composer.maximumHeight = 160
        let composerSend = NSButton(title: "Send", target: self, action: #selector(sendMessage))
        composerSend.bezelStyle = .rounded
        composerSend.toolTip = "⌘↩"
        let composerHint = NSTextField(labelWithString: "Ask the tutor anything")
        composerHint.font = .systemFont(ofSize: 11)
        composerHint.textColor = .tertiaryLabelColor
        let composerRow = NSStackView(views: [composer, composerSend])
        composerRow.orientation = .horizontal
        composerRow.alignment = .bottom
        composerRow.spacing = 12
        let composerBar = NSStackView(views: [composerHint, composerRow])
        composerBar.orientation = .vertical
        composerBar.alignment = .leading
        composerBar.spacing = 6
        composerBar.edgeInsets = NSEdgeInsets(top: 12, left: Self.margin, bottom: 14, right: 24)
        let divider = NSBox()
        divider.boxType = .separator
        let detail = NSStackView(views: [scroll, divider, composerBar])
        detail.orientation = .vertical
        detail.spacing = 0
        for view in [scroll, divider, composerBar] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let detailVC = NSViewController()
        detailVC.view = detail

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 340
        sidebarItem.preferredThicknessFraction = 0.24
        viewController.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = Self.margin + Self.column + 48
        viewController.addSplitViewItem(detailItem)
    }

    func show(path: String) {
        if path != self.path {
            saveDrafts()
            self.path = path
            drafts = prefs.dictionary(forKey: "tutor.drafts." + path) as? [String: [String: String]] ?? [:]
            confidence = prefs.dictionary(forKey: "tutor.confidence." + path) as? [String: Int] ?? [:]
            composer.string = prefs.string(forKey: "tutor.composer." + path) ?? ""
            composer.didChangeText()
            agent?.onChange = nil
            agent = TutorAgent.agent(for: path)
            agent?.onChange = { [weak self] in self?.refreshAgentRow() }
            shownReveals = []
            hasRendered = false
        }
        reload(forceScroll: true)
        focusFirstField()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let path = self.path, fileStamp(path) != self.stamp else { return }
            self.reload()
        }
    }

    func showEmpty(_ message: String = "No tutor sessions in `~/.dotfiles/show/tutor` yet. Claude starts one with `show --tutor <file>`.") {
        saveDrafts()
        timer?.invalidate()
        path = nil
        session = nil
        rebuild()
        column.addArrangedSubview(tutorText(renderer.tutorMarkdown(message), width: Self.column))
        sidebar.show(nil)
        title = "Show"
        subtitle = ""
        onTitleChange?()
    }

    /// Re-reads the session and its answers; keeps drafts, focus and scroll unless a new rung became current.
    func reload(forceScroll: Bool = false) {
        guard let path else { return }
        let fresh: TutorSession
        do {
            fresh = try loadTutorSession(path)
        } catch {
            if session == nil {
                column.arrangedSubviews.forEach { $0.removeFromSuperview() }
                column.addArrangedSubview(tutorText(NSAttributedString(string: "Can't read \(path): \(error)", attributes: [.font: renderer.base, .foregroundColor: NSColor.secondaryLabelColor]), width: Self.column))
            }
            return
        }
        stamp = fileStamp(path)
        session = fresh
        sidecar = loadSidecar(path)
        answers = sidecar.answers
        let current = currentRung(fresh, answers)?.id
        let moved = !hasRendered || current != lastCurrent
        let focusedField = window?.firstResponder as? AnswerField
        let focused = focusedField?.partID
        let cursor = focusedField?.selectedRange()
        let origin = scroll.contentView.bounds.origin
        rebuild()
        if forceScroll || moved {
            scrollToFocusRung()
            DispatchQueue.main.async { self.scrollToFocusRung() }
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if !moved, let focused, let field = fields.first(where: { $0.partID == focused }) {
            window?.makeFirstResponder(field)
            if let cursor, NSMaxRange(cursor) <= (field.string as NSString).length {
                field.setSelectedRange(cursor)
            }
        } else if moved {
            focusFirstField()
        }
        lastCurrent = current
        hasRendered = true
    }

    /// Keeps unsent answers across a relaunch into a new build; the answers sidecar only ever holds sent ones.
    func saveDrafts() {
        guard let path else { return }
        prefs.set(drafts, forKey: "tutor.drafts." + path)
        prefs.set(confidence, forKey: "tutor.confidence." + path)
        prefs.set(composer.string, forKey: "tutor.composer." + path)
    }

    func focusFirstField() {
        if let field = fields.first(where: { $0.string.isEmpty }) ?? fields.first {
            window?.makeFirstResponder(field)
        }
    }

    func choose(confidence level: Int) {
        guard let id = currentRungID else { return }
        confidence[id] = level
        picker?.selectedSegment = level
        hint?.isHidden = true
        saveDrafts()
    }

    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        document.subviews.filter { $0 !== column }.forEach { $0.removeFromSuperview() }
        fields = []
        focusRungView = nil
        guard let session else { return }
        renderSidebar(session)
        title = session.title
        subtitle = "\(session.rungs.filter { answers[$0.id] != nil }.count) of \(session.rungs.count) answered"
        onTitleChange?()
        let current = currentRung(session, answers)
        let focusID = current?.id ?? session.rungs.last?.id
        var fresh: [NSView] = []
        var seen: Set<String> = []
        for item in thread(session) {
            guard case .rung(let rung) = item else {
                let view = threadRow(item)
                column.addArrangedSubview(view)
                column.setCustomSpacing(28, after: view)
                continue
            }
            var marks: [(mark: NSView, block: NSView)] = []
            let view = rungView(rung, isCurrent: rung.id == current?.id, fresh: &fresh, seen: &seen, marks: &marks)
            column.addArrangedSubview(view)
            for (mark, block) in marks {
                document.addSubview(mark)
                NSLayoutConstraint.activate([
                    mark.trailingAnchor.constraint(equalTo: column.leadingAnchor, constant: -16),
                    mark.centerYAnchor.constraint(equalTo: block.topAnchor, constant: 10),
                ])
            }
            column.setCustomSpacing(56, after: view)
            if rung.id == focusID {
                focusRungView = view
            } else {
                view.alphaValue = 0.6
                marks.forEach { $0.mark.alphaValue = 0.6 }
            }
        }
        if session.rungs.isEmpty, agent?.isBusy != true {
            column.addArrangedSubview(quiet("No rungs yet. Waiting for Claude."))
        }
        agentRow = nil
        refreshAgentRow()
        document.layoutSubtreeIfNeeded()
        if hasRendered, !fresh.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fresh.forEach { $0.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                fresh.forEach { $0.animator().alphaValue = 1 }
            }
        }
        shownReveals = seen
    }

    enum ThreadItem {
        case rung(Rung)
        case message(LearnerMessage)
        case note(TutorSession.Note)
    }

    /// Rungs, the learner's messages and the tutor's notes as one conversation by time; a rung counts from when the previous rung was answered,
    /// and the first rung from just after the tutor's first note, so a boot's map sits above it.
    private func thread(_ session: TutorSession) -> [ThreadItem] {
        var keyed: [(Date, Int, ThreadItem)] = []
        let firstNote = (session.notes ?? []).compactMap { isoDate($0.at) }.min()
        for (i, rung) in session.rungs.enumerated() {
            let posted: Date
            if i == 0 {
                posted = firstNote?.addingTimeInterval(0.001) ?? .distantPast
            } else if let previous = answers[session.rungs[i - 1].id] {
                posted = isoDate(previous.at) ?? .distantPast
            } else {
                posted = .distantFuture
            }
            keyed.append((posted, keyed.count, .rung(rung)))
        }
        for message in sidecar.messages {
            keyed.append((isoDate(message.at) ?? .distantFuture, keyed.count, .message(message)))
        }
        for note in session.notes ?? [] {
            keyed.append((isoDate(note.at) ?? .distantFuture, keyed.count, .note(note)))
        }
        return keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private func threadRow(_ item: ThreadItem) -> NSView {
        switch item {
        case .message(let message):
            let p = NSMutableParagraphStyle()
            p.alignment = .right
            p.lineSpacing = 3
            return tutorText(NSAttributedString(string: message.text, attributes: [.font: inkFont, .foregroundColor: inkColor, .paragraphStyle: p]), width: Self.column)
        case .note(let note):
            return tutorText(renderer.tutorMarkdown(note.text), width: Self.column)
        case .rung:
            return NSView()
        }
    }

    /// The tutor's live row under the thread: a typing line with the streamed preview, or the last failure with Retry.
    func refreshAgentRow() {
        let atBottom = scroll.contentView.bounds.maxY >= document.bounds.height - 40
        if let agentRow {
            column.removeArrangedSubview(agentRow)
            agentRow.removeFromSuperview()
            self.agentRow = nil
        }
        if let above = agentRowAbove {
            column.setCustomSpacing(agentRowAboveGap, after: above)
            agentRowAbove = nil
        }
        guard let agent else { return }
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        if let failure = agent.failure {
            let label = quiet("The tutor stopped with an error:")
            let detail = tutorText(NSAttributedString(string: failure, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]), width: Self.column)
            let retry = NSButton(title: "Retry", target: self, action: #selector(retryAgent))
            retry.bezelStyle = .rounded
            [label, detail, retry].forEach(row.addArrangedSubview)
        } else if agent.isBusy {
            row.addArrangedSubview(TypingDots())
            let text = agent.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                row.addArrangedSubview(tutorText(NSAttributedString(string: text, attributes: [.font: renderer.base, .foregroundColor: NSColor.tertiaryLabelColor]), width: Self.column))
            }
        } else {
            return
        }
        if let above = column.arrangedSubviews.last {
            agentRowAbove = above
            agentRowAboveGap = column.customSpacing(after: above)
            column.setCustomSpacing(14, after: above)
        }
        column.addArrangedSubview(row)
        agentRow = row
        document.layoutSubtreeIfNeeded()
        if atBottom {
            scrollToBottom()
        }
    }

    private func scrollToBottom() {
        document.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func retryAgent() {
        agent?.retry()
    }

    /// Hands a line to whoever tutors this file: its own headless session, or the `replyTo` terminal session in older files.
    private func deliver(_ message: String) {
        guard let path, let session else { return }
        if session.usesAgent {
            agent?.send(message)
            scrollToBottom()
        } else if let replyTo = session.replyTo, let failure = claudeSay(replyTo, message) {
            showClaudeSayFailure(replyTo: replyTo, saved: "It's saved in \((answersURL(path).path as NSString).lastPathComponent).", detail: failure, window: window)
        }
    }

    /// ⌘↩: send the composer when it has focus, otherwise the current rung.
    func sendFocused() {
        if window?.firstResponder === composer {
            sendMessage()
        } else if currentRungID != nil {
            sendAnswer()
        } else if !composer.string.isEmpty {
            sendMessage()
        } else {
            NSSound.beep()
        }
    }

    @objc private func sendMessage() {
        guard let path else { return }
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        var all = loadSidecar(path)
        all.messages.append(LearnerMessage(at: ISO8601DateFormatter().string(from: Date()), text: text))
        do {
            try writeSidecar(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your message"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        composer.string = ""
        composer.didChangeText()
        saveDrafts()
        reload()
        deliver("learner says: \(text)")
    }

    private func rungView(_ rung: Rung, isCurrent: Bool, fresh: inout [NSView], seen: inout Set<String>, marks: inout [(mark: NSView, block: NSView)]) -> NSView {
        let width = Self.column
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        func add(_ view: NSView, after gap: CGFloat) {
            stack.addArrangedSubview(view)
            stack.setCustomSpacing(gap, after: view)
        }
        func reveal(_ text: String, key: String) -> NSView {
            let view = tutorText(renderer.tutorMarkdown(text), width: width)
            seen.insert(key)
            if !shownReveals.contains(key) { fresh.append(view) }
            return view
        }
        let answer = answers[rung.id]
        add(tutorText(renderer.tutorInline(rung.title, font: .systemFont(ofSize: 21, weight: .bold)), width: width), after: 4)
        let tag = [rung.station, rung.ask].compactMap { $0 }.joined(separator: " · ")
        add(tutorText(NSAttributedString(string: tag.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6]), width: width), after: 18)
        if let situation = rung.situation, !situation.isEmpty {
            add(tutorText(renderer.tutorMarkdown(situation), width: width), after: 12)
        }

        func partBlock(_ part: Rung.Part, width: CGFloat) -> NSView {
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 8
            if let ask = part.ask {
                block.addArrangedSubview(tutorText(renderer.tutorInline(ask, font: .systemFont(ofSize: 14.5, weight: .semibold)), width: width))
            }
            let written = answer?.parts[part.id] ?? drafts[rung.id]?[part.id] ?? ""
            let field = AnswerField(partID: part.id, text: !isCurrent && written.isEmpty ? "—" : written, width: width, editable: isCurrent)
            if isCurrent {
                field.delegate = self
                fields.append(field)
            }
            block.addArrangedSubview(field)
            if let text = rung.reveal(for: part.id) {
                let view = reveal(text, key: "\(rung.id)/\(part.id)")
                block.setCustomSpacing(12, after: field)
                block.addArrangedSubview(view)
                view.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            if let verdict = rung.verdicts?[part.id] {
                marks.append((VerdictMark(held: verdict == "held"), block))
            }
            return block
        }

        let rail = railItems(rung)
        if !rail.isEmpty {
            let railStack = NSStackView()
            railStack.orientation = .vertical
            railStack.alignment = .leading
            railStack.spacing = 0
            let inner = width - RailRow.contentX
            for (i, item) in rail.enumerated() {
                let row: RailRow
                switch item {
                case .event(let event):
                    row = RailRow(t: event.t, hollow: false, content: tutorText(renderer.tutorInline(event.event, font: renderer.base), width: inner))
                case .part(let part):
                    row = RailRow(t: part.at ?? "", hollow: true, content: partBlock(part, width: inner))
                }
                row.isFirst = i == 0
                row.isLast = i == rail.count - 1
                railStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            add(railStack, after: 16)
        }
        for part in rung.answerParts where part.at == nil {
            add(partBlock(part, width: width), after: 22)
        }
        if let text = rung.wholeReveal {
            add(reveal(text, key: "\(rung.id)/*"), after: 16)
        }
        if let followup = rung.followup, !followup.isEmpty {
            add(tutorText(renderer.tutorMarkdown(followup), width: width), after: 16)
        }
        if isCurrent {
            let question = quiet(rung.isPredict ? "How sure are you?  ⌃1 · ⌃2 · ⌃3" : "How sure are you? (optional)  ⌃1 · ⌃2 · ⌃3")
            add(question, after: 8)
            let control = NSSegmentedControl(labels: confidenceLevels.map(\.1), trackingMode: .selectOne, target: self, action: #selector(pickedConfidence))
            control.selectedSegment = confidence[rung.id] ?? -1
            control.refusesFirstResponder = true
            picker = control
            add(control, after: 18)
            let send = NSButton(title: rung.isPredict ? "Send prediction" : "Send answer", target: self, action: #selector(sendAnswer))
            send.bezelStyle = .rounded
            send.toolTip = "⌘↩"
            add(send, after: 8)
            let note = quiet("")
            note.isHidden = true
            hint = note
            add(note, after: 0)
        } else if let answer {
            let level = confidenceLevels.first(where: { $0.0 == answer.confidence })?.1
            let waiting = rung.reveal == nil && agent?.isBusy != true
            if level != nil || waiting {
                let line = NSStackView()
                line.orientation = .horizontal
                line.spacing = 10
                if let level {
                    line.addArrangedSubview(NSTextField(labelWithAttributedString: NSAttributedString(string: level.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .kern: 0.6])))
                }
                if waiting {
                    line.addArrangedSubview(TypingDots())
                }
                add(line, after: 0)
            }
        }
        return stack
    }

    /// The view the agent row sits under, and its usual gap, which the row tightens while it's there.
    private weak var agentRowAbove: NSView?
    private var agentRowAboveGap: CGFloat = 0

    private func quiet(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func renderSidebar(_ session: TutorSession) {
        sidebar.show(session)
    }

    private func scrollToFocusRung() {
        guard let view = focusRungView else { return }
        document.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: document)
        let room = document.bounds.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(frame.minY - 40, room))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func showHint(_ text: String) {
        NSSound.beep()
        hint?.stringValue = text
        hint?.isHidden = false
    }

    @objc private func pickedConfidence(_ sender: NSSegmentedControl) {
        choose(confidence: sender.selectedSegment)
    }

    @objc private func sendAnswer() {
        guard let path, let session, let rung = currentRung(session, answers) else {
            NSSound.beep()
            return
        }
        var texts: [String: String] = [:]
        for part in rung.answerParts {
            texts[part.id] = (drafts[rung.id]?[part.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if texts.values.contains(where: \.isEmpty) {
            showHint(rung.answerParts.count > 1 ? "Answer every part first." : "Write your answer first.")
            return
        }
        let level = confidence[rung.id]
        if rung.isPredict, level == nil {
            showHint("Pick how sure you are first: ⌃1 Guessing · ⌃2 Fairly sure · ⌃3 Certain.")
            return
        }
        var all = loadSidecar(path)
        all.answers[rung.id] = TutorAnswer(parts: texts, confidence: level.map { confidenceLevels[$0].0 }, at: ISO8601DateFormatter().string(from: Date()))
        do {
            try writeSidecar(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your answer"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        drafts[rung.id] = nil
        confidence[rung.id] = nil
        saveDrafts()
        reload()
        deliver("tutor answer: \(path) rung \(rung.id)")
    }

    func textDidChange(_ notification: Notification) {
        if notification.object as? AnswerField === composer {
            saveDrafts()
            return
        }
        guard let field = notification.object as? AnswerField, let id = currentRungID else { return }
        drafts[id, default: [:]][field.partID] = field.string
        hint?.isHidden = true
        saveDrafts()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === composer, commandSelector == #selector(NSResponder.insertBacktab(_:)), let last = fields.last {
            window?.makeFirstResponder(last)
            return true
        }
        guard let index = fields.firstIndex(where: { $0 === textView }), fields.count > 0 else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            window?.makeFirstResponder(fields[(index + 1) % fields.count])
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.makeFirstResponder(fields[(index + fields.count - 1) % fields.count])
            return true
        default:
            return false
        }
    }

    /// Writes the whole worksheet column, which runs taller than the window, to `file`.
    func snapshotWorksheet(to file: String) {
        timer?.invalidate()
        scroll.contentView.scroll(to: .zero)
        document.layoutSubtreeIfNeeded()
        writePNG(document, to: file)
    }
}

func fileStamp(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(modified)-\(attributes[.size] as? Int ?? 0)"
}

/// `--tutor-ask`: what the composer does, without a window: record a learner message, run the tutor turn, stream its text to stdout.
func tutorAsk(_ raw: String, _ text: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        _ = try loadTutorSession(path)
        var sidecar = try readSidecar(path)
        sidecar.messages.append(LearnerMessage(at: ISO8601DateFormatter().string(from: Date()), text: text))
        try writeSidecar(sidecar, path)
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
    return streamTutorTurn(path, "learner says: \(text)")
}

/// Sends one message to the file's tutor and streams the reply's text to stdout until the turn ends; exits with its outcome.
func streamTutorTurn(_ path: String, _ message: String) -> Int32 {
    let agent = TutorAgent.agent(for: path)
    let began = Date()
    var started = false
    agent.onDelta = { piece in
        FileHandle.standardOutput.write(piece.data(using: .utf8)!)
    }
    agent.onChange = {
        if agent.isBusy { started = true }
        if started, !agent.isBusy || agent.failure != nil {
            if let failure = agent.failure {
                FileHandle.standardError.write("\ntutor failed:\n\(failure)\n".data(using: .utf8)!)
                exit(1)
            }
            print("\n[done in \(Int(Date().timeIntervalSince(began)))s; agent.session \(TutorAgent.sessionID(path) ?? "-")]")
            exit(0)
        }
    }
    agent.send(message)
    RunLoop.main.run()
    return 0
}

/// Three dots breathing in turn: the tutor is working on its reply. It says nothing in words, since the place it sits says what it's for.
final class TypingDots: NSView {
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 12))
        wantsLayer = true
        for i in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * 10, y: 3, width: 6, height: 6)
            dot.cornerRadius = 3
            dot.opacity = 0.25
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 0.9
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            dot.add(pulse, forKey: "pulse")
            layer?.addSublayer(dot)
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func updateLayer() {
        let color = NSColor.secondaryLabelColor.cgColor
        layer?.sublayers?.forEach { $0.backgroundColor = color }
    }

    override var wantsUpdateLayer: Bool { true }
}
