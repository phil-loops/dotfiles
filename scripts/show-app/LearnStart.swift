import AppKit

/// One concept due for a re-test, as the learner graph derives it.
struct DueConcept {
    let id: String
    let name: String
    let reason: String
}

/// The learner graph's due re-tests, read with `learn json` (read-only, `LEARNING_MEMORY=0`) and cached between refreshes.
enum LearnDue {
    static let script = ("~/.dotfiles/scripts/learn" as NSString).expandingTildeInPath
    private(set) static var concepts: [DueConcept] = []
    private(set) static var failure: String?
    private static var loading = false
    static var expanded = false
    static var onChange: (() -> Void)?

    /// Re-reads the graph off the main thread (or right away with `sync`), then calls `onChange` on the main thread.
    static func refresh(sync: Bool = false) {
        if sync {
            apply(read())
            return
        }
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = read()
            DispatchQueue.main.async {
                loading = false
                apply(result)
            }
        }
    }

    private static func apply(_ result: Result<[DueConcept], Error>) {
        switch result {
        case .success(let fresh):
            concepts = fresh
            failure = nil
        case .failure(let error):
            failure = "\(error)"
        }
        onChange?()
    }

    /// What `learn retest --all` would offer, in its order: every due concept not already tested today.
    static func read() -> Result<[DueConcept], Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = ["json"]
        var environment = ProcessInfo.processInfo.environment
        environment["LEARNING_MEMORY"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let due = state["due"] as? [String],
                  let concepts = state["concepts"] as? [String: [String: Any]] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "learn json exited \(process.terminationStatus)"])
            }
            let today = state["today"] as? String
            let testedToday = Set(((state["evidence"] as? [[String: Any]]) ?? []).filter { $0["at"] as? String == today }.compactMap { $0["concept"] as? String })
            return .success(due.filter { !testedToday.contains($0) }.map { id in
                let concept = concepts[id] ?? [:]
                return DueConcept(id: id, name: concept["name"] as? String ?? id,
                                  reason: (concept["mastery"] as? [String: Any])?["reason"] as? String ?? "")
            })
        } catch {
            return .failure(error)
        }
    }

    static func name(_ id: String) -> String {
        concepts.first { $0.id == id }?.name ?? id
    }
}

/// Learn's shelf group of due re-tests: the top few, the rest folded.
func dueShelfRows() -> [ShelfRow] {
    let due = LearnDue.concepts
    guard !due.isEmpty else { return [] }
    let shown = LearnDue.expanded ? due : Array(due.prefix(WorkspaceController.foldAfter))
    var rows = [ShelfRow.dueHeader(due.count)] + shown.map(ShelfRow.due)
    if due.count > WorkspaceController.foldAfter {
        rows.append(.dueFold(hidden: due.count - WorkspaceController.foldAfter, expanded: LearnDue.expanded))
    }
    return rows
}

/// The cell for a Due-group row, or nil for every other shelf row.
func dueShelfView(_ row: ShelfRow) -> NSView? {
    func label(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    let cell = NSTableCellView()
    switch row {
    case .dueHeader(let count):
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = NSAttributedString(string: "Due  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            + NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])
        return header
    case .dueFold(let hidden, let expanded):
        let fold = label(expanded ? "Show fewer" : "Show \(hidden) more", .systemFont(ofSize: 11.5, weight: .medium), .secondaryLabelColor)
        fold.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(fold)
        NSLayoutConstraint.activate([
            fold.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 30),
            fold.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    case .due(let concept):
        let mark = label("◆", .systemFont(ofSize: 11), .systemOrange)
        let title = label(concept.name, .systemFont(ofSize: 13, weight: .medium), .labelColor)
        let detail = label(concept.reason, .systemFont(ofSize: 11), .secondaryLabelColor)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [mark, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            mark.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 26),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -34),
            detail.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -34),
        ])
        cell.toolTip = "↵ starts a one-rung re-test of \(concept.id)"
        return cell
    default:
        return nil
    }
}

/// A new session file from the template: a title, nothing to answer yet, and a fresh `agent.session` for its own tutor.
func createTutorSession(title: String, slug: String) throws -> String {
    try FileManager.default.createDirectory(atPath: tutorDirectory, withIntermediateDirectories: true)
    let format = DateFormatter()
    format.dateFormat = "yyyyMMdd-HHmmss"
    let words = slug.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let stem = String(words).split(separator: "-").joined(separator: "-").prefix(48)
    let path = canonicalPath((tutorDirectory as NSString).appendingPathComponent("\(stem.isEmpty ? "session" : String(stem))-\(format.string(from: Date())).json"))
    let template: [String: Any] = [
        "mode": "tutor",
        "title": title,
        "stations": [],
        "rungs": [],
        "notes": [],
        "agent": ["session": UUID().uuidString.lowercased()],
    ]
    try JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    return path
}

