import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class BranchHistory {
    typealias Source = BranchSource
    struct Stamp: Equatable { let source: Source; let request: Int }
    enum State: Equatable {
        case idle, loading, failed
        case ready([HistoryCommit])
    }
    private struct Entry { let stamp: Stamp; var state: State }
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var sequence = 0
    /// branches whose read in flight should be followed by another (a retry asked mid-read)
    @ObservationIgnored private var again: Set<String> = []
    @ObservationIgnored let source: (String) -> Source?
    @ObservationIgnored var read: (Source) async throws -> [HistoryCommit]

    init(source: @escaping (String) -> Source?, read: @escaping (Source) async throws -> [HistoryCommit]) {
        self.source = source
        self.read = read
    }

    static func of(_ app: AppModel) -> BranchHistory {
        app.state {
            let transport = app.transport
            return BranchHistory(source: { [weak app] id in
                guard let app else { return nil }
                return BranchSource.history(app, id)
            }, read: { source in
                try await transport.getJSON(transport.atRepo(source.repo, "/commits?branch=\(source.name.uriComponent)"))
            })
        }
    }

    /// What the page shows: the last read that completed for this branch, even when the branch has
    /// moved since (`isStale`) — a newer key revalidates, it never blanks what's on screen.
    func state(_ id: String) -> State {
        guard source(id) != nil, let entry = entries[id] else { return .idle }
        return entry.state
    }

    /// The rows on screen were read for an older key; a read for the current one is coming.
    func isStale(_ id: String) -> Bool {
        guard let current = source(id), let entry = entries[id], case .ready = entry.state else { return false }
        return entry.stamp.source != current
    }

    func rows(_ id: String) -> [HistoryCommit]? {
        guard case .ready(let rows) = state(id) else { return nil }
        return rows
    }

    /// Names the rows on screen while they were read for the current key. A pick (an anchor on the
    /// line) binds only to fresh rows: stale rows draw, but nothing picked against them survives the
    /// key's move, so a move between a pick's two ends can't retarget it.
    func stamp(_ id: String) -> Stamp? {
        guard case .ready = state(id), !isStale(id) else { return nil }
        return entries[id]?.stamp
    }

    /// Stale-while-revalidate (2026-11-17). A read in flight is never cancelled: a key that changes
    /// faster than a read completes (a reshape rebasing the branch or its parent; under load a read
    /// took 80 s) used to restart it forever, and the page sat at "reading the commits…". Now every
    /// read that completes is installed, unless a newer result already is, and then, after a short
    /// debounce that folds a burst of moves into one, the same task reads again for whatever the key
    /// is by then, until a read lands on the current key.
    @discardableResult
    func load(_ id: String, retry: Bool = false) -> Task<Void, Never>? {
        guard let source = source(id) else { return nil }
        touch(id)
        if let task = tasks[id] {
            if retry { again.insert(id) }   // the read in flight finishes; this one follows it
            return task
        }
        if let entry = entries[id], entry.stamp.source == source, !retry {
            if case .loading = entry.state {} else { return nil }   // current: ready, or failed until a retry
        }
        if entries[id] == nil { entries[id] = Entry(stamp: Stamp(source: source, request: 0), state: .loading) }
        // rows already on screen: this is a revalidation, so a burst of moves waits out the debounce
        var shown = false
        if case .ready = entries[id]?.state { shown = true }
        let task = Task { @MainActor [weak self] in guard let self else { return }; await self.revalidate(id, debounce: shown) }
        tasks[id] = task
        return task
    }

    static let debounce: UInt64 = 250_000_000
    @ObservationIgnored var debounceNanos = BranchHistory.debounce

    private func revalidate(_ id: String, debounce first: Bool) async {
        var wait = first
        while !Task.isCancelled {
            if wait { try? await Task.sleep(nanoseconds: debounceNanos) }
            wait = true
            guard !Task.isCancelled, let source = source(id) else { break }
            again.remove(id)
            sequence &+= 1
            let stamp = Stamp(source: source, request: sequence)
            let result: Result<[HistoryCommit], Error>
            do { result = .success(try await read(source)) }
            catch { result = .failure(error) }
            if Task.isCancelled { break }
            guard self.source(id) != nil else { entries[id] = nil; break }
            install(id, stamp, result)
            guard again.contains(id) || self.source(id) != source else { break }
        }
        tasks[id] = nil
        again.remove(id)
    }

    /// A completed read goes on screen unless a newer one (a later read, or `put`) already has.
    private func install(_ id: String, _ stamp: Stamp, _ result: Result<[HistoryCommit], Error>) {
        if let shown = entries[id], shown.stamp.request > stamp.request, shown.state != .loading { return }
        switch result {
        case .success(let rows): entries[id] = Entry(stamp: stamp, state: .ready(rows.filter(\.own)))
        case .failure:
            // a failed revalidation keeps the rows on screen; with nothing shown, the failure is
            if case .ready = entries[id]?.state { return }
            entries[id] = Entry(stamp: stamp, state: .failed)
        }
    }

    func put(_ id: String, rows: [HistoryCommit]) {
        guard let source = source(id) else { return }
        sequence &+= 1
        entries[id] = Entry(stamp: Stamp(source: source, request: sequence), state: .ready(rows.filter(\.own)))
        touch(id)
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 64 {
            let oldest = order.removeFirst()
            tasks.removeValue(forKey: oldest)?.cancel()
            entries[oldest] = nil
        }
    }
}
