import AppKit
import CanopyCore

/// One line of a section's conversation in `<deck>.thread.json`: Show appends Phil's, the deck's author appends Claude's.
/// A reply in a work-bound section also carries the `id`, `seq` and `work` the work journal captured it under.
struct ThreadMessage: Codable {
    let at: String
    let from: String
    let text: String
    var id: String? = nil
    var seq: Int? = nil
    var work: String? = nil

    var isPhil: Bool { from != "claude" }
}

func threadURL(_ deckPath: String) -> URL {
    URL(fileURLWithPath: deckPath).deletingPathExtension().appendingPathExtension("thread.json")
}

func loadThread(_ deckPath: String) -> [String: [ThreadMessage]] {
    (try? JSONDecoder().decode([String: [ThreadMessage]].self, from: Data(contentsOf: threadURL(deckPath)))) ?? [:]
}

/// Appends one message to a section's thread, keeping every other entry exactly as the author wrote it. The thread file
/// is what Claude reads; a work-bound reply is projected here only after the work journal captured it, with its id,
/// sequence and work, and projecting the same id twice changes nothing.
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
    var entry: [String: Any] = ["at": message.at, "from": message.from, "text": message.text]
    if let id = message.id {
        if list.contains(where: { ($0 as? [String: Any])?["id"] as? String == id }) { return }
        entry["id"] = id
        if let seq = message.seq { entry["seq"] = seq }
        if let work = message.work { entry["work"] = work }
    }
    list.append(entry)
    raw[key] = list
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
}

/// The work journal's command line; `SHOW_CANOPY_WORK` swaps in a stub for testing.
var canopyWorkPath: String {
    ProcessInfo.processInfo.environment["SHOW_CANOPY_WORK"] ?? ("~/.dotfiles/scripts/canopy-work" as NSString).expandingTildeInPath
}

/// Runs `canopy-work` with `input` on stdin and returns its exit status, parsed JSON output and error text.
func canopyWork(_ arguments: [String], input: Data? = nil) -> (status: Int32, json: [String: Any]?, error: String) {
    let process = Zsh.process("exec \"$0\" \"$@\"", [canopyWorkPath] + arguments)
    let output = Pipe()
    let errors = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    do {
        try process.run()
    } catch {
        return (-1, nil, "\(error)")
    }
    if let input {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, (try? JSONSerialization.jsonObject(with: out)) as? [String: Any], String(data: err, encoding: .utf8) ?? "")
}

/// The `claude-say` binary; `SHOW_CLAUDE_SAY` swaps in a stub for testing.
var claudeSayPath: String {
    ProcessInfo.processInfo.environment["SHOW_CLAUDE_SAY"] ?? ("~/.dotfiles/scripts/claude-say" as NSString).expandingTildeInPath
}

