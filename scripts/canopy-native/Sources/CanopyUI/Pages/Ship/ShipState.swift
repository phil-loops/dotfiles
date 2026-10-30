import AppKit
import CanopyCore
import Foundation
import Observation

/// The comment box: a line comment (or a range `x` extended), a note for Claude on one commit's
/// line, or a reply to a thread (review/page.ts Composer).
public enum ShipComposer: Equatable, Sendable {
    case line(key: String, path: String, side: Side, line: Int, startLine: Int?, sha: String?)
    case reply(key: String, threadID: String)

    public var key: String {
        switch self { case .line(let k, _, _, _, _, _), .reply(let k, _): k }
    }
    /// a note for Claude on a commit's line, not a GitHub comment
    public var noteSha: String? { if case .line(_, _, _, _, _, let sha) = self { return sha }; return nil }
}

/// One sync motion (commands/sync.ts Motion).
public struct SyncMotion: Equatable, Sendable {
    public var steps: [SyncStep]
    public var phase: SyncPhase
    /// the dirty files the motion waits on a decision about
    public var dirt: (files: [String], rows: [DirtRow], worktree: String)?
    public var stashed: Bool
    /// the tip when it stopped — a hand-off to Claude reads as done once the tip moves
    public var tip: String

    public static func == (a: SyncMotion, b: SyncMotion) -> Bool {
        a.steps == b.steps && a.phase == b.phase && a.stashed == b.stashed && a.tip == b.tip && a.dirt?.files == b.dirt?.files
    }
}

/// The Ship area's state, one per window (`ShipState.of(app)`): the sync motions, the reads the
/// ship strip makes per branch, the review ledger's composer and folds, the address sheet, and the
/// commits tab's history.
@MainActor
@Observable
public final class ShipState {
    /// What area B tells Ship about the review page (the tab, the cursor's line range, …). Until
    /// B sets its own, a stand-in keeps the tab so Ship's views and commands run on their own.
    public var host: ShipHost = StandInHost()

    // ── ⟲ sync ──
    public var motions: [String: SyncMotion] = [:]
    /// the dirty file whose change is open under the dirt decision — "<branch id>|<path>"
    public var dirtOpen: String?
    /// the branch whose divergence is being inspected
    public var inspecting: String?

    // ── the strip's reads, per branch, keyed by what they depend on ──
    public private(set) var facts: [String: (key: String, value: SyncFacts?)] = [:]
    public private(set) var prep: [String: (key: String, value: PrepRoute?)] = [:]
    public private(set) var progress: [String: (key: String, value: GateProgress?)] = [:]
    public private(set) var forceScopes: [String: (key: String, value: ForceScope??)] = [:]
    public private(set) var divergence: [String: DivergedDetail?] = [:]
    /// the gate whose output the strip shows instead of the running one's — "<branch id> <gate>"
    public var gateShown: String?

    // ── the review ledger ──
    public var composer: ShipComposer?
    public private(set) var texts: [String: String] = [:]
    /// a thread's fold (by thread id) and its second-reader note's ("note:<id>")
    public var unfold: [String: Bool] = [:]
    /// the thread E is addressing, while its sheet is open, and whether it lists commits to pick
    public var addressing: String?
    public var addressPicking = false

    // ── the commits tab ──
    public enum HistoryFocus: String, Sendable { case list, diff }
    public private(set) var history: (key: String, rows: [HistoryCommit])?
    /// the one commit whose diff shows (nil: the whole branch, "lands on main")
    public var commitScope: String?
    public var historyFocus: HistoryFocus = .list

