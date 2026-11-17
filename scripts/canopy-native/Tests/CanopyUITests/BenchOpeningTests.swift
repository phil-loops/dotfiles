import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct BenchOpeningTests {
    func fixture(multiple: Bool = false) throws -> (AppModel, BenchFiles) {
        let app = world(.review(repo: "r", branch: "a"))
        let files = BenchFiles()
        files.set("/fixtures/one.json", try BenchLibraryTests().document(repo: "r", project: "tree", branch: "a", title: "One"))
        if multiple { files.set("/fixtures/two.json", try BenchLibraryTests().document(repo: "r", project: "tree", branch: "a", title: "Two")) }
        BenchLibrary.of(app).io = files.io
        return (app, files)
    }

    func begin(_ app: AppModel) throws -> Task<Void, Never> {
        app.keys.handle(",")
        app.keys.handle("T")
        return try #require(BenchOpening.of(app).task)
    }

    @Test func theKeyOpensTheExactDocumentAndObeysTheKeyboardRules() async throws {
        let (app, _) = try fixture()
        var opened: [URL] = []
        BenchOpening.of(app).openDocument = { opened.append($0) }
        let task = try begin(app)
        await task.value
        #expect(opened.map(\.path) == ["/fixtures/one.json"])
        #expect(KeyboardRule.violations(app) { $0.hasPrefix("bench.") }.isEmpty)
        #expect(app.registry.keyProblems.isEmpty)
        app.router.navigate(.forest(repo: "r", project: "tree"))
        let forestTask = try begin(app)
        await forestTask.value
        #expect(opened.count == 2)
    }

    @Test func pickerChoicesUseFullPathsAndRevalidateTheDefinition() async throws {
        let (app, files) = try fixture(multiple: true)
        var opened: [URL] = []
        let opening = BenchOpening.of(app)
        opening.openDocument = { opened.append($0) }
        let task = try begin(app)
        await task.value
        #expect(app.nav.picker?.items.map(\.label) == ["One", "Two"])
        #expect(app.nav.picker?.items.map(\.text) == ["/fixtures/one.json", "/fixtures/two.json"])
        files.set("/fixtures/two.json", try BenchLibraryTests().document(repo: "other"))
        #expect(app.nav.choose(1))
        await opening.task?.value
        #expect(opened.isEmpty)
        #expect(app.runner.note?.contains("bench changed") == true)
    }

    @Test func anUnchangedPickerChoiceOpensOnlyItsChosenDocument() async throws {
        let (app, _) = try fixture(multiple: true)
        var opened: [URL] = []
        let opening = BenchOpening.of(app)
        opening.openDocument = { opened.append($0) }
        await (try begin(app)).value
        #expect(app.nav.choose(1))
        await opening.task?.value
        #expect(opened.map(\.path) == ["/fixtures/two.json"])
    }

    @Test func aReplayedPickerCannotOpenInAnotherReader() async throws {
        let (app, _) = try fixture(multiple: true)
        var opened: [URL] = []
        BenchOpening.of(app).openDocument = { opened.append($0) }
        await (try begin(app)).value
        app.nav.close()
        app.router.navigate(.review(repo: "r", branch: "b"))
        #expect(app.nav.reopen())
        #expect(app.nav.choose(0))
        await BenchOpening.of(app).task?.value
        #expect(opened.isEmpty)
    }

    @Test func movingBeforeTheTaskStartsCannotOpenAnything() async throws {
        let (app, _) = try fixture()
        var opened: [URL] = []
        BenchOpening.of(app).openDocument = { opened.append($0) }
        let task = try begin(app)
        app.router.navigate(.review(repo: "r", branch: "b"))
        app.router.navigate(.review(repo: "r", branch: "a"))
        await task.value
        #expect(opened.isEmpty)
    }

    @Test func escapeCancelsAHeldDiscovery() async throws {
        let (app, _) = try fixture()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        BenchLibrary.of(app).io.list = { _ in
            entered.continuation.yield(())
            release.wait()
            return []
        }
        var opened: [URL] = []
        let opening = BenchOpening.of(app)
        opening.openDocument = { opened.append($0) }
        let task = try begin(app)
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        #expect(opening.waiting)
        app.keys.handle("esc")
        #expect(app.runner.note == "bench opening cancelled")
        release.signal()
        await task.value
        #expect(!opening.waiting)
        #expect(opened.isEmpty)
    }

    @Test func thePracticeAppHasAnEmptyLibraryAndAReplacedOpeningSeam() async throws {
        let app = KeyTutorSandbox.make()
        let library = BenchLibrary.of(app)
        let subject = BenchSubject.branch(repo: KeyTutorSandbox.repo, name: KeyTutorSandbox.root)
        #expect(try library.io.documents(for: subject).isEmpty)
        try await BenchOpening.of(app).openDocument(URL(fileURLWithPath: "/fixtures/practice.json"))
        #expect(KeyTutorStub.notes(app.config.port!).contains("open bench /fixtures/practice.json"))
    }

    @Test func totalsKeepEnvironmentsTimesAndBranchScopesDistinct() throws {
        let document = try #require(BenchDocument(URL(fileURLWithPath: "/fixtures/one.json"), BenchLibraryTests().document()))
        let rows = ["topic: 1 of 2 fixed on staging, 2026-11-17T09:10:11Z",
                    "other: 2 of 3 fixed on staging, 2026-11-17T09:10:11Z",
                    "topic: 0 of 2 fixed on local, 2026-11-16T09:10:11Z"].compactMap(BenchObservation.parse)
        let entry = BenchEntry(document: document, status: .observations(rows))
        let branch = try #require(entry.totals(for: .branch(repo: "loops", name: "topic")))
        #expect(branch.map(\.total) == [2, 2])
        let forest = try #require(entry.totals(for: .forest(repo: "loops", project: "forest")))
        #expect(forest.map(\.total) == [5, 2])
        #expect(forest.map(\.fixed) == [3, 0])
        #expect(forest.map(\.environment) == ["staging", "local"])
        let summary = BenchSummary.rows([entry], for: .forest(repo: "loops", project: "forest"))
        #expect(summary.first?.text.contains("3 of 5 fixed on staging") == true)
        #expect(summary.first?.text.contains("2026") == true)
        #expect(summary.count == 2)
    }
}
