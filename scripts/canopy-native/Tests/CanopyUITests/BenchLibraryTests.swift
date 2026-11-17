import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

final class BenchFiles: @unchecked Sendable {
    let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var outputs: [URL: String] = [:]

    func set(_ path: String, _ data: Data, status: String = "no runs yet") {
        lock.withLock {
            let url = URL(fileURLWithPath: path)
            files[url] = data
            outputs[url] = status
        }
    }

    func remove(_ url: URL) { lock.withLock { _ = files.removeValue(forKey: url) } }

    var io: BenchIO {
        BenchIO(directory: URL(fileURLWithPath: "/fixtures"),
                read: { url in try self.lock.withLock {
                    guard let data = self.files[url] else { throw CocoaError(.fileNoSuchFile) }
                    return data
                } },
                list: { _ in self.lock.withLock { Array(self.files.keys) } },
                status: { url, _ in try self.lock.withLock { try #require(self.outputs[url]) } })
    }
}

@MainActor struct BenchLibraryTests {
    let branch = BenchSubject.branch(repo: "loops", name: "topic")
    let status = "topic: 1 of 2 fixed on staging, 2026-11-17T09:10:11.123Z"

    func document(repo: String = "loops", project: String = "forest", branch: String = "topic", title: String = "Replay") throws -> Data {
        let doc: JSONValue = ["mode": "bench", "title": .string(title), "sections": [],
                              "bench": ["repo": .string(repo), "project": .string(project),
                                        "groups": [["branch": .string(branch)]]]]
        return try JSONEncoder().encode(doc)
    }

    @Test func discoveryMatchesTheExactRepoAndNamedBranchOrForest() throws {
        let files = BenchFiles()
        files.set("/fixtures/a.json", try document(), status: status)
        files.set("/fixtures/b.json", try document(repo: "other"), status: status)
        files.set("/fixtures/c.json", try document(branch: "topic-child"), status: status)
        files.set("/fixtures/not-a-bench.json", Data(#"{"mode":"deck","title":"Ordinary","sections":[]}"#.utf8))
        files.set("/fixtures/malformed.json", Data("{".utf8))
        let entries = try files.io.load(branch)
        #expect(entries.map(\.document.url.lastPathComponent) == ["a.json"])
        #expect(entries[0].observations(for: branch).map(\.fixed) == [1])
        #expect(entries[0].document.project == "forest")
        #expect(try files.io.load(.forest(repo: "loops", project: "forest")).count == 2)
        #expect(try files.io.load(.forest(repo: "other", project: "forest")).count == 1)
    }

    @Test func resultParsingPreservesTheEnvironmentAndObservationTime() {
        let output = status + "\ntopic: 0 of 2 fixed on local, 2026-11-16T01:02:03Z\n"
        guard case .observations(let rows) = BenchStatus.decode(output) else { Issue.record("missing observations"); return }
        #expect(rows.map(\.environment) == ["staging", "local"])
        #expect(rows.map(\.recordedAt) == ["2026-11-17T09:10:11.123Z", "2026-11-16T01:02:03Z"])
        #expect(rows.map(\.total) == [2, 2])
        #expect(BenchStatus.decode("no runs yet\n") == .noRuns)
        #expect(BenchStatus.decode("") == .observations([]))
        #expect(BenchStatus.decode("topic: 3 of 2 fixed on staging, 2026-11-17T01:00:00Z") == .unavailable)
        #expect(BenchStatus.decode("topic: 1 of 1 fixed on staging, not-a-time") == .unavailable)
        #expect(BenchStatus.decode(status + "\nunrecognized output") == .unavailable)
    }

    @Test func missingRecordAndFailedStatusRemainDifferentFacts() throws {
        let files = BenchFiles()
        files.set("/fixtures/bench.json", try document())
        #expect(try files.io.load(branch).first?.status == .noRuns)
        var io = files.io
        io.status = { _, _ in throw CocoaError(.fileReadUnknown) }
        #expect(try io.load(branch).first?.status == .unavailable)
        io.list = { _ in [] }
        #expect(try io.load(branch).isEmpty)
    }

    @Test func changedAndDeletedDocumentsLoseTheirOpeningAuthority() throws {
        let files = BenchFiles()
        let url = URL(fileURLWithPath: "/fixtures/bench.json")
        files.set(url.path, try document(), status: status)
        let entry = try #require(files.io.load(branch).first)
        #expect(files.io.validate(entry.document, for: branch))
        files.set(url.path, try document(repo: "other"), status: status)
        #expect(!files.io.validate(entry.document, for: branch))
        files.set(url.path, try document(title: "changed definition"), status: status)
        #expect(!files.io.validate(entry.document, for: branch))
        files.remove(url)
        #expect(!files.io.validate(entry.document, for: branch))
    }

    @Test func aDocumentChangedDuringItsStatusReadHasNoObservation() throws {
        let files = BenchFiles()
        let url = URL(fileURLWithPath: "/fixtures/bench.json")
        files.set(url.path, try document(), status: status)
        let changed = try document(repo: "other")
        let result = status
        var io = files.io
        io.status = { url, _ in
            files.set(url.path, changed)
            return result
        }
        #expect(try io.load(branch).first?.status == .unavailable)
    }

    @Test func collidingRecordNamesDoNotBorrowEachOthersResults() throws {
        let files = BenchFiles()
        files.set("/fixtures/one/bench.json", try document(), status: status)
        files.set("/fixtures/two/bench.json", try document(repo: "other"), status: status)
        #expect(try files.io.load(branch).first?.status == .unavailable)
    }

    @Test func productionDiscoveryIncludesNestedRecordingCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try document().write(to: root.appendingPathComponent("bench.json"))
        try document(repo: "other").write(to: archive.appendingPathComponent("bench.json"))
        var io = BenchIO(directory: root)
        io.status = { _, _ in Issue.record("colliding recording must not be read"); return "no runs yet" }
        #expect(try io.load(branch).first?.status == .unavailable)
    }

    @Test func aNewerSubjectOwnsTheLibraryAfterAnOlderReadFinishes() async throws {
        let files = BenchFiles()
        files.set("/fixtures/old.json", try document())
        files.set("/fixtures/new.json", try document(branch: "new"))
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let library = BenchLibrary()
        library.io = files.io
        library.io.status = { url, _ in
            if url.lastPathComponent == "old.json" {
                entered.continuation.yield(())
                release.wait()
            }
            return "no runs yet"
        }
        let old = Task { await library.load(branch) }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        let newer = BenchSubject.branch(repo: "loops", name: "new")
        await library.load(newer)
        release.signal()
        await old.value
        #expect(library.subject == newer)
        #expect(library.entries.map(\.document.url.lastPathComponent) == ["new.json"])
        #expect(!library.loading)
    }

    @Test func cancellationSettlesLoadingAndStopsFurtherStatusReads() async throws {
        let files = BenchFiles()
        files.set("/fixtures/a.json", try document())
        files.set("/fixtures/b.json", try document())
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let library = BenchLibrary()
        library.io = files.io
        library.io.status = { url, _ in
            #expect(url.lastPathComponent == "a.json")
            entered.continuation.yield(())
            release.wait()
            return "no runs yet"
        }
        let task = Task { await library.load(branch) }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        release.signal()
        await task.value
        #expect(!library.loading)
        #expect(library.entries.isEmpty)
        #expect(!library.failed)
    }

    @Test func theRealStatusCommandOnlyReadsIsolatedRecordedRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("fixture.json")
        let scenario = #"{"mode":"bench","title":"fixture","sections":[],"bench":{"repo":"fixture","project":"forest","envs":[{"name":"fixture","base":"http://127.0.0.1:1","key":"unused"}],"groups":[{"id":"one","branch":"topic"}],"steps":[{"id":"request","group":"one","claim":{"today":{"status":400},"fixed":{"status":200}}}]}}"#
        try Data(scenario.replacingOccurrences(of: #""fixed":{"status":200}"#, with: #""fixed":{"status":201}"#).utf8).write(to: doc)
        let run = #"{"env":{"name":"fixture"},"at":"2026-11-17T09:10:11.123Z","seen":{"request":{"status":200}}}"#
        try Data((run + "\n").utf8).write(to: root.appendingPathComponent("fixture.jsonl"))
        var environment = ProcessInfo.processInfo.environment
        environment["BENCH_RUNS"] = root.path
        let output = try BenchIO.recordedStatus(doc, data: Data(scenario.utf8), environment: environment)
        #expect(output == "topic: 1 of 1 fixed on fixture, 2026-11-17T09:10:11.123Z\n")
        #expect(BenchStatus.decode(output) == .observations([try #require(BenchObservation.parse(output.trimmingCharacters(in: .whitespacesAndNewlines)))]))
    }
}
