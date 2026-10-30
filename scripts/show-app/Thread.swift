import AppKit

/// One line of a section's conversation in `<deck>.thread.json`: Show appends Phil's, the deck's author appends Claude's.
struct ThreadMessage: Codable {
    let at: String
    let from: String
    let text: String

    var isPhil: Bool { from != "claude" }
}

func threadURL(_ deckPath: String) -> URL {
    URL(fileURLWithPath: deckPath).deletingPathExtension().appendingPathExtension("thread.json")
}

func loadThread(_ deckPath: String) -> [String: [ThreadMessage]] {
    (try? JSONDecoder().decode([String: [ThreadMessage]].self, from: Data(contentsOf: threadURL(deckPath)))) ?? [:]
}

/// Appends one message to a section's thread, keeping every other entry exactly as the author wrote it.
func appendThreadMessage(_ message: ThreadMessage, section key: String, deckPath: String) throws {
    let url = threadURL(deckPath)
    var raw: [String: Any] = [:]
    if let data = try? Data(contentsOf: url), !data.isEmpty {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        raw = parsed
    }
    var list = raw[key] as? [Any] ?? []
    list.append(["at": message.at, "from": message.from, "text": message.text])
    raw[key] = list
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
}

/// The `claude-say` binary; `SHOW_CLAUDE_SAY` swaps in a stub for testing.
var claudeSayPath: String {
    ProcessInfo.processInfo.environment["SHOW_CLAUDE_SAY"] ?? ("~/.dotfiles/scripts/claude-say" as NSString).expandingTildeInPath
}

/// Whether `replyTo` resolves to one live, deliverable Claude session, by `claude-say <who> --check` (it sends nothing).
func claudeSessionReachable(_ replyTo: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudeSayPath)
    process.arguments = [replyTo, "--check"]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return false
    }
    return process.terminationStatus == 0
}

/// Gets a deck's thread messages and regenerate requests to whoever answers for it:
/// the author's live session over `claude-say`, or else the deck's own headless `claude -p`.
final class ThreadDelivery {
    enum Status {
        case sending
        case failed(String)
    }

    static var all: [String: ThreadDelivery] = [:]

    static func delivery(for deckPath: String) -> ThreadDelivery {
        if let existing = all[deckPath] { return existing }
        let delivery = ThreadDelivery(deckPath: deckPath)
        all[deckPath] = delivery
        return delivery
    }

    let deckPath: String
    private(set) var status: [String: Status] = [:]
    private var pending: [String: (message: String, replyTo: String?)] = [:]
    private let lane = DispatchQueue(label: "show.thread.delivery")
    private lazy var agent = DeckAgent(deckPath: deckPath)
    var onChange: (() -> Void)?

    init(deckPath: String) {
        self.deckPath = deckPath
    }

    /// The line a section's new message sends: the same words to a live author or the headless one.
    func threadLine(section key: String) -> String {
        "Show thread: \(deckPath) section \(key) — reply by appending {from:\"claude\"} to \(threadURL(deckPath).path)"
    }

    /// Sends `message` on behalf of `key` (a section id, or `regen:<branch>`), remembering it for Retry.
    func send(_ message: String, key: String, replyTo: String?) {
        pending[key] = (message, replyTo)
        status[key] = .sending
        onChange?()
        lane.async { [weak self] in
            guard let self else { return }
            if let replyTo, !replyTo.isEmpty, claudeSessionReachable(replyTo) {
                let failure = claudeSay(replyTo, message)
                DispatchQueue.main.async {
                    self.finish(key, failure: failure)
                }
            } else {
                DispatchQueue.main.async {
                    self.agent.send(message) { [weak self] failure in
                        self?.finish(key, failure: failure)
                    }
                }
            }
        }
    }

    func retry(_ key: String) {
        guard let last = pending[key] else { return }
        agent.clearFailure()
        send(last.message, key: key, replyTo: last.replyTo)
    }

