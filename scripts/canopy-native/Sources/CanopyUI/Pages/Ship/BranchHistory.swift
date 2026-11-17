import CanopyCore
import Foundation
import Observation

@MainActor
@Observable
final class BranchHistory {
    struct Source: Hashable {
        let repo: String
        let name: String
        let tip: String
        let parent: String
        let upstream: String
        let pushed: String
        let ahead: Int
        let epoch: String
        let git: Int?
        let remote: Int?
        let hydration: Int
        var id: String { "\(repo):\(name)" }
    }
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
                guard let app, let branch = app.store.view(Branch.self, id) else { return nil }
                return Source(repo: branch.repo, name: branch.name, tip: branch.tip, parent: branch.parent,
                              upstream: branch.upstream, pushed: branch.pushed.rawValue, ahead: branch.ahead,
                              epoch: app.store.epoch, git: app.store.versions[Domain.git], remote: app.store.versions[Domain.remote],
                              hydration: app.store.hydrations)
            }, read: { source in
                try await transport.getJSON(transport.atRepo(source.repo, "/commits?branch=\(source.name.uriComponent)"))
            })
        }
    }

    func state(_ id: String) -> State {
        guard let entry = entries[id], entry.stamp.source == source(id) else { return .idle }
        return entry.state
    }

    func rows(_ id: String) -> [HistoryCommit]? {
        guard case .ready(let rows) = state(id) else { return nil }
        return rows
    }

    func stamp(_ id: String) -> Stamp? {
        guard case .ready = state(id) else { return nil }
        return entries[id]?.stamp
    }

    @discardableResult
    func load(_ id: String, retry: Bool = false) -> Task<Void, Never>? {
        guard let source = source(id) else { return nil }
        if entries[id]?.stamp.source == source, !retry {
            touch(id)
            return tasks[id]
        }
        tasks[id]?.cancel()
        sequence &+= 1
        let stamp = Stamp(source: source, request: sequence)
        entries[id] = Entry(stamp: stamp, state: .loading)
        touch(id)
        let read = read
        let task = Task { @MainActor [weak self] in
            let result: Result<[HistoryCommit], Error>
            do { result = .success(try await read(source)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, entries[id]?.stamp == stamp else { return }
            tasks[id] = nil
            guard self.source(id) == source else { entries[id] = nil; return }
            switch result {
            case .success(let rows): entries[id]?.state = .ready(rows.filter(\.own))
            case .failure: entries[id]?.state = .failed
            }
        }
        tasks[id] = task
        return task
    }

    func put(_ id: String, rows: [HistoryCommit]) {
        guard let source = source(id) else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
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