    /// Where unsent words are kept across launches; the keytutor's practice app keeps its own.
    @ObservationIgnored public var defaults = UserDefaults.standard
    /// Every command Ship registered, for its keyboard-rule test.
    @ObservationIgnored public internal(set) var commandIDs: [String] = []
    /// Opens a URL in the browser (GitHub, the compare form, a preview). Tests swap it out.
    @ObservationIgnored public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Puts text on the clipboard (`y`). The keytutor's practice app swaps it.
    @ObservationIgnored public var copyText: (String) -> Void = { s in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    /// A branch's description as it's being typed, by branch id (saved on leaving insert).
    public var describing: [String: String] = [:]

    public init() {}

    public static func of(_ app: AppModel) -> ShipState { app.state { ShipState() } }

    // ── composer text, kept across launches like v2's localStorage ──

    public func text(_ key: String) -> String { texts[key] ?? defaults.string(forKey: "canopy.ship.text.\(key)") ?? "" }

    public func setText(_ key: String, _ v: String) {
        texts[key] = v
        if v.isEmpty { defaults.removeObject(forKey: "canopy.ship.text.\(key)") } else { defaults.set(v, forKey: "canopy.ship.text.\(key)") }
    }

    /// A thread is open unless folded — resolved and outdated ones start folded.
    public func isOpen(_ t: CanopyCore.Thread) -> Bool { unfold[t.id] ?? (!t.resolved && !t.outdated) }

    // ── motions ──

    public func motionOf(_ id: String?) -> SyncMotion? { id.flatMap { motions[$0] } }

    func patch(_ id: String, _ fn: (inout SyncMotion) -> Void) {
        guard var m = motions[id] else { return }
        fn(&m)
        motions[id] = m
    }

    func setStep(_ id: String, _ step: StepID, _ state: StepState, _ note: String? = nil) {
        patch(id) { m in
            m.steps = m.steps.map { s in
                guard s.id == step else { return s }
                var x = s
                x.state = state
                if let note { x.note = note }
                if state == .run && x.t0 == nil { x.t0 = Date() }
                return x
            }
        }
    }

    // ── reads (GET only; never a write) ──

    /// GET /sync and /prep-route for the strip, once per `key` (the branch's tip, push state,
    /// drift and the motion's phase — what can change their answer).
    public func readFacts(_ app: AppModel, _ b: Branch, key: String) {
        if facts[b.id]?.key == key { return }
        facts[b.id] = (key, facts[b.id]?.value)
        prep[b.id] = (key, prep[b.id]?.value)
        let t = app.transport
        let q = "?branch=\(b.name.uriComponent)"
        let syncPath = t.atRepo(b.repo, "/sync\(q)"), prepPath = t.atRepo(b.repo, "/prep-route\(q)")
        Task { @MainActor [weak self] in
            async let f = try? t.getJSON(syncPath, as: SyncFacts.self)
            async let p = try? t.getJSON(prepPath, as: PrepRoute.self)
            let (fv, pv) = await (f, p)
            guard let self, self.facts[b.id]?.key == key else { return }
            self.facts[b.id] = (key, fv)
            self.prep[b.id] = (key, pv)
        }
    }

    /// GET /gates-progress, re-read every 2s while the run is going (as v2 polls it). The app
    /// reads it the way v2 does; tests never point it at a real branch.
    public func readProgress(_ app: AppModel, _ b: Branch, key: String, gate: String?) {
        if progress[b.id]?.key == key { return }
        progress[b.id] = (key, progress[b.id]?.value)
        let path = app.transport.atRepo(b.repo, "/gates-progress?branch=\(b.name.uriComponent)\(gate.map { "&gate=\($0.uriComponent)" } ?? "")")
        let t = app.transport
        Task { @MainActor [weak self, weak app] in
            let got = try? await t.getJSON(path, as: GateProgress.self)
            guard let self, self.progress[b.id]?.key == key else { return }
            self.progress[b.id] = (key, got)
            guard got?.running == true else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak app] in
                guard let self, let app, self.progress[b.id]?.key == key, let now = app.store.view(Branch.self, b.id) else { return }
                self.progress[b.id] = ("", self.progress[b.id]?.value)
                self.readProgress(app, now, key: key, gate: gate)
            }
        }
    }

    public func progressOf(_ id: String) -> GateProgress? { progress[id]?.value }
    public func factsOf(_ id: String) -> SyncFacts? { facts[id]?.value }
    public func prepOf(_ id: String) -> PrepRoute? { prep[id]?.value }

    static func scopeKey(_ b: Branch) -> String { "\(b.tip)|\(b.ahead)|\(b.gates.rawValue)" }

    /// The force scope read for this tip — nil until read, .some(nil) when it couldn't be.
    public func forceScopeOf(_ app: AppModel, _ id: String?) -> ForceScope?? {
        guard let id, let b = app.store.view(Branch.self, id), let s = forceScopes[id], s.key == Self.scopeKey(b) else { return nil }
        return s.value
    }

    /// Read the scope once per tip (it asks GitHub, so never on a poll). A run's green shows in
    /// /state a moment before its verdict lands in git config, so a gates ✗ under green gates is
    /// read again, a few times.
    public func readForceScope(_ app: AppModel, _ id: String, tries: Int = 0) {
        guard let b = app.store.view(Branch.self, id) else { return }
        let key = Self.scopeKey(b)
        if tries == 0 && forceScopes[id]?.key == key { return }
        if tries == 0 { forceScopes[id] = (key, nil) }
        struct Answer: Decodable { var forceScope: ForceScope? }
        let t = app.transport
        let path = t.atRepo(b.repo, "/force-scope?branch=\(b.name.uriComponent)")
        Task { @MainActor [weak self, weak app] in
            let got = try? await t.getJSON(path, as: Answer.self)
            guard let self, let app, let now = app.store.view(Branch.self, id), Self.scopeKey(now) == key else { return }
            self.forceScopes[id] = (key, .some(got?.forceScope))
            let early = b.gates == .green && got?.forceScope?.guards.contains { $0.k == "gates" && !$0.ok } == true
            if early && tries < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(tries + 1)) { [weak self, weak app] in
                    guard let self, let app else { return }
                    self.readForceScope(app, id, tries: tries + 1)
                }
            }
        }
    }

    /// Put a force scope in place (the server's answer to a refused force carries the fresh one).
    public func putForceScope(_ app: AppModel, _ id: String, _ s: ForceScope?) {
        guard let b = app.store.view(Branch.self, id) else { return }
        forceScopes[id] = (Self.scopeKey(b), .some(s))
    }

    public func readDivergence(_ app: AppModel, _ b: Branch) {
        guard divergence[b.id] == nil else { return }
        let t = app.transport
        let path = t.atRepo(b.repo, "/diverged-detail?branch=\(b.name.uriComponent)")
        Task { @MainActor [weak self] in
            let got = try? await t.getJSON(path, as: DivergedDetail.self)
            self?.divergence[b.id] = .some(got)
        }
    }

    public func forgetDivergence(_ id: String) { divergence[id] = nil }

    // ── the history list (GET /commits) ──

    /// The history's freshness: the tip, and what origin has — a push changes the second, not the first.
    static func historyKey(_ b: Branch) -> String { "\(b.repo)|\(b.name)|\(b.tip)|\(b.pushed.rawValue)|\(b.ahead)" }

    public func loadHistory(_ app: AppModel, _ id: String) {
        guard let b = app.store.view(Branch.self, id) else { return }
        let key = Self.historyKey(b)
        if history?.key == key { return }
        let t = app.transport
        let path = t.atRepo(b.repo, "/commits?branch=\(b.name.uriComponent)")
        Task { @MainActor [weak self, weak app] in
            guard let rows = try? await t.getJSON(path, as: [HistoryCommit].self) else { return }
            guard let self, let app, let now = app.store.view(Branch.self, id), Self.historyKey(now) == key else { return }
            self.history = (key, rows.filter(\.own))
        }
    }

    public func historyRows(_ id: String) -> [HistoryCommit]? { history?.key.hasPrefix(Self.branchKey(id)) == true ? history?.rows : nil }

    static func branchKey(_ id: String) -> String {
        guard let cut = id.firstIndex(of: ":") else { return id }
        return "\(id[..<cut])|\(id[id.index(after: cut)...])|"
    }

    /// For tests and the forest page: a history read put in place.
    public func putHistory(_ b: Branch, _ rows: [HistoryCommit]) { history = (Self.historyKey(b), rows.filter(\.own)) }

    /// Show one commit's diff (nil: the whole branch). The diff itself is area B's to load.
    public func showCommit(_ sha: String?) {
        commitScope = sha
        host.commitScopeChanged(sha)
    }
}