    private func finish(_ key: String, failure: String?) {
        if let failure {
            status[key] = .failed(failure.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            status[key] = nil
        }
        onChange?()
    }

    /// Waits up to `seconds` for every send to settle, spinning the run loop; for snapshots.
    func settle(within seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, status.values.contains(where: { if case .sending = $0 { return true } else { return false } }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// A deck's own headless Claude, for when its author session is gone: one `claude -p` session per deck,
/// its id kept in the deck's top-level `agent.session`, one turn at a time, run in `~/.dotfiles`, allowed to edit only the deck and its thread.
final class DeckAgent {
    let deckPath: String
    private var queue: [(message: String, done: (String?) -> Void)] = []
    private var running: Process?
    private var failed = false

    init(deckPath: String) {
        self.deckPath = deckPath
    }

    func send(_ message: String, done: @escaping (String?) -> Void) {
        queue.append((message, done))
        startNext()
    }

    func clearFailure() {
        failed = false
    }

    static func sessionID(_ deckPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: deckPath)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (raw["agent"] as? [String: Any])?["session"] as? String
    }

    private func mintSession() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: deckPath)),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let session = UUID().uuidString.lowercased()
        var agent = raw["agent"] as? [String: Any] ?? [:]
        agent["session"] = session
        raw["agent"] = agent
        guard let out = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: URL(fileURLWithPath: deckPath), options: .atomic)) != nil else { return nil }
        return session
    }

    /// Drops a session whose boot turn failed, so Retry boots it again instead of resuming nothing.
    private func forgetSession() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: deckPath)),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agent = raw["agent"] as? [String: Any] else { return }
        agent["session"] = nil
        raw["agent"] = agent.isEmpty ? nil : agent
        guard let out = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: URL(fileURLWithPath: deckPath), options: .atomic)
    }

    /// Read anywhere and read-only git; Edit and Write only on the deck and its thread (`//` roots a permission path at /).
    var allowedTools: String {
        let own = [deckPath, threadURL(deckPath).path].flatMap { ["Edit(/\($0))", "Write(/\($0))"] }
        let git = ["log", "show", "diff", "rev-parse", "merge-base", "config --get"].map { "Bash(git -C * \($0) *)" }
        return (["Read", "Grep", "Glob"] + own + git).joined(separator: ",")
    }

    private var bootPrompt: String {
        let thread = threadURL(deckPath).path
        return """
        You answer Phil's review conversation for the Show deck \(deckPath) (its author session is gone). \
        The thread contract is in ~/.dotfiles/.claude/skills/show/SKILL.md under "Threads"; read it first. \
        A line `Show thread: <deck> section <id>` means Phil wrote in that section's thread: read the section in the deck and its array in \(thread), \
        then reply by appending {"at": <ISO-8601 now>, "from": "claude", "text": <markdown>} to that array, keeping the file valid JSON and every other entry untouched. \
        A line `regenerate page <branch>` means rewrite that branch's section in the deck from the branch's current tip, per ~/.dotfiles/.claude/skills/branch-deck/SKILL.md, \
        keeping its id and setting its "sha" to the new tip (read git with `git -C <repo checkout> …`). \
        You may edit only \(deckPath) and \(thread); never the .signoff.json.
        """
    }

    private func startNext() {
        guard running == nil, !failed, let next = queue.first else { return }
        var session = Self.sessionID(deckPath)
        let booting = session == nil
        var text = next.message
        var arguments = ["-p", "--output-format", "json", "--allowedTools", allowedTools]
        if let session {
            arguments += ["--resume", session]
        } else {
            session = mintSession()
            guard let session else {
                fail("Couldn't write agent.session into \(deckPath)")
                return
            }
            arguments += ["--session-id", session]
            text = bootPrompt + "\n\n" + text
        }
        arguments += ["--", text]
        let process = Process()
        if let override = ProcessInfo.processInfo.environment["SHOW_CLAUDE"] {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "export PATH=\"$HOME/.local/bin:$PATH\"; exec claude \"$@\"", "claude"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: ("~/.dotfiles" as NSString).expandingTildeInPath)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        var out = Data()
        var err = Data()
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); out.append(chunk); lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); err.append(chunk); if err.count > 8192 { err = err.suffix(8192) }; lock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            out.append(output.fileHandleForReading.readDataToEndOfFile())
            err.append(errors.fileHandleForReading.readDataToEndOfFile())
            let result = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
            let tail = String(data: err, encoding: .utf8) ?? ""
            lock.unlock()
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                let resultError = result?["is_error"] as? Bool == true ? (result?["result"] as? String ?? result?["subtype"] as? String) : nil
                if status == 0, resultError == nil {
                    let done = self.queue.removeFirst().done
                    done(nil)
                    self.startNext()
                } else {
                    if booting {
                        self.forgetSession()
                    }
                    let lines = tail.split(separator: "\n").suffix(6).joined(separator: "\n")
                    self.fail([resultError, lines.isEmpty ? nil : lines, "exit \(status)"].compactMap { $0 }.joined(separator: "\n"))
                }
            }
        }
        do {
            try process.run()
            running = process
        } catch {
            fail("\(error)")
        }
    }

    /// Fails the head of the queue and everything behind it; Retry sends each again.
    private func fail(_ detail: String) {
        failed = true
        let waiting = queue
        queue = []
        waiting.forEach { $0.done(detail) }
    }
}

