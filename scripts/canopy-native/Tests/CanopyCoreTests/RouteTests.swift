import Foundation
import Testing
@testable import CanopyCore

@Suite struct RouteTests {
    @Test(arguments: [
        ("/v2", Route.forests),
        ("/v2/", Route.forests),
        ("/v2/dashboard", .dashboard),
        ("/v2/todo", .todo),
        ("/v2/machine", .machine),
        ("/v2/wiki", .wiki(slug: nil)),
        ("/v2/wiki/canopy-v2-sync", .wiki(slug: "canopy-v2-sync")),
        ("/v2/tutor", .tutor(session: nil)),
        ("/v2/tutor/abc", .tutor(session: "abc")),
        ("/v2/p/loops/svix-timeouts", .forest(repo: "loops", project: "svix-timeouts")),
        ("/v2/b/loops/add-x", .review(repo: "loops", branch: "add-x")),
        ("/v2/b/loops/goal-metrics/metrics-job", .review(repo: "loops", branch: "goal-metrics/metrics-job")),
        ("/v2/b/loops/refs/stack/feat-integration", .review(repo: "loops", branch: "refs/stack/feat-integration")),
        ("/v2/b/loops/review/pr-11285", .review(repo: "loops", branch: "review/pr-11285")),
        ("/v2/b/loops/add-x?base=main", .review(repo: "loops", branch: "add-x", base: "main")),
        ("/v2/b/loops/add-x?base=bogus", .review(repo: "loops", branch: "add-x")),
        ("/v2/nonsense", .forests),
        ("/v2/b", .forests),
        ("/elsewhere", .forests),
        ("canopy://v2/p/loops/svix-timeouts", .forest(repo: "loops", project: "svix-timeouts")),
        ("canopy:///v2/b/loops/a/b", .review(repo: "loops", branch: "a/b")),
        ("canopy://open?path=/v2/todo", .todo),
        ("http://127.0.0.1:62497/v2/machine", .machine),
    ])
    func parses(_ address: String, _ want: Route) {
        #expect(Route(address) == want)
    }

    @Test func pathsRoundTripWithEncoding() {
        let routes: [Route] = [
            .forests, .dashboard, .todo, .machine, .wiki(slug: nil), .wiki(slug: "a b"), .tutor(session: "s 1"),
            .forest(repo: "loops", project: "url-safety"), .review(repo: "loops", branch: "a/b c", base: "outgoing"),
            .review(repo: "loops", branch: Route.integrationRef("p")),
        ]
        for r in routes { #expect(Route(r.path) == r, "\(r.path)") }
        #expect(Route.review(repo: "loops", branch: "a/b c").path == "/v2/b/loops/a/b%20c")
        #expect(Route.forest(repo: "loops", project: "p").projectID == "loops:p")
        #expect(Route.review(repo: "loops", branch: "a/b").branchID == "loops:a/b")
        #expect(Route.review(repo: "loops", branch: "a/b").arg == "loops/a/b")
    }

    @Test func integrationRefs() {
        #expect(Route.integrationOf("refs/stack/url-safety-integration") == "url-safety")
        #expect(Route.integrationOf("add-x") == nil)
    }

    @MainActor @Test func historyBackAndForward() {
        let r = Router()
        var navs: [String] = []
        r.onNavigate = { _, to in navs.append(to.path) }
        r.navigate(.todo)
        r.navigate(.todo)
        r.navigate("/v2/machine")
        #expect(r.back == [.forests, .todo])
        #expect(r.goBack())
        #expect(r.route == .todo)
        #expect(r.forward == [.machine])
        r.navigate(.dashboard)
        #expect(r.forward.isEmpty)
        #expect(r.goBack() && r.goBack())
        #expect(r.route == .forests)
        #expect(!r.goBack())
        #expect(r.goForward())
        #expect(navs == ["/v2/todo", "/v2/machine", "/v2/todo", "/v2/dashboard", "/v2/todo", "/v2", "/v2/todo"])
    }

    @Test func theQueryIsKeptForThePageNotTheRoute() {
        #expect(Route("/v2/tutor?concept=lock-ttl") == .tutor(session: nil))
        #expect(Route.query("/v2/tutor?concept=lock-ttl") == ["concept": "lock-ttl"])
        #expect(Route.query("canopy://v2/tutor?import=term-1&say=a%20b") == ["import": "term-1", "say": "a b"])
        #expect(Route.query("/v2/b/loops/x") == [:])
    }

    @MainActor @Test func anAddressHandsItsQueryToThePageOnce() {
        let r = Router()
        r.navigate("/v2/tutor?concept=a")
        #expect(r.route == .tutor(session: nil) && r.query == ["concept": "a"])
        r.navigate("/v2/tutor?concept=b")
        #expect(r.query == ["concept": "b"], "a link to where you are still delivers its query")
        #expect(r.takeQuery() == ["concept": "b"] && r.query.isEmpty)
        r.navigate("/v2/tutor?concept=c")
        r.navigate(.forests)
        #expect(r.query.isEmpty, "moving on drops it")
    }
}
