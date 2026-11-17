import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct FileColumnTests {
    let base = ReviewPageTests()
    let probe = ReviewProbeTests()

    func panes(_ app: AppModel) -> [String] { (app.provider?.panes(app) ?? []).map(\.id) }

    @Test func twoFilesListBesideTheDiffAndEnterOpensOne() async throws {
        let (app, _) = try await base.app(probe.payload([("queries/message.ts", "@@ -1,1 +1,1 @@\n-a\n+A"), ("models/message.ts", "@@ -1,1 +1,1 @@\n-b\n+B")]))
        let pg = ReviewPageState.of(app)
        #expect(pg.showsTree && panes(app).contains(reviewTreePane))
        #expect(ReviewPage.treeRows(pg) == ["f|queries/message.ts", "f|models/message.ts"])
        app.focus(pane: reviewTreePane)
        app.setCursor("f|models/message.ts")
        app.keys.handle("ret")
        #expect(pg.here?.path == "models/message.ts" && app.pane?.id == reviewDiffPane)
    }

    @Test func oneFileHasNoColumn() async throws {
        let (app, _) = try await base.app(probe.payload([("models/message.ts", "@@ -1,1 +1,1 @@\n-old\n+new")]))
        #expect(!ReviewPageState.of(app).showsTree && !panes(app).contains(reviewTreePane))
    }

    @Test func returnToTakesTheColumnWhileOpen() async throws {
        let (app, _) = try await base.app(probe.payload([("queries/message.ts", "@@ -1,1 +1,1 @@\n-a\n+A"), ("models/message.ts", "@@ -1,1 +1,1 @@\n-b\n+B")]))
        app.runner.dispatch("review.guide", via: .key)
        #expect(panes(app).contains(reviewGuidePane) && !panes(app).contains(reviewTreePane))
    }
}