/// The conversation under a section's body: Phil's lines right-aligned in his ink, Claude's left-aligned as markdown,
/// then a quiet waiting row (with a Retry link once a delivery fails).
func threadText(_ messages: [ThreadMessage], status: ThreadDelivery.Status?, renderer: Renderer, width: CGFloat) -> NSAttributedString {
    let waiting = messages.last?.isPhil == true || status != nil
    guard !messages.isEmpty || waiting else { return NSAttributedString() }
    let out = NSMutableAttributedString()
    let header = NSMutableParagraphStyle()
    header.paragraphSpacingBefore = 28
    header.paragraphSpacing = 10
    out.append(NSAttributedString(string: "Conversation\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: header]))
    for message in messages {
        if message.isPhil {
            let p = NSMutableParagraphStyle()
            p.alignment = .right
            p.lineSpacing = 3
            p.paragraphSpacing = 14
            p.firstLineHeadIndent = width * 0.25
            p.headIndent = width * 0.25
            out.append(NSAttributedString(string: message.text + "\n", attributes: [.font: inkFont, .foregroundColor: inkColor, .paragraphStyle: p]))
        } else {
            let reply = NSMutableAttributedString(attributedString: renderer.tutorMarkdown(message.text))
            reply.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reply.length)) { value, range, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.tailIndent = -width * 0.12
                reply.addAttribute(.paragraphStyle, value: style, range: range)
            }
            out.append(reply)
        }
    }
    guard waiting else { return out }
    let quiet = NSMutableParagraphStyle()
    quiet.paragraphSpacingBefore = 4
    let small = NSFont.systemFont(ofSize: 12)
    if case .failed(let detail) = status {
        out.append(NSAttributedString(string: "Couldn't deliver this to Claude.  ", attributes: [.font: small, .foregroundColor: NSColor.systemOrange, .paragraphStyle: quiet]))
        out.append(NSAttributedString(string: "Retry", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .link: URL(string: "show-thread:retry")!, .paragraphStyle: quiet]))
        out.append(NSAttributedString(string: "\n" + detail + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quiet]))
    } else {
        out.append(NSAttributedString(string: "Waiting for Claude's reply…\n", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: quiet]))
    }
    return out
}

/// The thread's pen: a serif, ink-blue field pinned under the page that grows with its text; ⌘↩ sends.
final class ThreadComposer: NSTextView {
    var placeholder = "Reply about this section — ⌘↩ sends"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: inkFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
