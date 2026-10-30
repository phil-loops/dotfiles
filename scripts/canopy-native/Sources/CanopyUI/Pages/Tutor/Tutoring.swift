import CanopyCore
import Foundation
import Observation

/// The tutor's state (tutoring.ts): the learner's concept graph (GET /learning-state, re-read after
/// every turn and every audit), the sessions this app keeps, and the turn streaming now. A turn is
/// POST /tutor, answered as server-sent events — a headless read-only claude, so starting or
/// answering one spends a model call; the next launch re-attaches to a turn still running (a body
/// with only its turn id never starts one). The graph itself is written by the server, never here.
///
/// Published for other areas: `learn` / `load()` (the space menu's concept finder reads them).
@MainActor
@Observable
final class TutorState {
    @ObservationIgnored weak var app: AppModel?
    /// The server door. Tests swap in a stubbed transport.
    @ObservationIgnored var transport: Transport
    /// Where sessions persist (the web app's localStorage); nil keeps them in memory (tests).
    @ObservationIgnored var sessionsFile: URL?
    /// The re-join loop's pause and patience (≈ a minute, as the web app).
    @ObservationIgnored var retryDelay: Duration = .seconds(1)
    @ObservationIgnored var maxTries = 60
    @ObservationIgnored var newID: () -> String = { UUID().uuidString.lowercased() }

    var sessions: [Session] = []
    var learn: LearnState?
    var learnErr = ""
    @ObservationIgnored private var reading = false

    var drawer: String?
    var pin: Pin?
    var code: CodeSrc?
    var streaming = false
    var status = ""
    var evidenceOpen = false
    var mapOpen = true
    var historyOpen = false
    var expanded: Int?
    var allDue = false
    var confidence: String?
    var askedConfidence = false
    /// what's typed: the home page's "dig into", the answer box, the drawer's question
    var target = ""
    var draft = ""
    var question = ""
    var terminal: [TerminalSession] = []
    var error = ""
    /// a two-press removal waiting for its second press ("forget <id>", "cut <id>")
    var armed: String?
    /// the pane focus was on when the drawer opened, to return to
    @ObservationIgnored var beforeDrawer: String?


