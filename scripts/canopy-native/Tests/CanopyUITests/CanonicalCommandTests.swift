import CanopyCore
import Testing
@testable import CanopyUI

@MainActor struct CanonicalCommandTests {
    let names = ["parent", "child", "requires"]

    @Test func ancestryDiscoveryShowsCanonicalNamesOnBothPages() {
        for route in [Route.review(repo: "r", branch: "b"), .forest(repo: "r", project: "tree")] {
            let app = world(route)
            if case .forest = route { app.setCursor("b:r:b") }
            let completions = app.keys.completions("").map(\.id)
            let menu = MenuState().commands(app).map(\.id)
            for name in names {
                #expect(completions.filter { $0 == name }.count == 1)
                #expect(menu.filter { $0 == name }.count == 1)
                #expect(!completions.contains("review.\(name)") && !completions.contains("forest.\(name)"))
                #expect(!menu.contains("review.\(name)") && !menu.contains("forest.\(name)"))
            }
        }
    }

    @Test func eligibleCompatibilityNamesRemainSearchableWithoutLeakingOtherPages() {
        let app = world(.review(repo: "r", branch: "b")), menu = MenuState()
        #expect(app.keys.completions("review.par").contains { $0.id == "parent" })
        menu.query = "review.par"
        #expect(menu.commands(app).map(\.id) == ["parent"])
        menu.query = "forest.par"
        #expect(!menu.commands(app).contains { $0.id == "parent" })
        menu.query = "parent"
        #expect(menu.rows(app).first { $0.id == "parent" }?.side == ":parent")
    }

    @Test func exactLegacyInvocationStillRunsThePageImplementation() {
        let app = world(.review(repo: "r", branch: "b"))
        app.cmdline = "review.parent"
        #expect(app.completions.map(\.id) == ["review.parent"])
        app.runCmdline()
        #expect(app.router.route.branchID == "r:a")
    }

    @Test func exactCompatibilityArgumentsAreNotRewrittenToAnotherCommandID() {
        let app = world()
        var received: String?
        app.registry.register(Command(id: "canonical.echo", title: "echo", scope: .global, takes: "text", local: { _, _ in }))
        app.registry.register(Command(id: "legacy.echo", title: "echo", scope: .global, takes: "text", local: { _, arg in received = arg as? String }))
        app.registry.alias(["legacy.echo"], to: "canonical.echo")
        app.cmdline = "legacy.echo keep literal text"
        #expect(app.completions.map(\.id) == ["legacy.echo"])
        app.runCmdline()
        #expect(received == "keep literal text")
    }

    @Test func aRouterWithNoUnderlyingBranchDoesNotAdvertiseAncestry() {
        for route in [Route.review(repo: "r", branch: "missing"), .forest(repo: "r", project: "missing")] {
            let app = world(route)
            for name in names {
                #expect(app.registry.command(name)?.available?(nil) == false)
                #expect(!app.keys.completions("").contains { $0.id == name })
            }
        }
    }

    @Test func menuEligibilityCanRetainAnAliasWhoseCanonicalIsQuiet() {
        let app = world(), menu = MenuState()
        app.registry.register(Command(id: "quiet.canonical", title: "quiet canonical", scope: .global, quiet: true))
        app.registry.register(Command(id: "visible.alias", title: "visible alias", scope: .global))
        app.registry.alias(["visible.alias"], to: "quiet.canonical")
        menu.query = "visible.alias"
        #expect(menu.commands(app).map(\.id) == ["visible.alias"])
    }
}
