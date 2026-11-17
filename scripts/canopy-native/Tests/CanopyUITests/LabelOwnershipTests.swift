import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct LabelOwnershipTests {
    @Test func refusingATargetPrecedesEveryCursorAndCommandEffect() {
        let app = world(.forest(repo: "r", project: "tree"))
        app.setCursor("b:r:a")
        var calls = 0
        app.registry.register(Command(id: "test.label.effect", title: "test", scope: .global, local: { _, _ in calls += 1 }))
        var target = LabelTarget(pane: "main", key: "b:r:c", rect: .zero, run: RouteTo("test.label.effect"))
        target.acceptsPick = { false }
        let jumps = app.jumps.back.count, focus = app.focusGeneration, cursor = app.cursorGeneration(in: "main")
        app.pickTarget(target)
        #expect(app.selected == "b:r:a")
        #expect(app.jumps.back.count == jumps)
        #expect(app.focusGeneration == focus && app.cursorGeneration(in: "main") == cursor)
        #expect(calls == 0)
    }

    @Test func unguardedAndAcceptedTargetsRetainTheirSelectionBehavior() {
        let app = world(.forest(repo: "r", project: "tree"))
        app.setCursor("b:r:a")
        let target = LabelTarget(pane: "main", key: "b:r:c", rect: .zero, run: RouteTo("cursor.set", target: "b:r:c"))
        app.pickTarget(target)
        #expect(app.selected == "b:r:c")
        var accepted = LabelTarget(pane: "main", key: "b:r:b", rect: .zero, run: RouteTo("cursor.set", target: "b:r:b"))
        accepted.acceptsPick = { true }
        app.pickTarget(accepted)
        #expect(app.selected == "b:r:b")
    }

    @Test func aLabelChoiceOwnsExactlyItsOpeningAndClosingTransitions() {
        let app = world(.forest(repo: "r", project: "tree"))
        let reader = ReaderContext(app)
        app.keys.openLayer(.labels); app.keys.closeLayer()
        #expect(reader.isCurrentAfterLabelChoice(app))
        app.keys.openLayer(.labels); app.keys.closeLayer()
        #expect(!reader.isCurrentAfterLabelChoice(app))
    }

    @Test func movementDuringLabelsRevokesTheirReader() {
        let app = world(.forest(repo: "r", project: "tree"))
        app.setCursor("b:r:a")
        let reader = ReaderContext(app)
        app.keys.openLayer(.labels)
        app.moveCursor(1); app.moveCursor(-1)
        app.keys.closeLayer()
        #expect(!reader.isCurrentAfterLabelChoice(app))
    }
}