    nonisolated static let defaultSessionsFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
        return base.appendingPathComponent("canopy-native/tutor-sessions.json")
    }()

    init(app: AppModel, sessionsFile: URL? = TutorState.defaultSessionsFile) {
        self.app = app
        self.transport = app.transport
        self.sessionsFile = sessionsFile
        sessions = Self.loadSessions(sessionsFile)
    }

    static func loadSessions(_ file: URL?) -> [Session] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    func save() {
        guard let file = sessionsFile, let data = try? JSONEncoder().encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func at(_ id: String) -> Int? { sessions.firstIndex { $0.id == id } }

    private func edit(_ id: String, _ f: (inout Session) -> Void) {
        guard let i = at(id) else { return }
        f(&sessions[i])
    }

    var recent: [Session] { sessions.sorted { $0.touched > $1.touched } }

    /// The session the route names (/v2/tutor/<id>), or nil on the home page.
    var activeID: String? {
        guard let app, case .tutor(let s?) = app.router.route else { return nil }
        return s
    }

    var active: Session? { activeID.flatMap { id in sessions.first { $0.id == id } } }

    // ── the graph ──

    func refresh() {
        if reading { return }
        reading = true
        let t = transport
        Task { @MainActor in
            defer { self.reading = false }
            do {
                self.learn = try await t.getJSON("/learning-state", as: LearnState.self)
                self.learnErr = ""
            } catch {
                self.learnErr = String(describing: error)
            }
        }
    }

    /// Read the graph if it hasn't been yet — the menu's finder asks too.
    func load() { if learn == nil { refresh() } }

    func concept(_ id: String?) -> Concept? { id.flatMap { learn?.concepts[$0] } }
    func nameOf(_ id: String) -> String { concept(id)?.name ?? id.replacingOccurrences(of: "-", with: " ") }
    func titleOf(_ s: Session) -> String {
        if let t = s.topic, let title = learn?.topics[t]?.title, !title.isEmpty { return title }
        return s.target
    }
    var due: [String] { learn?.due ?? [] }
    var shownDue: [String] { allDue ? due : Array(due.prefix(8)) }
    var openQuestions: [Question] { (learn?.questions ?? []).filter { $0.status == "open" } }
    var topicsByUpdate: [Topic] { (learn?.topics.values.map { $0 } ?? []).sorted { ($0.updated ?? "", $1.id) > ($1.updated ?? "", $0.id) } }

    // ── the code pane follows the pin ──

    @ObservationIgnored private var pinned = ""

    func showPin(_ p: Pin?) {
        pin = p
        let key = p.map { "\($0.ref ?? ""):\($0.path)" } ?? ""
        if key == pinned { return }
        pinned = key
        code = nil
        guard let p else { return }
        let t = transport
        let path = "/tutor-src?path=\(p.path.uriComponent)&ref=\((p.ref ?? "").uriComponent)"
        Task { @MainActor in
            do {
                let c = try await t.getJSON(path, as: CodeSrc.self)
                if self.pinned == key { self.code = c }
            } catch {
                if self.pinned == key { self.code = CodeSrc(path: p.path, ref: p.ref ?? "", text: "", err: String(describing: error)) }
            }
        }
    }

    /// The session's newest pin, when it changes (a pin chosen from a turn or the drawer stays until then).
    @ObservationIgnored private var newestPinSeen: String?
    func followNewestPin(_ s: Session) {
        let newest: Pin? = { if case .pin(let p)? = Lesson.latest(s.msgs, .pin) { return p }; return nil }()
        let key = "\(s.id)|\(newest.map { "\($0.ref ?? ""):\($0.path):\($0.lines ?? [])" } ?? "")"
        guard key != newestPinSeen else { return }
        newestPinSeen = key
        showPin(newest)
    }

    /// The current rung asks for a confidence rating before the reveal.
    var wantsConfidence: Bool {
        guard let last = active?.msgs.last, last.role == "tutor" else { return false }
        for seg in Lesson.segments(last.text) { if case .rung(_, _, _, let c, _, _) = seg { return c } }
        return false
    }

    /// The concept the current rung tests — "you are here" on the map.
    var here: String? {
        guard let s = active, case .rung(let c, _, _, _, _, _)? = Lesson.latest(s.msgs, .rung) else { return nil }
        return c
    }

    // ── turns ──

    /// One turn, streamed: POST /tutor; a dropped stream (the server restarting) is re-joined by
    /// turn id and replayed from its start, until the turn ends or about a minute passes.
    func runTurn(_ id: String, _ first: [String: String], reattach: Bool = false) async {
        guard let s0 = sessions.first(where: { $0.id == id }) else { return }
        edit(id) { $0.pendingTurn = first["turn"]; $0.lastActive = Date().timeIntervalSince1970 * 1000; $0.error = nil }
        save()
        streaming = true
        status = "thinking"
        var body = first
        body["tab"] = id
        if let t = s0.topic { body["topic"] = t }
        if let c = s0.cwd { body["cwd"] = c }
        if s0.forkNext == true && body["resume"] != nil { body["fork"] = "1" }
        if let p = s0.primed { body["primed"] = p }
        var tutorIdx = s0.msgs.count - 1
        var reset = reattach
        var ended = false

        func removeEmptyTutor() {
            edit(id) { s in
                if s.msgs.indices.contains(tutorIdx), s.msgs[tutorIdx].role == "tutor", s.msgs[tutorIdx].text.isEmpty { s.msgs.remove(at: tutorIdx) }
            }
        }

        let frame: (SSEFrame) -> Bool = { [weak self] f in
            guard let self else { return true }
            let p = f.json ?? [:]
            switch f.event {
            case "session":
                if jsTruthy(p["session_id"]) {
                    let sid = jsString(p["session_id"])
                    self.edit(id) { s in
                        s.sessionId = sid
                        if sid != s.importedFrom { s.forkNext = false }
                    }
                }
            case "token":
                if reset {
                    self.edit(id) { s in if s.msgs.indices.contains(tutorIdx) { s.msgs[tutorIdx].text = "" } }
                    reset = false
                }
                self.status = ""
                let t = jsString(p["t"])
                self.edit(id) { s in if s.msgs.indices.contains(tutorIdx) { s.msgs[tutorIdx].text += t } }
            case "tool":
                self.status = "reading · \(jsTruthy(p["arg"]) ? jsString(p["arg"]) : jsString(p["name"]))"
            case "status":
                if p["s"]?.string == "thinking" { self.status = "thinking" }
            case "graph":
                if jsTruthy(p["topic"]) { let t = jsString(p["topic"]); self.edit(id) { $0.topic = t } }
                if jsTruthy(p["protocol"]) { let pr = jsString(p["protocol"]); self.edit(id) { $0.primed = pr } }
                if let errors = p["errors"]?.array, !errors.isEmpty {
                    let line = "graph: " + errors.map { jsString($0) }.joined(separator: "; ")
                    self.edit(id) { $0.error = line }
                }
                self.refresh()
            case "gone":
                self.edit(id) { $0.error = "that turn was lost (the server restarted) — send your answer again" }
                removeEmptyTutor()
                tutorIdx = -1
            case "error":
                let e = jsTruthy(p["err"]) ? jsString(p["err"]) : "the turn failed"
                self.edit(id) { $0.error = e }
            case "done":
                if jsTruthy(p["stopped"]) { removeEmptyTutor() }
            default:
                break
            }
            ended = f.event == "done" || f.event == "error" || f.event == "gone"
            return ended
        }

        do {
            var tries = 0
            while true {
                do {
                    try await follow(body, frame)
                } catch {
                    if tries >= maxTries { throw error }
                }
                if ended { break }
                if tries >= maxTries { throw Refusal("lost the turn's stream") }
                status = "reconnecting"
                try? await Task.sleep(for: retryDelay)
                var again: [String: String] = ["turn": body["turn"] ?? "", "tab": body["tab"] ?? id]
                if let t = body["topic"] { again["topic"] = t }
                if let c = body["cwd"] { again["cwd"] = c }
                body = again
                reset = true
                tries += 1
            }
        } catch {
            let e = String(describing: error)
            edit(id) { $0.error = e }
        }
        edit(id) { $0.pendingTurn = nil }
        save()
        streaming = false
        status = ""
    }

    /// The turn's frames, handled here on the main actor: `Transport.streamPost` calls its `on` off
    /// it, so the stream is pumped through an AsyncStream; it stops at the frame that ends a turn.
    private func follow(_ body: [String: String], _ handle: (SSEFrame) -> Bool) async throws {
        let (frames, cont) = AsyncStream.makeStream(of: SSEFrame.self)
        let t = transport
        let pump = Task.detached {
            defer { cont.finish() }
            try await t.streamPost("/tutor", body) { f in
                cont.yield(f)
                return TutorState.ends(f.event)
            }
        }
        for await f in frames where handle(f) { break }
        try await pump.value
    }

    nonisolated static func ends(_ event: String) -> Bool { event == "done" || event == "error" || event == "gone" }

    /// A new session on `goal` (a PR, a branch, a concept, a re-test) — it opens at once and streams in.
    @discardableResult
    func start(_ goal: String, topic: String? = nil) -> Task<Void, Never> {
        let id = newID()
        sessions.insert(Session(id: id, target: goal, created: Date().timeIntervalSince1970 * 1000, sessionId: "", msgs: [.tutor("")], topic: topic), at: 0)
        closeDrawer()
        app?.go(.tutor(session: id))
        let turn = newID()
        return Task { await self.runTurn(id, ["turn": turn, "target": goal]) }
    }

    /// Send an answer (or a question) into a session — a rung that froze a sim plays it now, and
    /// the answer carries what the system did for the tutor to record.
    @discardableResult
    func answer(_ id: String, _ said: String) -> Task<Void, Never>? {
        guard let s = sessions.first(where: { $0.id == id }), !streaming, !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = said + played(s.msgs.last?.role == "tutor" ? s.msgs.last!.text : "")
        edit(id) { $0.msgs += [.me(text), .tutor("")] }
        let turn = newID()
        return Task { await self.runTurn(id, ["turn": turn, "answer": text, "resume": s.sessionId]) }
    }

    func played(_ turn: String) -> String {
        guard let seg = Lesson.segments(turn).first(where: { $0.kind == .sim }), case .sim(let scenario, let off) = seg,
              let sim = SimScenarios.sim(scenario, off: off) else { return "" }
        let r = sim.runToEnd()
        return "\n\n" + Lesson.simResultFence(scenario: scenario, off: off, outcome: r.outcome, divergence: r.divergence)
    }

    func forget(_ id: String) {
        sessions.removeAll { $0.id == id }
        save()
    }

    /// A terminal /tutor session, continued here as a fork; its own transcript is left alone.
    func pickUp(_ session: String) async throws {
        if let kept = sessions.first(where: { $0.importedFrom == session && $0.saved != true }) {
            app?.go(.tutor(session: kept.id))
            return
        }
        let r = try await transport.getJSON("/tutor-import?session=\(session.uriComponent)", as: ImportReply.self)
        if let e = r.err { throw Refusal(e) }
        let id = newID()
        let cwd = r.cwd ?? ""
        let target = (r.target ?? "").isEmpty ? "picked up from the terminal · \(Self.worktreeName(cwd))" : r.target!
        sessions.insert(Session(id: id, target: target, created: Date().timeIntervalSince1970 * 1000, sessionId: r.session ?? session, msgs: r.msgs ?? [],
                                cwd: cwd, forkNext: true, importedFrom: r.session ?? session), at: 0)
        save()
        app?.go(.tutor(session: id))
    }

    static func worktreeName(_ cwd: String) -> String { cwd.split(separator: "/").last.map(String.init) ?? cwd }

    func listTerminal() {
        let t = transport
        Task { @MainActor in
            self.terminal = (try? await t.getJSON("/tutor-terminal", as: [TerminalSession].self)) ?? []
        }
    }

    var pickable: [TerminalSession] {
        let ours = Set(sessions.flatMap { [$0.sessionId, $0.importedFrom ?? ""] })
        return terminal.filter { !ours.contains($0.session) }
    }

    @ObservationIgnored private var attached = false
    /// Once per launch: re-attach to turns a quit interrupted, so their replies still land.
    func reattach() {
        if attached { return }
        attached = true
        for s in sessions where s.pendingTurn != nil {
            let turn = s.pendingTurn!
            Task { await self.runTurn(s.id, ["turn": turn], reattach: true) }
        }
    }

    // ── the drawer (a pane of its own while it's open) ──

    func openDrawer(_ id: String) {
        guard let app else { drawer = id; return }
        if drawer == nil, let here = app.pane?.id, here != TutorPane.drawer { beforeDrawer = here }
        drawer = id
        app.focus(pane: TutorPane.drawer)
        app.cursorTo(0)
    }

    func closeDrawer() {
        guard drawer != nil else { return }
        drawer = nil
        if let app, let back = beforeDrawer { app.focus(pane: back) }
        beforeDrawer = nil
    }
}
