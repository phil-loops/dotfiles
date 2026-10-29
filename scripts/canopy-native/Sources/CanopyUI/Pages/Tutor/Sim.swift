import Foundation

// A toy SES projection the tutor plays instead of telling (sim.ts): a scenario scripts inserts,
// projector pages, crashes and handoffs; kernels switch each safeguard on or off; the result names
// every event that was skipped, counted twice, or left pinned past cleanup. Mirrors the real
// design's rules (models/email-send-metric-projection.ts in loops) at toy scale. Deterministic and pure.

enum Kernel: String, CaseIterable, Sendable {
    case atomicCommit, safetyLag, lock, shardBookmarks, fence, cutoffCheck, retireBookmark

    var title: String {
        switch self {
        case .atomicCommit: "counts and bookmark commit together"
        case .safetyLag: "readers skip rows newer than the safety lag"
        case .lock: "one transaction per bookmark (advisory lock)"
        case .shardBookmarks: "bookmarks belong to shards, not groups"
        case .fence: "activation fences the old global writer"
        case .cutoffCheck: "activation waits until the cutoff is past the global bookmark"
        case .retireBookmark: "a removed reader's bookmark is deleted"
        }
    }
}

typealias Kernels = [Kernel: Bool]

enum SimConst {
    /// Ticks a reader stays behind the clock; every scripted insert commits within fewer.
    static let lag = 3
    static let metrics = "metrics"
    static let allKernels: Kernels = Dictionary(uniqueKeysWithValues: Kernel.allCases.map { ($0, true) })
    /// The safeguards a block names off, by name — an unknown name is ignored, as the web app's record lookup is.
    static func kernels(off: [String]) -> Kernels {
        Dictionary(uniqueKeysWithValues: off.compactMap { Kernel(rawValue: $0) }.map { ($0, false) })
    }
}

struct Step: Sendable {
    enum Do: Sendable {
        case insert(id: String, shard: Int?)
        /// stamped now, invisible until its commit — a slow ingest transaction
        case begin(id: String, shard: Int?)
        case commit(id: String)
        case tick(n: Int?)
        /// opens a page transaction on one bookmark, or on a group's bookmarks; `lag` overrides the kernel
        case read(worker: String, bookmark: String?, group: Int?, lag: Int?)
        case apply(worker: String)
        case save(worker: String)
        case crash(worker: String)
        /// a Valkey group lease; a held lease makes the worker exit for the rest of the run
        case lease(worker: String, group: Int)
        /// the lease key vanishes (expiry, Valkey restart) while its worker keeps running
        case leaseLost(worker: String)
        case regroup(groupCount: Int)
        case activate
        /// the operator stops and drains the old global deployment
        case stopGlobal
        case dropReader(bookmark: String)
        case cleanup
    }
    var `do`: Do
    var note: String?
    init(_ d: Do, note: String? = nil) { self.do = d; self.note = note }
}

struct Scenario: Sendable {
    var id: String
    var title: String
    /// the graph standard and concepts this scenario is evidence for
    var standard: String
    var concepts: [String]
    /// the safeguard a contrast flips; nil when the scenario holds with every kernel on
    var kernel: Kernel?
    /// the situation as posed before the reveal, and the question
    var situation: String
    var question: String
    var shards: Int?
    var groupCount: Int?
    var pageSize: Int?
    /// bookmarks present at the start: "global", "audit", or "layout" (shard or group bookmarks per kernel)
    var bookmarks: [String]
    var steps: [Step]
    /// steps before this index are the setup the learner sees frozen
    var revealAt: Int
}

struct Cursor: Equatable, Sendable {
    var stamp: Int
    var id: String
}

struct SimEvent: Equatable, Sendable {
    var id: String
    var shard: Int
    var stamp: Int
    var committed: Bool
    var retained: Bool
    /// times each projection counted it
    var applied: [String: Int]
}

struct Bookmark: Equatable, Sendable {
    var name: String
    var projection: String
    var shards: [Int]
    var cursor: Cursor
    /// false once stopped, dropped or orphaned by a regroup; the row may still exist
    var live: Bool
}

struct Worker: Equatable, Sendable {
    /// "idle" | "reading" | "busy" | "crashed" | "exited"
    var id: String
    var status: String
    var lease: Int?
    var txn: Txn?
    struct Txn: Equatable, Sendable {
        var bookmarks: [String]
        /// per bookmark, in the order read: the event ids on the page
        var page: [(String, [String])]
        var applied: Bool
        static func == (a: Txn, b: Txn) -> Bool {
            a.bookmarks == b.bookmarks && a.applied == b.applied && a.page.map(\.0) == b.page.map(\.0) && a.page.map(\.1) == b.page.map(\.1)
        }
    }
}

