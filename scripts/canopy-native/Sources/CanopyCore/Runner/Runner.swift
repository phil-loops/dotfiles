import Foundation
import Observation

/// What the runner needs from the app around it: what a scope's command acts on, which scopes are
/// live, and the menu to close. The shell's AppModel implements it from the page providers.
@MainActor
public protocol CommandContext: AnyObject {
    /// What a command of this scope acts on, from the cursor (model.ts targetFor).
    func target(for scope: Scope) -> String?
    /// The live scopes, narrowest first (model.ts liveScopes).
    func liveScopes() -> [Scope]
    /// A command ran from the menu or palette: close it.
    func closeMenu()
}

/// A write's live state, for a button that becomes its own status (runner.ts Run).
public struct Run: Equatable, Sendable {
    public enum State: String, Sendable { case sending, landing, done, failed }
    public var state: State
    public var t0: Date
    public var t1: Date?
    public var err: String?
}

/// The command runner — a port of runner.ts, the one way an action happens. A run applies its
/// effect at once (a local change, or a write's optimistic overlay), posts the write in the
/// background on a FIFO queue, keeps the overlay until the server's copy agrees (or 5s pass), and
/// rolls back with a quiet line if the server refuses. Every run emits one `cmd` event.
@MainActor
@Observable
public final class Runner {
    /// The quiet line at the bottom of the window.
    public private(set) var note: String?
    /// The command a key just ran (ok) or that had nothing to do (not ok), for ~half a second.
    public private(set) var fired: (id: String, ok: Bool, at: Date)?
    public private(set) var runs: [String: Run] = [:]

    @ObservationIgnored public let registry: CommandRegistry
    @ObservationIgnored public let store: Store
    @ObservationIgnored public let transport: Transport
    @ObservationIgnored public let telemetry: Telemetry
    @ObservationIgnored public weak var context: CommandContext?

    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var tail: Task<Sent, Never>?
    @ObservationIgnored private var undo: [Inverse] = []
    @ObservationIgnored private var awaiting: [Int: (settled: () -> Bool, done: () -> Void)] = [:]
    @ObservationIgnored private var noteGen = 0
    @ObservationIgnored private var firedGen = 0
    public static let settleWait: TimeInterval = 5

    public init(registry: CommandRegistry, store: Store, transport: Transport, telemetry: Telemetry) {
        self.registry = registry
        self.store = store
        self.transport = transport
        self.telemetry = telemetry
        _ = store.onChange { [weak self] in
            guard let self else { return }
            for (_, a) in self.awaiting where a.settled() { a.done() }
        }
    }

