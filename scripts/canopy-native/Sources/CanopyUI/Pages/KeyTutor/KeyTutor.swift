import CanopyCore
import Foundation
import Observation

/// Where you are in the keytutor, kept across launches.
struct KeyTutorProgress: Codable, Equatable {
    var lesson: String
    var step: Int
    var done: [String]
}

/// Where progress lives: ~/Library/Application Support/canopy-native/keytutor.json, or memory
/// (tests, `--dump`).
protocol KeyTutorProgressStore: AnyObject {
    func load() -> KeyTutorProgress?
    func save(_ p: KeyTutorProgress)
}

final class FileProgress: KeyTutorProgressStore {
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
        return base.appendingPathComponent("canopy-native/keytutor.json")
    }()

    let url: URL
    init(_ url: URL = FileProgress.defaultURL) { self.url = url }

    func load() -> KeyTutorProgress? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(KeyTutorProgress.self, from: $0) } }

    func save(_ p: KeyTutorProgress) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

final class MemoryProgress: KeyTutorProgressStore {
    var saved: KeyTutorProgress?
    init(_ saved: KeyTutorProgress? = nil) { self.saved = saved }
    func load() -> KeyTutorProgress? { saved }
    func save(_ p: KeyTutorProgress) { saved = p }
}

/// One piece of a rendered step: text, or a key (drawn as a keycap).
struct KeyTutorPiece: Equatable {
    var text: String
    var key: Bool
}

/// The keytutor (vimtutor for canopy's keys): lessons run in a practice app — a real AppModel on
/// canned data behind a stub transport (`KeyTutorSandbox`) — that gets every key while the keytutor
/// page is up. A step finishes when the practice app's engine sees the step's VERB fire (whatever key
/// you've given it) with the outcome it wants. esc that cancels nothing in there leaves, back to
/// where you were.
@MainActor
@Observable
final class KeyTutor {
    @ObservationIgnored weak var app: AppModel?
    /// On a practice app's own state: the keytutor running it (whose commands its keys drive).
    @ObservationIgnored weak var host: KeyTutor?
    private(set) var sandbox: AppModel?
    private(set) var lessonIndex = 0
    private(set) var stepIndex = 0
    private(set) var done: Set<String> = []
    /// the lesson's recap is up; ↵, j or esc goes on
    private(set) var recapping = false
    /// every lesson done
    private(set) var finished = false
    /// misses on this step (a different verb, a key that's nothing here)
    private(set) var misses = 0
    /// the step's starting place is set (a diff can take a moment to land)
    private(set) var ready = false
    /// one quiet line: what just happened
    private(set) var said: String?

    @ObservationIgnored var store: KeyTutorProgressStore
    @ObservationIgnored private var events: [VerbEvent] = []
    @ObservationIgnored private var keysSynced = -1
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var outcome: Task<Void, Never>?

    static let lessons = KeyLessons.all

    init(_ app: AppModel) {
        self.app = app
        store = app.config.dump ? MemoryProgress() : FileProgress()
    }

    static func of(_ app: AppModel) -> KeyTutor { app.state { KeyTutor(app) } }

    var lesson: KeyLesson { Self.lessons[lessonIndex] }
    var step: KeyStep? { lesson.steps.indices.contains(stepIndex) ? lesson.steps[stepIndex] : nil }

    // ── the practice app ──

    /// The practice app, made on first use (resuming saved progress), its keys kept to the host's.
    @discardableResult
    func ensureSandbox() -> AppModel {
        if let sandbox {
            syncKeys()
            return sandbox
        }
        let host = app!
        let sb = KeyTutorSandbox.make(overrides: host.registry.lastOverrides, shared: host.registry.lastShared)
        keysSynced = host.registry.keysVersion
        KeyTutor.of(sb).host = self
        sb.keys.onVerb = { [weak self] e in self?.events.append(e) }
        sandbox = sb
        if let p = store.load(), let i = Self.lessons.firstIndex(where: { $0.id == p.lesson }) {
            done = Set(p.done)
            lessonIndex = i
            stepIndex = max(0, min(p.step, Self.lessons[i].steps.count - 1))
        }
        if case .keytutor(let l?) = host.router.route, let i = KeyLessons.match(l) { lessonIndex = i; stepIndex = 0 }
        begin()
        Log.line("keytutor: practice app on port \(sb.config.port ?? 0) · lesson \(lesson.id) step \(stepIndex + 1)")
        return sb
    }

