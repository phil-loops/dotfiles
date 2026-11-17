import CanopyCore
import Foundation
import Observation

struct MachineRun: Equatable, Sendable {
    private struct Head: Decodable {
        struct Status: Decodable {
            let state: String?
            let done: Int?
            let total: Int?
            let current: String?
        }
        let mode: String?
        let title: String
        let status: Status?
        let staleAfter: Double?
    }

    let url: URL
    let title: String
    let state: String
    let done: Int?
    let total: Int?
    let current: String?
    let modified: Date?
    let staleAfter: Double
    var key: String { "run:\(url.path)" }
    var terminal: Bool { state == "done" || state == "failed" }

    init?(_ url: URL, file: LocalDocumentFile) {
        guard file.data.count <= 8_388_608, let head = try? JSONDecoder().decode(Head.self, from: file.data), head.mode == "live" else { return nil }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        title = head.title.isEmpty ? url.deletingPathExtension().lastPathComponent : head.title
        state = head.status?.state ?? ""
        done = head.status?.done.flatMap { $0 >= 0 ? $0 : nil }
        total = head.status?.total.flatMap { $0 >= 0 ? $0 : nil }
        current = head.status?.current.flatMap { $0.isEmpty ? nil : $0 }
        modified = file.modified
        staleAfter = head.staleAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
    }

    func stale(at now: Date) -> Bool { state == "running" && modified.map { now.timeIntervalSince($0) > staleAfter } == true }
    var progress: String? {
        guard let done else { return nil }
        return total.map { "\(done) of \($0)" } ?? "\(done) done"
    }
    var reportedState: String { state.isEmpty ? "state not reported" : "reported \(state)" }
    func freshness(at now: Date) -> String {
        guard let modified else { return "report time unavailable" }
        let seconds = now.timeIntervalSince(modified)
        if seconds < -60 { return "report clock ahead" }
        let age = seconds < 60 ? "\(Int(max(0, seconds)))s" : MachineText.ago(seconds)
        return "last report \(age) ago"
    }
}

struct MachineRunsIO: Sendable {
    struct Snapshot: Sendable { let runs: [MachineRun]; let unavailable: Int }
    var registry: URL
    var read: @Sendable (URL) throws -> LocalDocumentFile = { try LocalDocumentFile.read($0) }

    static var local: MachineRunsIO {
        let path = ProcessInfo.processInfo.environment["SHOW_LIVE_RUNS"] ?? "~/Library/Application Support/Show/live-runs.json"
        return MachineRunsIO(registry: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    private func paths() throws -> (urls: [URL], unavailable: Int) {
        let file: LocalDocumentFile
        do { file = try read(registry) }
        catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return ([], 0) }
        guard file.data.count <= 8_388_608 else { throw CocoaError(.fileReadTooLarge) }
        let entries = try JSONDecoder().decode([JSONValue].self, from: file.data)
        var urls: [URL] = [], seen = Set<URL>(), unavailable = 0
        for entry in entries {
            guard let path = entry["path"]?.string, !path.isEmpty, (path as NSString).expandingTildeInPath.hasPrefix("/") else {
                unavailable += 1
                continue
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(url).inserted { urls.append(url) }
        }
        return (urls, unavailable)
    }

    func load() throws -> Snapshot {
        let paths = try paths()
        var runs: [MachineRun] = [], unavailable = paths.unavailable
        for url in paths.urls {
            try Task.checkCancellation()
            guard let file = try? read(url), let run = MachineRun(url, file: file) else { unavailable += 1; continue }
            if !run.terminal { runs.append(run) }
        }
        return Snapshot(runs: runs.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return ($0.title, $0.url.path) < ($1.title, $1.url.path)
        }, unavailable: unavailable)
    }

    func validate(_ run: MachineRun) -> Bool {
        guard let paths = try? paths(), paths.urls.contains(run.url), let file = try? read(run.url), let current = MachineRun(run.url, file: file) else { return false }
        return current.title == run.title
    }
}

@MainActor
@Observable
final class MachineRuns {
    private(set) var runs: [MachineRun] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var unavailable = false
    private(set) var unreadable = 0
    private(set) var now = Date()
    @ObservationIgnored var io = MachineRunsIO.local
    @ObservationIgnored var openDocument: (URL) async throws -> Void = ShowDocument.open
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private(set) var openingTask: Task<Void, Never>?
    private var openingReader: ReaderContext?
    private var openingSequence = 0

    private init(_ app: AppModel) { self.app = app }
    static func of(_ app: AppModel) -> MachineRuns { app.state { MachineRuns(app) } }
    func run(_ path: String?) -> MachineRun? { runs.first { $0.url.path == path } }

    func refresh() async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let mine = generation, io = io
        loading = true
        defer { if mine == generation { loading = false } }
        let worker = Task.detached(priority: .utility) { Result { try io.load() } }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard mine == generation, !Task.isCancelled else { return }
        now = Date()
        loaded = true
        switch result {
        case .success(let snapshot): runs = snapshot.runs; unreadable = snapshot.unavailable; unavailable = false
        case .failure: unavailable = true
        }
    }

    var waiting: Bool { app.map { openingReader?.isCurrent($0) == true && $0.keys.active == .normal } ?? false }
    func cancelOpening() {
        openingSequence &+= 1
        openingReader = nil
        openingTask?.cancel()
    }

    func open(_ path: String) {
        guard let app, let run = run(path) else { return }
        cancelOpening()
        let reader = ReaderContext(app), mine = openingSequence, io = io
        openingReader = reader
        openingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if mine == openingSequence { openingReader = nil } }
            guard reader.isCurrent(app), !Task.isCancelled else { return }
            let valid = await Task.detached(priority: .utility) { io.validate(run) }.value
            guard mine == openingSequence, reader.isCurrent(app), !Task.isCancelled, app.keys.active == .normal else { return }
            guard valid else { return app.runner.say("run document changed or disappeared; refresh Machine") }
            openingReader = nil
            do {
                try await openDocument(run.url)
                if mine == openingSequence, !Task.isCancelled, reader.isCurrent(app) { app.runner.say("opened \(run.title) in Show") }
            } catch {
                if mine == openingSequence, !Task.isCancelled, reader.isCurrent(app) { app.runner.say("couldn't open the run document in Show") }
            }
        }
    }
}