struct SimState: Equatable, Sendable {
    var clock = 0
    var groupCount: Int
    var events: [SimEvent] = []
    var bookmarks: [Bookmark] = []
    var workers: [Worker] = []
    var leases: [Int: String] = [:]
    var cleaned = false
    var log: [String] = []
}

struct SimResult: Equatable, Sendable {
    /// "green" | "red"
    var outcome: String
    /// metric counts there should be so far, and there are
    var truth: Int
    var actual: Int
    var divergence: [Divergence]
    /// pages a worker couldn't start because another held the bookmark
    var busy: Int
}

private func cmp(_ a: Cursor, _ b: Cursor) -> Int {
    if a.stamp != b.stamp { return a.stamp - b.stamp }
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

private func shardsOfGroup(_ shards: Int, _ group: Int, _ groupCount: Int) -> [Int] {
    (0..<shards).filter { $0 % groupCount == group }
}

/// One playable run of a scenario under a set of kernels.
final class Sim {
    let scenario: Scenario
    let kernels: Kernels
    private var s: SimState
    private var next = 0
    private var busy = 0
    private let shardCount: Int
    private let pageSize: Int
    private let all: [Int]

    init(_ scenario: Scenario, _ kernels: Kernels = [:]) {
        self.scenario = scenario
        self.kernels = SimConst.allKernels.merging(kernels) { $1 }
        shardCount = scenario.shards ?? 1
        pageSize = scenario.pageSize ?? 10
        all = Array(0..<shardCount)
        s = SimState(groupCount: scenario.groupCount ?? 1)
        let start = Cursor(stamp: -1, id: "")
        for name in scenario.bookmarks {
            if name != "layout" { addBookmark(name, coverage(name), start) }
            else if k(.shardBookmarks) { all.forEach { addBookmark("shard-\($0)", [$0], start) } }
            else { for g in 0..<s.groupCount { addBookmark(groupBookmark(g), shardsOfGroup(shardCount, g, s.groupCount), start) } }
        }
    }

    private func k(_ x: Kernel) -> Bool { kernels[x] ?? true }

    func state() -> SimState { s }
    var done: Bool { next >= scenario.steps.count }

    /// Runs one step; returns its log line, or nil when the script is over.
    @discardableResult
    func step() -> String? {
        if done { return nil }
        let line = run(scenario.steps[next].do)
        next += 1
        s.log.append(line)
        return line
    }

    /// Runs the setup and returns the frozen state the learner predicts from.
    func toReveal() -> SimState {
        while next < scenario.revealAt { step() }
        return s
    }

    func runToEnd() -> SimResult {
        while step() != nil {}
        return result()
    }

    // ── the world ──

    private func bookmarkIdx(_ name: String) -> Int? { s.bookmarks.firstIndex { $0.name == name } }

    @discardableResult
    private func addBookmark(_ name: String, _ shards: [Int], _ cursor: Cursor) -> Int {
        s.bookmarks.append(Bookmark(name: name, projection: name == "audit" ? "audit" : SimConst.metrics, shards: shards, cursor: cursor, live: true))
        return s.bookmarks.count - 1
    }

    private func groupBookmark(_ g: Int) -> String { "group-\(g)/\(s.groupCount)" }

    private func coverage(_ name: String) -> [Int] {
        if name.hasPrefix("shard-"), let n = Int(name.dropFirst(6)), String(n) == name.dropFirst(6) { return [n] }
        return all
    }

    private func worker(_ id: String) -> Int {
        if let i = s.workers.firstIndex(where: { $0.id == id }) { return i }
        s.workers.append(Worker(id: id, status: "idle", lease: nil, txn: nil))
        return s.workers.count - 1
    }

    private func lockHolder(_ name: String, except: String? = nil) -> Worker? {
        s.workers.first { $0.id != except && ($0.txn?.bookmarks.contains(name) ?? false) }
    }

    private func pos(_ e: SimEvent) -> Cursor { Cursor(stamp: e.stamp, id: e.id) }

    private func applyCounts(_ w: Int) {
        guard let txn = s.workers[w].txn else { return }
        for (name, ids) in txn.page {
            guard let b = bookmarkIdx(name) else { continue }
            let projection = s.bookmarks[b].projection
            for id in ids {
                if let e = s.events.firstIndex(where: { $0.id == id }) { s.events[e].applied[projection, default: 0] += 1 }
            }
        }
    }

    private func insert(_ id: String, _ shard: Int, _ committed: Bool) {
        s.events.append(SimEvent(id: id, shard: shard, stamp: s.clock, committed: committed, retained: true, applied: [:]))
    }

    private func read(_ w: Int, bookmark: String?, group: Int?, lag: Int?) -> String {
        let wid = s.workers[w].id
        if s.workers[w].status == "exited" { return "\(wid) has exited" }
        let names: [String] = bookmark.map { [$0] }
            ?? (k(.shardBookmarks) ? shardsOfGroup(shardCount, group ?? 0, s.groupCount).map { "shard-\($0)" } : [groupBookmark(group ?? 0)])
        for name in names {
            if let b = bookmarkIdx(name), !s.bookmarks[b].live, name == "global" { return "\(wid) can't read global: the old writer is stopped" }
        }
        if k(.lock), let held = names.first(where: { lockHolder($0, except: wid) != nil }) {
            busy += 1
            s.workers[w].status = "busy"
            return "\(wid) is busy: \(lockHolder(held, except: wid)!.id) holds \(held)"
        }
        let horizon = s.clock - (lag ?? (k(.safetyLag) ? SimConst.lag : 0))
        var page: [(String, [String])] = []
        for name in names {
            let bi = bookmarkIdx(name)
                ?? addBookmark(name, bookmark != nil ? coverage(name) : shardsOfGroup(shardCount, group ?? 0, s.groupCount), Cursor(stamp: s.clock - SimConst.lag, id: ""))
            let b = s.bookmarks[bi]
            let ids = s.events
                .filter { $0.committed && $0.retained && b.shards.contains($0.shard) && $0.stamp <= horizon && cmp(pos($0), b.cursor) > 0 }
                .sorted { cmp(pos($0), pos($1)) < 0 }
                .prefix(pageSize)
                .map(\.id)
            page.append((name, Array(ids)))
        }
        s.workers[w].status = "reading"
        s.workers[w].txn = Worker.Txn(bookmarks: names, page: page, applied: false)
        let ids = page.flatMap(\.1)
        return "\(wid) reads \(names.joined(separator: ", ")): \(ids.isEmpty ? "nothing ready" : ids.joined(separator: " "))"
    }

    private func apply(_ w: Int) -> String {
        let wid = s.workers[w].id
        guard s.workers[w].txn != nil else { return "\(wid) has no page open" }
        s.workers[w].txn!.applied = true
        if !k(.atomicCommit) {
            applyCounts(w)
            return "\(wid) commits the counts (bookmark not saved yet)"
        }
        return "\(wid) adds the counts in its open transaction"
    }

    private func save(_ w: Int) -> String {
        let wid = s.workers[w].id
        guard let txn = s.workers[w].txn else { return "\(wid) has no page open" }
        if k(.atomicCommit) && txn.applied { applyCounts(w) }
        for (name, ids) in txn.page {
            if let last = ids.last, let b = bookmarkIdx(name), let e = s.events.first(where: { $0.id == last }) { s.bookmarks[b].cursor = pos(e) }
        }
        s.workers[w].txn = nil
        s.workers[w].status = "idle"
        return k(.atomicCommit) ? "\(wid) commits counts and bookmark together" : "\(wid) saves its bookmark"
    }

    private func activate() -> String {
        let shardNames = all.map { "shard-\($0)" }
        if shardNames.allSatisfy({ bookmarkIdx($0) != nil }) { return "shards already active" }
        let global = bookmarkIdx("global")
        if k(.fence), let holder = lockHolder("global") { return "activation is busy: \(holder.id) holds global" }
        let cutoff = Cursor(stamp: s.clock - SimConst.lag, id: "")
        if k(.cutoffCheck), let g = global, cutoff.stamp <= s.bookmarks[g].cursor.stamp {
            return "activation waits: cutoff \(cutoff.stamp) is not past the global bookmark \(s.bookmarks[g].cursor.stamp)"
        }
        for (sh, n) in shardNames.enumerated() where bookmarkIdx(n) == nil { addBookmark(n, [sh], cutoff) }
        if k(.fence), let g = global { s.bookmarks[g].live = false }
        return "shards start at cutoff \(cutoff.stamp)\(k(.fence) && global != nil ? "; the old global writer is fenced" : "")"
    }

    private func cleanup() -> String {
        s.cleaned = true
        guard let first = s.bookmarks.first else { return "cleanup: no bookmarks, nothing removed" }
        let floor = s.bookmarks.reduce(first.cursor) { cmp($1.cursor, $0) < 0 ? $1.cursor : $0 }
        var gone: [String] = []
        for i in s.events.indices where s.events[i].retained && s.events[i].committed && cmp(pos(s.events[i]), floor) < 0 {
            s.events[i].retained = false
            gone.append(s.events[i].id)
        }
        return "cleanup removes everything before stamp \(floor.stamp): \(gone.isEmpty ? "nothing" : gone.joined(separator: " "))"
    }

    private func run(_ step: Step.Do) -> String {
        switch step {
        case .insert(let id, let shard):
            insert(id, shard ?? 0, true)
            return "\(id) lands at t\(s.clock)\(shardCount > 1 ? " in shard \(shard ?? 0)" : "")"
        case .begin(let id, let shard):
            insert(id, shard ?? 0, false)
            return "\(id) is stamped t\(s.clock) but its insert hasn't committed"
        case .commit(let id):
            if let e = s.events.firstIndex(where: { $0.id == id }) { s.events[e].committed = true }
            return "\(id) commits now (stamped earlier)"
        case .tick(let n):
            s.clock += n ?? 1
            return "clock → t\(s.clock)"
        case .read(let w, let bookmark, let group, let lag):
            return read(worker(w), bookmark: bookmark, group: group, lag: lag)
        case .apply(let w):
            return apply(worker(w))
        case .save(let w):
            return save(worker(w))
        case .crash(let id):
            let w = worker(id)
            s.workers[w].txn = nil
            s.workers[w].status = "crashed"
            return "\(id) crashes\(k(.atomicCommit) ? "; its open transaction rolls back" : "")"
        case .lease(let id, let group):
            let w = worker(id)
            if let holder = s.leases[group], holder != id {
                s.workers[w].status = "exited"
                return "\(id) can't lease group \(group) (\(holder) holds it) and exits"
            }
            s.leases[group] = id
            s.workers[w].lease = group
            return "\(id) leases group \(group)"
        case .leaseLost(let id):
            let w = worker(id)
            if let l = s.workers[w].lease { s.leases[l] = nil }
            s.workers[w].lease = nil
            return "\(id)'s lease key is gone; \(id) is still running"
        case .regroup(let groupCount):
            let old = s.groupCount
            s.groupCount = groupCount
            for i in s.bookmarks.indices where s.bookmarks[i].name.hasSuffix("/\(old)") { s.bookmarks[i].live = false }
            return "group count \(old) → \(groupCount)"
        case .activate:
            return activate()
        case .stopGlobal:
            if let g = bookmarkIdx("global") { s.bookmarks[g].live = false }
            return "the old global deployment is stopped and drained"
        case .dropReader(let name):
            guard let b = bookmarkIdx(name) else { return "no reader \(name)" }
            s.bookmarks[b].live = false
            if k(.retireBookmark) { s.bookmarks.remove(at: b) }
            return "reader \(name) is removed\(k(.retireBookmark) ? " with its bookmark" : "; its bookmark row stays")"
        case .cleanup:
            return cleanup()
        }
    }

    func result() -> SimResult {
        var divergence: [Divergence] = []
        let live = s.bookmarks.filter { $0.live && $0.projection == SimConst.metrics }
        var truth = 0, actual = 0
        for e in s.events {
            let n = e.applied[SimConst.metrics] ?? 0
            actual += n
            if n >= 2 { divergence.append(Divergence(event: e.id, kind: "double")) }
            let covering = live.filter { $0.shards.contains(e.shard) }
            let passed = !covering.isEmpty && covering.allSatisfy { cmp($0.cursor, pos(e)) >= 0 }
            if n == 0 && e.committed && passed { divergence.append(Divergence(event: e.id, kind: "skipped")) }
            if n > 0 || (e.committed && passed) { truth += 1 }
        }
        let allLive = s.bookmarks.filter(\.live)
        if s.cleaned, let first = allLive.first {
            let floor = allLive.reduce(first.cursor) { cmp($1.cursor, $0) < 0 ? $1.cursor : $0 }
            for e in s.events where e.retained && e.committed && cmp(pos(e), floor) < 0 { divergence.append(Divergence(event: e.id, kind: "pinned")) }
        }
        return SimResult(outcome: divergence.isEmpty ? "green" : "red", truth: truth, actual: actual, divergence: divergence, busy: busy)
    }
}