/// Whether `replyTo` resolves to one live, deliverable Claude session, by `claude-say <who> --check` (it sends nothing).
func claudeSessionReachable(_ replyTo: String) -> Bool {
    let process = Zsh.process("exec \"$0\" \"$@\"", [claudeSayPath, replyTo, "--check"])
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
        /// Handed to the session without a confirmed submission; only a deliberate Retry sends it again.
        case uncertain(String)
        /// Captured, waiting for Claude's current turn to end; it goes then by itself.
        case queued
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
    private var pendingWork: [String: (outbox: Int, headless: Bool)] = [:]
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

    /// A work-bound section's binding, read when the section's deck is opened: the work the conversation directs, frozen
    /// until someone rebinds it. `replaced` means the tracker record was deleted or recreated since; Show won't send then.
    struct Binding: Codable, Equatable {
        let workId: String
        let todo: String
        let generation: Int
        let replaced: Bool
    }

    /// A reply Phil sent: its stable id, literal text, the binding it was written under and the draft revision it came
    /// from. Every one is kept, by id, until the work journal has captured it.
    struct Submission: Codable, Equatable {
        let id: String
        let section: String
        let text: String
        let workId: String
        let generation: Int
        let sentAt: String
        let draftRevision: Int
    }

    private(set) var bindings: [String: Binding] = [:]
    private let captureLane = DispatchQueue(label: "show.thread.capture")
    /// Advances each time a section starts capturing a reply: a slower answer begun before it can't overwrite its state.
    private(set) var captureGeneration: [String: Int] = [:]
    /// The receipt of each section's current delivery: a turn watcher acts only while its receipt is still this one.
    private var currentReceipt: [String: String] = [:]
    /// How often a delivered turn and a queued delivery are rechecked; tests shorten them.
    static var turnPoll: TimeInterval = 3
    static var queuePoll: TimeInterval = 5

    /// Called on the main thread once the journal holds a submission, with its sequence number.
    var onCaptured: ((_ submission: Submission, _ seq: Int) -> Void)?

    private var pendingKey: String { "thread.submit.\(deckPath)" }

    func pendingSubmissions() -> [String: Submission] {
        guard let data = prefs.data(forKey: pendingKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Submission].self, from: data)) ?? [:]
    }

    private func setPending(_ update: (inout [String: Submission]) -> Void) {
        var all = pendingSubmissions()
        update(&all)
        if all.isEmpty {
            prefs.removeObject(forKey: pendingKey)
        } else if let data = try? JSONEncoder().encode(all) {
            prefs.set(data, forKey: pendingKey)
        }
    }

    /// Reads (establishing on first use) each work-bound section's binding, then resubmits whatever a crash or quit left
    /// uncaptured, oldest first.
    func open(sections: [(key: String, todo: String, replyTo: String?)]) {
        let deck = deckPath
        captureLane.async { [weak self] in
            var found: [String: Binding] = [:]
            for section in sections {
                let r = canopyWork(["show-bind", "--deck", deck, "--section", section.key, "--todo", section.todo])
                if r.status == 0, let j = r.json, let work = j["work_id"] as? String, let generation = j["generation"] as? Int {
                    found[section.key] = Binding(workId: work, todo: section.todo, generation: generation, replaced: j["replaced"] as? Bool ?? true)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.bindings.merge(found) { _, new in new }
                let replyTo = Dictionary(sections.map { ($0.key, $0.replyTo) }, uniquingKeysWith: { a, _ in a })
                for pending in self.pendingSubmissions().values.sorted(by: { $0.sentAt < $1.sentAt }) {
                    self.capture(pending, replyTo: replyTo[pending.section] ?? nil)
                }
                self.recover(sections.map(\.key))
            }
        }
    }

    /// Why a section can't send now, or nil: its binding isn't read yet, or its record was replaced.
    func refusal(_ section: String) -> String? {
        guard let binding = bindings[section] else { return "This section's work binding isn't available yet." }
        return binding.replaced ? "\(binding.todo) was deleted or recreated since this section was bound to it. Rebind it deliberately (canopy-work show-bind --rebind) before replying." : nil
    }

    /// Keeps the submission until the journal holds it, then captures it (fast) and delivers it (separately, may be slow).
    func submit(_ submission: Submission, replyTo: String?) {
        setPending { $0[submission.id] = submission }
        capture(submission, replyTo: replyTo)
    }

    private func capture(_ submission: Submission, replyTo: String?) {
        let key = submission.section
        captureGeneration[key, default: 0] += 1
        status[key] = .sending
        onChange?()
        captureLane.async { [weak self] in
            guard let self else { return }
            var arguments = ["show-submit", "--note", self.threadLine(section: key)]
            var headless = false
            if let replyTo, !replyTo.isEmpty, claudeSessionReachable(replyTo) {
                arguments += ["--target", "claude-say:\(replyTo)"]
            } else if let session = DeckAgent.sessionID(self.deckPath) ?? self.agent.mintSession() {
                let boot = FileManager.default.temporaryDirectory.appendingPathComponent("show-boot-\(session).txt")
                try? self.agent.bootPrompt.write(to: boot, atomically: true, encoding: .utf8)
                arguments += ["--target", "claude-headless:\(session)", "--host-session", session,
                              "--host-cwd", ("~/.dotfiles" as NSString).expandingTildeInPath,
                              "--allowed-tools", self.agent.allowedTools, "--boot-prompt-file", boot.path]
                headless = true
            } else {
                DispatchQueue.main.async { self.finish(key, failure: "Couldn't name a session to deliver to. Your reply is kept and resent when the deck opens.") }
                return
            }
            let envelope: [String: Any] = ["message_id": submission.id, "text": submission.text, "deck": self.deckPath, "section": key,
                                           "work_id": submission.workId, "generation": submission.generation, "sent_at": submission.sentAt]
            let result = canopyWork(arguments, input: (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data())
            let seq = result.json?["seq"] as? Int
            let outbox = result.json?["outbox_id"] as? Int
            DispatchQueue.main.async {
                guard result.status == 0, let seq, let outbox else {
                    self.finish(key, failure: "Your reply wasn't captured for its work item, so it wasn't sent; it's kept and resent when the deck opens.\n" + result.error)
                    return
                }
                self.setPending { $0[submission.id] = nil }
                self.onCaptured?(submission, seq)
                self.pendingWork[key] = (outbox, headless)
                self.currentReceipt[key] = nil
                self.deliver(key, outbox: outbox, headless: headless, retry: false)
            }
        }
    }

    /// Opening the deck: the journal resumes each section's safe pending deliveries and reports where every one stands.
    /// Recovery dispatches, so it may wait on a worker's host: it runs on the delivery lane, never ahead of a new reply's
    /// capture, and a section that captured anything since recovery began keeps its own state.
    private func recover(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let deck = deckPath
        let started = captureGeneration
        lane.async { [weak self] in
            let result = canopyWork(["show-recover", "--deck", deck] + keys.flatMap { ["--section", $0] })
            let sections = result.json?["sections"] as? [String: [String: Any]] ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                for (key, row) in sections {
                    guard self.captureGeneration[key] == started[key],
                          let outbox = row["outbox_id"] as? Int, self.pendingWork[key] == nil || self.pendingWork[key]?.outbox == outbox else { continue }
                    let headless = (row["target"] as? String)?.hasPrefix("claude-headless:") == true
                    self.pendingWork[key] = (outbox, headless)
                    self.show(key, outbox: outbox, headless: headless, delivery: row)
                }
            }
        }
    }

    /// Shows one delivery's state on its section: confirmed and its turn followed, queued and polled, uncertain, or failed.
    private func show(_ key: String, outbox: Int, headless: Bool, delivery: [String: Any]?) {
        let turn = (delivery?["turn"] as? [String: Any])?["state"] as? String
        switch delivery?["state"] as? String {
        case "delivered":
            if turn == "failed" || turn == "lost" {
                finish(key, failure: "Claude's turn \(turn == "lost" ? "stopped without a record" : "failed"): \(((delivery?["turn"] as? [String: Any])?["detail"] as? String) ?? "")")
                return
            }
            status[key] = nil
            onChange?()
            if headless, let receipt = delivery?["receipt_id"] as? String, turn != "succeeded" { watchTurn(key, outbox: outbox, receipt: receipt) }
        case "uncertain":
            status[key] = .uncertain((delivery?["error"] as? String) ?? "not confirmed")
            onChange?()
        case "pending" where (delivery?["error"] as? String)?.contains("turn") == true, "leased":
            status[key] = .queued
            onChange?()
            lane.asyncAfter(deadline: .now() + Self.queuePoll) { [weak self] in
                DispatchQueue.main.async { self?.deliver(key, outbox: outbox, headless: headless, retry: false) }
            }
        case let state:
            finish(key, failure: (delivery?["error"] as? String) ?? state ?? "not delivered")
        }
    }

    private func deliver(_ key: String, outbox: Int, headless: Bool, retry: Bool) {
        lane.async { [weak self] in
            var arguments = ["show-deliver", "--outbox", String(outbox)]
            if retry { arguments.append("--retry") }
            let result = canopyWork(arguments)
            let delivery = result.json?["delivery"] as? [String: Any]
            DispatchQueue.main.async {
                guard let self, self.pendingWork[key]?.outbox == outbox else { return }
                self.show(key, outbox: outbox, headless: headless, delivery: delivery ?? ["state": "failed", "error": result.error])
            }
        }
    }

    /// Follows the owned host's turn for a delivered reply until it ends; a failed or vanished turn shows as a failure
    /// instead of leaving the section waiting.
    /// Follows one delivery's turn. Every step first checks the delivery is still the section's current one (same outbox
    /// row and receipt), so an older reply's turn can never overwrite a newer reply's status.
    private func watchTurn(_ key: String, outbox: Int, receipt: String) {
        currentReceipt[key] = receipt
        lane.asyncAfter(deadline: .now() + Self.turnPoll) { [weak self] in
            guard let self else { return }
            let state = canopyWork(["turn", "--receipt", receipt]).json
            let name = state?["state"] as? String ?? "unknown"
            DispatchQueue.main.async {
                guard self.pendingWork[key]?.outbox == outbox, self.currentReceipt[key] == receipt else { return }
                switch name {
                case "running", "unknown":
                    self.watchTurn(key, outbox: outbox, receipt: receipt)
                case "failed", "lost":
                    self.finish(key, failure: "Claude's turn \(name == "lost" ? "stopped without a record" : "failed"): \((state?["detail"] as? String) ?? "")")
                default:
                    break
                }
            }
        }
    }

    func retry(_ key: String) {
        if let work = pendingWork[key] {
            status[key] = .sending
            onChange?()
            deliver(key, outbox: work.outbox, headless: work.headless, retry: true)
            return
        }
        if let pending = pendingSubmissions().values.filter({ $0.section == key }).min(by: { $0.sentAt < $1.sentAt }) {
            capture(pending, replyTo: nil)
            return
        }
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

    func mintSession() -> String? {
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

    var bootPrompt: String {
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
            process.executableURL = URL(fileURLWithPath: Zsh.path)
            process.arguments = Zsh.arguments("exec claude \"$@\"", ["claude"] + arguments)
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
    if case .queued = status {
        out.append(NSAttributedString(string: "Queued: Claude is mid-turn; your reply goes when that turn ends.\n", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: quiet]))
    } else if case .uncertain(let detail) = status {
        out.append(NSAttributedString(string: "Handed to Claude's session, but its submission wasn't confirmed.  ", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quiet]))
        out.append(NSAttributedString(string: "Send again", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .link: URL(string: "show-thread:retry")!, .paragraphStyle: quiet]))
        out.append(NSAttributedString(string: "\n" + detail + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quiet]))
    } else if case .failed(let detail) = status {
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