    /// keys-native.toml moved in the host: the practice app follows.
    private func syncKeys() {
        guard let host = app, let sandbox, host.registry.keysVersion != keysSynced else { return }
        keysSynced = host.registry.keysVersion
        sandbox.registry.applyUserKeys(host.registry.lastOverrides, shared: host.registry.lastShared)
    }

    /// The key a verb has now, as it reads (the shortest of its keys; insert's own from normal mode).
    func keyOf(_ v: Verb) -> String {
        let vk = (sandbox ?? app)?.registry.verbKeys ?? .defaults
        let ks = (vk.keys[v] ?? []).isEmpty ? (vk.entry[v] ?? []) : (vk.keys[v] ?? [])
        let best = ks.enumerated().min { a, b in
            let ta = a.element.split(separator: " ").count, tb = b.element.split(separator: " ").count
            return (ta, a.element.count, a.offset) < (tb, b.element.count, b.offset)
        }?.element
        return best.map(glyph) ?? "(no key)"
    }

    /// A step's or recap's text with each `{verb}` as its key now.
    func render(_ text: String) -> [KeyTutorPiece] {
        var out: [KeyTutorPiece] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { out.append(KeyTutorPiece(text: String(rest[..<open]), key: false)) }
            let name = String(rest[rest.index(after: open)..<close])
            if let v = Verb(rawValue: name) { out.append(KeyTutorPiece(text: keyOf(v), key: true)) } else { out.append(KeyTutorPiece(text: "{\(name)}", key: false)) }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(KeyTutorPiece(text: String(rest), key: false)) }
        return out
    }

    func plain(_ text: String) -> String { render(text).map(\.text).joined() }

    /// After a couple of misses: the verb the step wants and your key for it.
    var hint: String? {
        guard misses >= 2, let s = step, !recapping else { return nil }
        if let v = s.wants.first {
            return "this step wants \(v.name) — your key is \(keyOf(v))"
        }
        return s.hint.map(plain)
    }

    // ── keys: the host hands every key on the keytutor page to the practice app, then here ──

    func observe(_ key: String, took: Bool) {
        guard let sb = sandbox else { return }
        let evs = events
        events = []
        if recapping {
            if key == "esc" || evs.contains(where: { $0.verb == .main || $0.verb == .next || $0.verb == .cancel }) { goOn() }
            return
        }
        settle()
        if ready, let s = step {
            let fired = s.wants.isEmpty || evs.contains { $0.verb.map(s.wants.contains) == true }
            if fired, s.check?(sb) ?? true {
                complete()
                return
            }
            // the verb fired; its outcome may still be on its way (a picker the server fills)
            if fired, !s.wants.isEmpty { awaitOutcome() }
        }
        if key == "esc", !sb.keys.lastEscCancelled {
            leave()
            return
        }
        guard let s = step else { return }
        // moving about and typing aren't misses; a different verb, or a key that's nothing here, is
        let wrong = evs.filter { e in
            guard let v = e.verb else { return !e.mode.takesText }
            return !s.wants.contains(v) && v != .next && v != .previous && v != .leader
        }
        misses += wrong.count
    }

    /// Put the practice app where the step starts; if it isn't there yet (a diff loading), keep trying
    /// for a few seconds.
    private func settle() {
        guard !ready, let sb = sandbox else { return }
        if step?.setup?(sb) ?? true {
            ready = true
            settling?.cancel()
            settling = nil
            return
        }
        guard settling == nil else { return }
        settling = Task { @MainActor [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let sb = self.sandbox, !self.ready else { break }
                if self.step?.setup?(sb) ?? true { self.ready = true; break }
            }
            self?.settling = nil
        }
    }

    /// Re-check the step's outcome for a few seconds after its verb fired.
    private func awaitOutcome() {
        let at = (lessonIndex, stepIndex)
        outcome?.cancel()
        outcome = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, (self.lessonIndex, self.stepIndex) == at, !self.recapping,
                      let sb = self.sandbox, let s = self.step else { return }
                if s.check?(sb) ?? true { self.complete(); return }
            }
        }
    }

    private func begin() {
        ready = false
        misses = 0
        events = []
        outcome?.cancel()
        outcome = nil
        settling?.cancel()
        settling = nil
        settle()
    }

    private func complete() {
        said = "✓ \(plain(step?.text ?? "").prefix(60))"
        stepIndex += 1
        misses = 0
        if stepIndex >= lesson.steps.count {
            done.insert(lesson.id)
            recapping = true
            sandbox?.keys.openLayer(.keytutorRecap)
        } else {
            begin()
        }
        save()
    }

    /// From the recap, on to the next lesson (or the end).
    func goOn() {
        recapping = false
        if sandbox?.keys.layer == .keytutorRecap { sandbox?.keys.closeLayer() }
        if lessonIndex + 1 < Self.lessons.count {
            go(lesson: lessonIndex + 1)
        } else {
            finished = true
            said = "that's every lesson — :keytutor <lesson> goes back to any one"
            save()
        }
    }

    func go(lesson i: Int, step s: Int = 0) {
        guard Self.lessons.indices.contains(i) else { return }
        recapping = false
        finished = false
        if sandbox?.keys.layer == .keytutorRecap { sandbox?.keys.closeLayer() }
        if let sb = sandbox, sb.keys.mode != .normal { sb.keys.setMode(.normal) }
        lessonIndex = i
        stepIndex = max(0, min(s, Self.lessons[i].steps.count - 1))
        begin()
        save()
    }

    func skip() {
        guard step != nil, !recapping else { return }
        said = "skipped"
        complete()
    }

    private func save() {
        store.save(KeyTutorProgress(lesson: lesson.id, step: stepIndex, done: Self.lessons.map(\.id).filter(done.contains)))
    }

    // ── entering and leaving ──

    /// `:keytutor [lesson]`: open the keytutor where you left off, or at the lesson named (fuzzy).
    func open(_ want: String?) throws {
        if let host { return try host.open(want) }
        guard let app else { return }
        ensureSandbox()
        if let want, !want.isEmpty {
            guard let i = KeyLessons.match(want) else { throw Refusal("no lesson like \(want) — try \(Self.lessons.map(\.id).joined(separator: ", "))") }
            go(lesson: i)
        }
        if app.router.route.surfaceID != "keytutor" { app.go(.keytutor(lesson: nil)) }
    }

    /// Back to where you were before the keytutor (the jumplist), else Forests.
    func leave() {
        if let host { return host.leave() }
        guard let app, app.router.route.surfaceID == "keytutor" else { return }
        if !app.jumpBack() || app.router.route.surfaceID == "keytutor" { app.go(.forests) }
        app.runner.say("left the keytutor — :keytutor picks up where you were")
    }

    // ── --dump ──

    func dump() -> JSONValue {
        guard let sb = sandbox else { return ["started": false, "lessons": .number(Double(Self.lessons.count))] }
        let port = sb.config.port ?? 0
        let reqs = KeyTutorStub.requests(port)
        return [
            "started": true, "lessons": .number(Double(Self.lessons.count)),
            "lesson": .string(lesson.id), "step": .number(Double(stepIndex + 1)), "text": .string(plain(step?.text ?? lesson.recap)),
            "practiceRoute": .string(sb.router.route.path), "practicePort": .number(Double(port)),
            "practiceKeyProblems": .array(sb.registry.keyProblems.map(JSONValue.string)),
            "practiceKeyboardRule": .array(KeyboardRule.violations(sb).map(JSONValue.string)),
            "stubbedRequests": .number(Double(reqs.count)),
            "offStub": .array(reqs.filter { $0.host != "127.0.0.1" || $0.port != port }.map { .string("\($0.method) \($0.host):\($0.port)\($0.path)") }),
        ]
    }
}

extension KeyMode {
    /// the keytutor's recap between lessons: ↵ or j goes on, esc too
    static let keytutorRecap: KeyMode = "keytutor-recap"
}
