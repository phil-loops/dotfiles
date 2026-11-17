import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor final class HeldGitHubOrigin {
    var calls = 0
    var pending: [Int: CheckedContinuation<String?, Never>] = [:]

    func read(_ app: AppModel) async -> String? {
        calls += 1
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }

    func release(_ id: Int, _ web: String?) { pending.removeValue(forKey: id)?.resume(returning: web) }
}

@MainActor @Suite(.serialized) struct ReviewGitHubOpeningTests {
    let branch = "add-hankles-limited-label"
    let id = ReviewPageTests.branch

    func app() async throws -> (AppModel, Int) {
        let (app, port) = try await LookupTests().app()
        app.focus(pane: reviewDiffPane)
        ReviewPageState.of(app).setCursor("l|a.ts|R:2")
        return (app, port)
    }

    func run(_ app: AppModel, main: Bool = false) throws -> Task<Void, Never> {
        app.keys.handle("space"); app.keys.handle("o"); app.keys.handle(main ? "m" : "b")
        return try #require(ReviewGitHubOpening.of(app).task)
    }

    @Test func leavingBeforeSchedulingDoesNotResolveOrOpen() async throws {
        let (app, _) = try await app(), page = ReviewPageState.of(app)
        let held = HeldGitHubOrigin()
        page.githubWeb = held.read
        var opened = 0
        ShipState.of(app).openURL = { _ in opened += 1 }
        let task = try run(app)
        app.router.navigate(.machine)
        await task.value
        #expect(held.calls == 0 && opened == 0)
    }

    @Test func aReaderRoundTripCannotReviveAnExternalOpenOrItsFailure() async throws {
        for change in ["visit", "cursor", "focus", "picker", "mode", "source"] {
            for answer in ["https://github.com/o/r", nil] as [String?] {
                let (app, _) = try await app(), page = ReviewPageState.of(app)
                let held = HeldGitHubOrigin()
                page.githubWeb = held.read
                var opened = 0
                ShipState.of(app).openURL = { _ in opened += 1 }
                let task = try run(app)
                await until("the held origin") { held.pending[1] != nil }
                switch change {
                case "visit": app.router.navigate(.machine); app.router.navigate(.review(repo: "loops", branch: branch))
                case "cursor": page.setCursor("l|a.ts|R:3"); page.setCursor("l|a.ts|R:2")
                case "focus": app.focus(pane: ShipSeam.wordsPane); app.focus(pane: reviewDiffPane)
                case "picker": app.nav.pick("new picker", [PickItem(label: "keep this")]) { _ in }
                case "mode": app.keys.setMode(.select); app.keys.setMode(.normal)
                default:
                    #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
                }
                app.runner.say("newer feedback")
                held.release(1, answer)
                await task.value
                #expect(opened == 0 && app.runner.note == "newer feedback")
                if change == "picker" { #expect(app.nav.picker?.title == "new picker") }
            }
        }
    }

    @Test func escapeCancelsOnlyThePendingHandoff() async throws {
        let (app, _) = try await app(), page = ReviewPageState.of(app)
        let held = HeldGitHubOrigin()
        page.githubWeb = held.read
        var opened = 0
        ShipState.of(app).openURL = { _ in opened += 1 }
        let task = try run(app)
        await until("the held origin") { held.pending[1] != nil }
        app.keys.handle("esc")
        #expect(app.runner.note == "GitHub opening cancelled")
        held.release(1, "https://github.com/o/r")
        await task.value
        #expect(opened == 0 && ReviewGitHubOpening.of(app).task == nil)
    }

    @Test func aNewerHandoffOwnsSuccessAndFeedback() async throws {
        for answer in ["https://github.com/old/repo", nil] as [String?] {
            let (app, _) = try await app(), page = ReviewPageState.of(app)
            let held = HeldGitHubOrigin()
            page.githubWeb = held.read
            var opened: [URL] = []
            ShipState.of(app).openURL = { opened.append($0) }
            let old = try run(app)
            await until("the old origin") { held.pending[1] != nil }
            let new = try run(app, main: true)
            await until("the new origin") { held.pending[2] != nil }
            held.release(2, "https://github.com/new/repo")
            await new.value
            #expect(opened.map(\.absoluteString) == ["https://github.com/new/repo/blob/main/a.ts#L2"])
            #expect(!ReviewGitHubOpening.backOut(app))
            app.runner.say("newer feedback")
            held.release(1, answer)
            await old.value
            #expect(opened.count == 1 && app.runner.note == "newer feedback")
        }
    }

    @Test func mainUsesTheConfiguredTrunkAndHistoricalLinesKeepTheirCommit() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        var repo = try #require(app.store.rawView("repo", "loops"))
        repo["main"] = "master"
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                                                   upserts: ["repo": ["loops": .object(repo)]])) == .ok)
        page.githubWeb = { _ in "https://github.com/o/r" }
        var opened: [String] = []
        ShipState.of(app).openURL = { opened.append($0.absoluteString) }
        await (try run(app, main: true)).value
        #expect(opened.last == "https://github.com/o/r/blob/master/a.ts#L2")
        let historical = String(repeating: "1", count: 40)
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        page.commitScopeChanged("base..\(historical)")
        await until("the scoped diff") { page.commitFiles?.sha == "base..\(historical)" }
        page.setCursor("l|a.ts|R:2")
        await (try run(app)).value
        #expect(opened.last == "https://github.com/o/r/blob/\(historical)/a.ts#L2")
    }

    @Test func currentOriginFailureSettlesWithoutOpening() async throws {
        let (app, _) = try await app(), page = ReviewPageState.of(app)
        page.githubWeb = { _ in nil }
        var opened = false
        ShipState.of(app).openURL = { _ in opened = true }
        await (try run(app)).value
        #expect(!opened && app.runner.note?.contains("couldn't read origin") == true)
        #expect(!ReviewGitHubOpening.backOut(app))
    }

    @Test func originResolutionRequiresTheExactHeadAndNeverBorrowsAnotherReposCheckout() async throws {
        for sha in [nil, "short", String(repeating: "f", count: 40), SyntaxSourceTests().tip] as [String?] {
            let (app, port) = try await app(), page = ReviewPageState.of(app)
            var repo = try #require(app.store.rawView("repo", "loops"))
            repo["id"] = "other"; repo["name"] = "other"
            var branch = try #require(app.store.rawView("branch", id))
            branch["id"] = .string("other:\(self.branch)"); branch["repo"] = "other"
            #expect(app.store.applyPatch(try Patch.make(domain: Domain.git, version: (app.store.versions[Domain.git] ?? 0) + 1,
                upserts: ["repo": ["other": .object(repo)], "branch": ["other:\(self.branch)": .object(branch)]])) == .ok)
            let source = try #require(BranchSource.current(app, "other:\(self.branch)"))
            page.helixDirs["\(source.name)@\(source.tip)"] = "/wrong-repository"
            var visited: [String] = []
            page.githubOrigin = { dir in visited.append(dir); return "https://github.com/right/repo" }
            var response: JSONObject = ["ok": true, "dir": "/right-repository"]
            if let sha { response["sha"] = .string(sha) }
            ShipStub.answer(port, "POST", "/other/review-helix", String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            let web = await page.githubPage(app, source: source)
            #expect(visited == (sha == source.tip ? ["/right-repository"] : []))
            #expect(web == (sha == source.tip ? "https://github.com/right/repo" : nil))
            let post = try #require(ShipStub.posts(port).last { $0.path == "/other/review-helix" })
            #expect(post.body["branch"] == .string(source.name) && post.body["op"] == "where")
        }
    }
}
