import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

final class LocalDocumentFiles: @unchecked Sendable {
    let registry = URL(fileURLWithPath: "/fixtures/live-runs.json")
    private let lock = NSLock()
    private var files: [URL: LocalDocumentFile] = [:]

    func set(_ path: String, _ data: Data, at date: Date? = nil) {
        lock.withLock { files[URL(fileURLWithPath: path)] = LocalDocumentFile(data: data, modified: date) }
    }
    func remove(_ url: URL) { lock.withLock { _ = files.removeValue(forKey: url) } }
    var io: MachineRunsIO {
        MachineRunsIO(registry: registry, read: { url in try self.lock.withLock {
            guard let file = self.files[url] else { throw CocoaError(.fileNoSuchFile) }
            return file
        } })
    }
}

@MainActor struct MachineRunsTests {
    let first = "/fixtures/one.json", second = "/fixtures/two.json"
    let now = Date(timeIntervalSince1970: 1_000)

    func document(_ title: String = "Eval", state: String = "running", done: Int = 5, total: Int = 10) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["mode": "live", "title": .string(title), "staleAfter": 600,
            "status": ["state": .string(state), "done": .number(Double(done)), "total": .number(Double(total)), "current": "round 2"], "sections": []]))
    }
    func registry(_ paths: [String]) throws -> Data {
        try JSONEncoder().encode(paths.map { JSONValue.object(["path": .string($0), "title": "old registry title", "openedAt": "2020-01-01T00:00:00Z"]) })
    }
    func fixture() throws -> LocalDocumentFiles {
        let files = LocalDocumentFiles()
        files.set(files.registry.path, try registry([first]))
        files.set(first, try document(), at: now)
        return files
    }
    func app(_ files: LocalDocumentFiles) async -> (AppModel, MachineRuns) {
        var config = AppConfig(); config.route = .machine
        let app = testApp(config: config, port: 1)
        let runs = MachineRuns.of(app); runs.io = files.io
        await runs.refresh()
        app.focus(pane: "queue")
        return (app, runs)
    }

    @Test func malformedRegistryPeersAndDuplicatesDoNotHideValidDocuments() throws {
        let files = try fixture()
        files.set(files.registry.path, Data(#"[{"path":"/fixtures/one.json","title":"old"},{"bad":true},{"path":"/fixtures/one.json"},{"path":"/fixtures/gone.json"}]"#.utf8))
        let snapshot = try files.io.load()
        #expect(snapshot.runs.map(\.title) == ["Eval"])
        #expect(snapshot.runs.first?.modified == now)
        #expect(snapshot.unavailable == 2)
    }

    @Test func terminalStateComesFromTheProducerRatherThanTheCounts() throws {
        let files = LocalDocumentFiles()
        let states = ["running", "preparing", "paused", "new-state", "", "done", "failed"]
        let paths = states.indices.map { "/fixtures/\($0).json" }
        files.set(files.registry.path, try registry(paths))
        for (index, state) in states.enumerated() { files.set(paths[index], try document(state, state: state, done: 12, total: 10), at: now) }
        let snapshot = try files.io.load()
        #expect(Set(snapshot.runs.map(\.state)) == Set(states.prefix(5)))
        #expect(snapshot.runs.allSatisfy { $0.progress == "12 of 10" })
        files.set(paths[0], try document(done: 0, total: 0), at: now)
        #expect(try files.io.load().runs.first { $0.url.path == paths[0] }?.progress == "0 of 0")
    }

    @Test func freshnessUsesTheDocumentVersionAndNeverProvesProcessLiveness() throws {
        let run = try #require(MachineRun(URL(fileURLWithPath: first), file: LocalDocumentFile(data: document(), modified: now)))
        #expect(!run.stale(at: now.addingTimeInterval(600)))
        #expect(run.stale(at: now.addingTimeInterval(601)))
        #expect(run.reportedState == "reported running")
        #expect(run.freshness(at: now.addingTimeInterval(15)) == "last report 15s ago")
        let unknown = try #require(MachineRun(run.url, file: LocalDocumentFile(data: document(state: "paused"), modified: nil)))
        #expect(!unknown.stale(at: now.addingTimeInterval(10_000)))
        #expect(unknown.freshness(at: now) == "report time unavailable")
    }

    @Test func aRunRowOpensTheExactDocumentAndCannotEnterAProcessKillRoute() async throws {
        let files = try fixture(), (app, runs) = await app(files)
        var opened: [URL] = []; runs.openDocument = { opened.append($0) }
        #expect(app.selected == "run:\(first)")
        #expect(app.target(for: .queue) == nil)
        #expect(app.target(for: .reportedRun) == first)
        app.keys.handle("X")
        #expect(app.runner.armed == nil)
        #expect(try app.registry.command("machine.queue.stop")!.write!(first, nil) == nil)
        app.keys.handle("ret")
        await runs.openingTask?.value
        #expect(opened.map(\.path) == [first])
        #expect(KeyboardRule.violations(app) { $0.hasPrefix("machine.") }.isEmpty)
        #expect(!app.registry.command("machine.main")!.available!(nil))
    }

    @Test func openingAcceptsNewProgressButRefusesDeletionAndReassignment() async throws {
        let files = try fixture(), (app, runs) = await app(files)
        var opened: [URL] = []; runs.openDocument = { opened.append($0) }
        files.set(first, try document(state: "done", done: 10), at: now.addingTimeInterval(30))
        app.keys.handle("ret"); await runs.openingTask?.value
        #expect(opened.count == 1)
        files.set(first, try document("Another run"), at: now)
        app.keys.handle("ret"); await runs.openingTask?.value
        #expect(opened.count == 1)
        files.remove(URL(fileURLWithPath: first))
        app.keys.handle("ret"); await runs.openingTask?.value
        #expect(opened.count == 1)
    }

    @Test func anOpeningCannotSurviveAnAwayAndBackVisit() async throws {
        let files = try fixture(), (app, runs) = await app(files)
        var opened: [URL] = []; runs.openDocument = { opened.append($0) }
        app.keys.handle("ret")
        app.router.navigate(.forests); app.router.navigate(.machine)
        await runs.openingTask?.value
        #expect(opened.isEmpty)
    }

    @Test func aCancelledRefreshSettlesAndDoesNotPublishItsHeldRead() async throws {
        let files = try fixture(), (_, runs) = await app(files)
        let entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let io = files.io
        runs.io.read = { url in
            if url == io.registry { entered.continuation.yield(()); release.wait() }
            return try io.read(url)
        }
        let task = Task { await runs.refresh() }
        var iterator = entered.stream.makeAsyncIterator(); await iterator.next()
        task.cancel(); release.signal(); await task.value
        #expect(!runs.loading)
        #expect(!runs.unavailable)
        #expect(runs.runs.first?.title == "Eval")
    }

    @Test func aNewerRefreshOwnsItsSnapshotWhenAnOlderReadReturns() async throws {
        let files = try fixture(), (_, runs) = await app(files)
        let entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let old = files.io
        runs.io.read = { url in
            if url == old.registry { entered.continuation.yield(()); release.wait() }
            return try old.read(url)
        }
        let task = Task { await runs.refresh() }
        var iterator = entered.stream.makeAsyncIterator(); await iterator.next()
        let newer = LocalDocumentFiles()
        newer.set(newer.registry.path, try registry([second]))
        newer.set(second, try document("New snapshot"), at: now)
        runs.io = newer.io; await runs.refresh()
        release.signal(); await task.value
        #expect(runs.runs.map(\.title) == ["New snapshot"])
    }

    @Test func anUnavailableRegistryPreservesDatedReportsAndRecoversToEmpty() async throws {
        let files = try fixture(), (_, runs) = await app(files)
        files.set(files.registry.path, Data("{".utf8))
        await runs.refresh()
        #expect(runs.unavailable && runs.runs.count == 1)
        files.set(files.registry.path, Data("[]".utf8))
        await runs.refresh()
        #expect(!runs.unavailable && runs.runs.isEmpty)
    }

    @Test nonisolated func bytesAndModificationTimeComeFromTheOpenedFile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("version A".utf8).write(to: path)
        let date = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        let file = try LocalDocumentFile.read(path)
        #expect(file.data == Data("version A".utf8))
        #expect(file.modified == date)
    }

    @Test func thePracticeWorldReplacesBothFileReadingAndOpening() async throws {
        let app = KeyTutorSandbox.make(), reports = MachineRuns.of(app)
        await reports.refresh()
        #expect(reports.runs.isEmpty && !reports.unavailable)
        try await reports.openDocument(URL(fileURLWithPath: first))
        #expect(KeyTutorStub.notes(app.config.port!).contains("open run \(first)"))
    }
}