    /// The quiet line, for a command that says what happened itself.
    public func say(_ text: String) {
        note = text
        noteGen += 1
        let g = noteGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.noteGen == g { self?.note = nil }
        }
    }

    private func echo(_ id: String, _ via: Via, _ ok: Bool) {
        guard via == .key else { return }
        let at = Date()
        fired = (id, ok, at)
        firedGen += 1
        let g = firedGen
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.6 : 1.4)) { [weak self] in
            if self?.firedGen == g { self?.fired = nil }
        }
        if !ok { say("\(glyph(registry.command(id)?.keys.first ?? "")) · nothing here") }
    }

    /// Run a registered command. Never awaited by callers — the UI has already moved.
    public func dispatch(_ id: String, via: Via, target explicit: String? = nil, arg: Any? = nil, undoing: Bool = false, from: String? = nil) {
        guard let cmd = registry.command(id) else { return }
        if via == .menu || via == .palette { context?.closeMenu() }
        let named = from ?? id
        if let route = cmd.route {
            let next = route(explicit ?? context?.target(for: cmd.scope))
            if let next, next.id != id {
                dispatch(next.id, via: via, target: next.target ?? explicit, arg: next.arg ?? arg, undoing: undoing, from: named)
            } else {
                echo(named, via, false)
            }
            return
        }
        let t0 = Date()
        let target = explicit ?? context?.target(for: cmd.scope)
        if let available = cmd.available, !available(target) { return echo(named, via, false) }
        var base: JSONObject = ["type": "cmd", "id": .string(id), "budget": .string(cmd.budget.rawValue), "via": .string(via.rawValue)]
        if let target { base["target"] = .string(target) }
        let feedback = { (extra: JSONObject) in
            DispatchQueue.main.async { [weak self] in
                var e = base
                e["feedbackMs"] = .number((Date().timeIntervalSince(t0) * 10000).rounded() / 10)
                e.merge(extra) { $1 }
                self?.telemetry.emit(e)
            }
        }

        if let local = cmd.local {
            do {
                try local(target, arg)
                echo(named, via, true)
                feedback(["outcome": "ok", "settledMs": nil])
            } catch {
                let err = String(describing: error)
                say(err)
                echo(named, via, false)
                feedback(["outcome": "refused", "err": .string(String(err.prefix(48))), "settledMs": nil])
            }
            return
        }

        var w: Write?
        do {
            if let target, let write = cmd.write { w = try write(target, arg) }
        } catch {
            let err = String(describing: error)
            say(err)
            feedback(["outcome": "refused", "err": .string(String(err.prefix(48))), "settledMs": nil])
            return
        }
        echo(named, via, w != nil)
        guard let w else { return }
        let runKey = "\(id)|\(target ?? "")"
        let started = Date()
        runs[runKey] = Run(state: .sending, t0: started)
        seq += 1
        let s = seq
        store.addOps(w.ops.map { var o = $0; o.seq = s; return o })
        let t = transport
        let prev = w.alone ? nil : tail
        let sent = Task { @MainActor () -> Sent in
            _ = await prev?.value
            return await t.post(w.path, w.body, via: via)
        }
        if !w.alone { tail = sent }
        Task { @MainActor [weak self] in
            let r = await sent.value
            guard let self else { return }
            let settledMs = (Date().timeIntervalSince(t0) * 10000).rounded() / 10
            w.answered?(r.ok, r.body ?? ["err": .string(r.err ?? "")])
            if r.ok {
                if let inv = w.inverse?(r.body ?? [:]), !undoing { self.undo.append(inv) }
                if let said = w.said, !w.silent { self.say(said) }
                self.runs[runKey] = Run(state: .landing, t0: started)
                self.reconcile(s, w) { self.runs[runKey] = Run(state: .done, t0: started, t1: Date()) }
            } else {
                self.store.dropOps(seq: s)
                w.rollback?()
                // the server's own sentence says what to do next; the short class is the fallback
                let bodyErr = r.body?["err"]?.string ?? r.body?["error"]?.string
                let why: String = {
                    if let e = bodyErr, e.count <= 140 { return e }
                    if let e = r.err, e != "refused" { return e.replacingOccurrences(of: "-", with: " ") }
                    return ""
                }()
                let line = "\(w.failed)\(why.isEmpty ? "" : " — \(why)")"
                if !w.silent { self.say(line) }
                self.runs[runKey] = Run(state: .failed, t0: started, t1: Date(), err: line)
            }
            var extra: JSONObject = ["outcome": .string(r.outcome.rawValue), "settledMs": .number(settledMs), "rid": .string(r.rid)]
            if let e = r.err { extra["err"] = .string(e) }
            feedback(extra)
        }
    }

    private func reconcile(_ s: Int, _ w: Write, onDone: @escaping () -> Void) {
        if w.settled() {
            store.dropOps(seq: s)
            return onDone()
        }
        var finished = false
        let done = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.awaiting[s] = nil
            self?.store.dropOps(seq: s)
            onDone()
        }
        awaiting[s] = (w.settled, done)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWait) { done() }
    }

    /// The latest run of command `id` on `target` this launch.
    public func runOf(_ id: String, _ target: String?) -> Run? { runs["\(id)|\(target ?? "")"] }

    /// Put back the last write (one level per press).
    @discardableResult
    public func undoLast() -> Bool {
        guard let inv = undo.popLast() else { return false }
        dispatch(inv.id, via: .key, target: inv.target, arg: inv.arg, undoing: true)
        return true
    }

    /// Once per launch: what exists to be used, and the budgets it's held to (runner.ts announce).
    public func announce(surfaces: [Surface]) {
        let cmds: [JSONValue] = registry.commands.map { c in
            var o: JSONObject = ["id": .string(c.id), "title": .string(c.title), "scope": .string(c.scope.rawValue),
                                 "budget": .string(c.budget.rawValue), "keys": .array(c.keys.map(JSONValue.string))]
            if !c.v1.isEmpty { o["v1"] = .array(c.v1.map(JSONValue.string)) }
            return .object(o)
        }
        let budgets: JSONObject = Dictionary(uniqueKeysWithValues: Budget.allCases.map { b in
            (b.rawValue, JSONValue.object(["feedbackMs": .number(b.feedbackMs), "settledMs": b.settledMs.map(JSONValue.number) ?? .null]))
        })
        telemetry.emit(["type": "registry", "commands": .array(cmds),
                        "surfaces": .array(surfaces.map { .object(["id": .string($0.id)]) }),
                        "budgets": .object(budgets), "paintMs": .number(PAINT_MS)])
    }
}