/// How Learn starts a session: the file it creates and the opening its tutor boots with.
enum TutorOpening {
    case retest(concept: String)
    case topic(String)

    var message: String {
        switch self {
        case .retest(let concept): return "re-test \(concept)"
        case .topic(let text): return "/tutor \(text)"
        }
    }

    var title: String {
        switch self {
        case .retest(let concept): return "Re-test: \(LearnDue.name(concept))"
        case .topic(let text): return text.count > 60 ? String(text.prefix(59)) + "…" : text
        }
    }

    var slug: String {
        switch self {
        case .retest(let concept): return "retest-" + concept
        case .topic(let text): return text
        }
    }

    /// Creates the session file and queues the boot turn on its tutor. Returns the new file.
    func start() throws -> String {
        let path = try createTutorSession(title: title, slug: slug)
        TutorAgent.agent(for: path).send(message)
        return path
    }
}

extension WorkspaceController {
    /// Starts a new tutor session in Learn and opens it, its boot turn already running.
    func startTutor(_ opening: TutorOpening) {
        do {
            let path = try opening.start()
            onLibraryChange?()
            open(path)
            say("Started “\(opening.title)”")
        } catch {
            say("Couldn't start a session: \(error.localizedDescription)")
        }
    }

    /// ↵ on a shelf row in Learn's Due group.
    func activateDue(_ concept: DueConcept) {
        startTutor(.retest(concept: concept.id))
    }
}

/// ⌘N in Learn: one line asking what to learn, laid over the window. Free text, a branch, a PR number or a file path all go to `/tutor` as typed.
final class NewSessionOverlay: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let panel = NSVisualEffectView()
    var onStart: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        let question = NSTextField(labelWithString: "What do you want to learn?")
        question.font = .systemFont(ofSize: 13, weight: .semibold)
        question.textColor = .secondaryLabelColor
        field.placeholderString = "A topic, a branch, a PR number or a file path"
        field.font = inkFont
        field.textColor = inkColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        let hint = NSTextField(labelWithString: "↩ start a session · ⎋ cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        for view in [panel, question, field, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(panel)
        [question, field, hint].forEach(panel.addSubview)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.widthAnchor.constraint(equalToConstant: 520),
            question.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            question.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.topAnchor.constraint(equalTo: question.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onClose?()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                NSSound.beep()
            } else {
                onStart?(text)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }
}

extension AppDelegate {
    /// ⌘N in Learn: ask what to learn, then start a session whose tutor boots on `/tutor <text>`.
    func askNewTutorSession() {
        closeOverlays()
        workspaces[active]?.rememberFocus(in: window)
        let prompt = NewSessionOverlay()
        prompt.onClose = { [weak self] in self?.closeOverlays() }
        prompt.onStart = { [weak self] text in
            self?.shell.hideOverlay()
            self?.workspaces[.learn]?.startTutor(.topic(text))
            self?.updateFocusOutline()
        }
        shell.showOverlay(prompt)
        window.makeFirstResponder(prompt.field)
        updateFocusOutline()
    }
}

let learnKeys = [
    KeyBinding(id: "tutor.new", menu: "Tutor", title: "New Session…", key: "n", modifiers: .command, workspaces: [.learn]) { $0.askNewTutorSession() },
]

/// `--tutor-start "<re-test <concept> | text>"`: what ↵ on a due re-test or ⌘N does, without a window — create the session, boot its tutor, stream the reply.
func tutorStart(_ text: String) -> Int32 {
    let opening: TutorOpening
    if text.hasPrefix("re-test ") {
        LearnDue.refresh(sync: true)
        opening = .retest(concept: String(text.dropFirst("re-test ".count)))
    } else {
        opening = .topic(text)
    }
    let path: String
    do {
        path = try createTutorSession(title: opening.title, slug: opening.slug)
    } catch {
        FileHandle.standardError.write("Show: couldn't create a session: \(error)\n".data(using: .utf8)!)
        return 73
    }
    print("session: \(path)")
    fflush(stdout)
    return streamTutorTurn(path, opening.message)
}
