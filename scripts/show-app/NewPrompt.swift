import AppKit

/// ⌘N: a small "New…" prompt, routed per workspace. Review and Forest hand the request to a headless Claude that writes the deck
/// and opens it with `show`; Learn has its own (`tutor.new`); Runs has nothing to make.
enum NewRequest {
    static func placeholder(_ workspace: Workspace) -> String {
        switch workspace {
        case .review: return "Ask Claude for a deck about…"
        case .forest: return "Branch deck for project…"
        case .learn, .runs: return ""
        }
    }

    /// Why ⌘N does nothing here, or nil when it does something.
    static func unavailable(_ workspace: Workspace) -> String? {
        workspace == .runs ? "Runs start from their own scripts; Show only watches them" : nil
    }

    static var requestsDirectory: String { (decksDirectory as NSString).appendingPathComponent("requests") }

    /// Writes `requests/<ts>.json` with `{workspace, text}` and starts the headless Claude; returns the request file.
    static func ask(_ workspace: Workspace, _ text: String, done: @escaping (Int32, String) -> Void) throws -> String {
        try FileManager.default.createDirectory(atPath: requestsDirectory, withIntermediateDirectories: true)
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = (requestsDirectory as NSString).appendingPathComponent(format.string(from: Date()))
        let request = stem + ".json"
        let body: [String: String] = ["workspace": workspace.rawValue, "text": text, "at": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: request), options: .atomic)
        let arguments = ["-p", "--permission-mode", "acceptEdits", "--allowedTools", allowedTools] + extraDirectories + ["--", prompt(workspace, text, request: request)]
        let process = Process()
        if let override = ProcessInfo.processInfo.environment["SHOW_CLAUDE"] {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "export PATH=\"$HOME/.local/bin:$PATH\"; exec claude \"$@\"", "claude"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: ("~/.dotfiles" as NSString).expandingTildeInPath)
        let log = stem + ".log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? handle.close()
            DispatchQueue.main.async { done(finished.terminationStatus, log) }
        }
        try process.run()
        return request
    }

    static let allowedTools = "Read,Write,Edit,Glob,Grep,Bash(git:*),Bash(stack-merge-rank:*),Bash(python3:*),Bash(ls:*),Bash(show:*),Bash(~/.dotfiles/scripts/show:*)"

    /// The loops checkout, so a branch deck can read the forest's diffs.
    static var extraDirectories: [String] {
        let loops = ("~/coding/loops" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: loops) ? ["--add-dir", loops] : []
    }

    static func prompt(_ workspace: Workspace, _ text: String, request: String) -> String {
        let show = (decksDirectory as NSString).abbreviatingWithTildeInPath
        let common = "Save it as a new file in \(show)/ (never overwrite an existing deck), leave replyTo unset, then run `~/.dotfiles/scripts/show <that path>` so it opens in Phil's Show window. Reply with the deck's path only."
        switch workspace {
        case .forest:
            return "Phil asked Show (⌘N in Forest) for a branch deck. Request file: \(request). Project: \(text)\n\nUse the branch-deck skill (~/.dotfiles/.claude/skills/branch-deck/SKILL.md) and the show skill (~/.dotfiles/.claude/skills/show/SKILL.md) to build the forest deck for that stack project; read ranks and parents from git as the skill says. Name it \(show)/<project>-branches.json. \(common)"
        default:
            return "Phil asked Show (⌘N in Review) for a deck. Request file: \(request). About: \(text)\n\nUse the show skill (~/.dotfiles/.claude/skills/show/SKILL.md): write the deck with a small generator script, one idea per page, ordered for sign-off. \(common)"
        }
    }
}

/// The ⌘N prompt: one field, ↩ sends, ⎋ closes and keeps what you typed for next time.
final class NewPromptOverlay: NSView, NSTextFieldDelegate {
    let panel = NSVisualEffectView()
    let field = NSTextField()
    let workspace: Workspace
    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "New in \(workspace.name)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        field.placeholderString = NewRequest.placeholder(workspace)
        field.stringValue = prefs.string(forKey: "new.draft." + workspace.rawValue) ?? ""
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        let hint = NSTextField(labelWithString: "↩ asks Claude, who writes the deck and opens it here · ⎋ closes, keeps your text")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        for view in [panel, title, field, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(panel)
        [title, field, hint].forEach(panel.addSubview)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.widthAnchor.constraint(equalToConstant: 520),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
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

    func controlTextDidChange(_ obj: Notification) {
        prefs.set(field.stringValue, forKey: "new.draft." + workspace.rawValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return true
        }
        onSend?(text)
        return true
    }
}

extension AppDelegate {
    /// ⌘N: the New… prompt for the front workspace.
    func showNewPrompt() {
        let workspace = active
        if let reason = NewRequest.unavailable(workspace) {
            workspaces[workspace]?.say(reason)
            return
        }
        closeOverlays()
        workspaces[workspace]?.rememberFocus(in: window)
        let prompt = NewPromptOverlay(workspace: workspace)
        prompt.onClose = { [weak self] in self?.closeOverlays() }
        prompt.onSend = { [weak self, weak prompt] text in
            prefs.removeObject(forKey: "new.draft." + workspace.rawValue)
            prompt?.field.stringValue = ""
            self?.closeOverlays()
            self?.sendNew(workspace, text)
        }
        shell.showOverlay(prompt)
        window.makeFirstResponder(prompt.field)
        prompt.field.currentEditor()?.selectedRange = NSRange(location: (prompt.field.stringValue as NSString).length, length: 0)
    }

    func sendNew(_ workspace: Workspace, _ text: String) {
        guard let controller = workspaces[workspace] else { return }
        do {
            let request = try NewRequest.ask(workspace, text) { [weak controller] status, log in
                controller?.say(status == 0 ? "Claude finished: “\(text)”" : "Claude failed (exit \(status)); see \((log as NSString).abbreviatingWithTildeInPath)")
            }
            controller.say("Asked Claude for “\(text)” (\((request as NSString).lastPathComponent))")
        } catch {
            controller.say("Couldn't ask Claude: \(error.localizedDescription)")
        }
    }
}
