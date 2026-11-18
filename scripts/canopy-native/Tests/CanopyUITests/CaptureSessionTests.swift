import AppKit
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor struct CaptureSessionTests {
    @Test func captureKeepsDraftsAndProgressInMemoryAndRefusesEditorCommands() throws {
        let app = world(.review(repo: "r", branch: "a"))
        let board = Clipboard.board
        defer { Clipboard.board = board }
        let original = MemoryDefaults()
        original.set("kept", forKey: "canopy.ship.text.fixture")
        let ship = ShipState.of(app)
        ship.defaults = original
        KeyTutor.of(app).store = MemoryProgress(.init(lesson: "ladder", step: 2, done: ["start"]))
        CaptureSession.configure(app)
        #expect(ship.defaults is MemoryDefaults)
        #expect(ship.text("fixture") == "kept")
        ship.defaults.set("changed", forKey: "canopy.ship.text.fixture")
        #expect(original.string(forKey: "canopy.ship.text.fixture") == "kept")
        #expect(TutorArea.state(app).sessionsFile == nil)
        #expect(KeyTutor.of(app).store is MemoryProgress)
        #expect(KeyTutor.of(app).store.load()?.step == 2)
        #expect(Clipboard.board.name != board.name)
        for id in ["review.open", "review.compose.edit"] {
            let command = try #require(app.registry.command(id))
            #expect(app.runner.refusal?(command) != nil)
        }
        for command in app.registry.commands where command.write != nil || command.verbs.contains(.editor) {
            #expect(app.runner.refusal?(command) != nil)
        }
        ship.openURL(URL(string: "https://example.com")!)
        #expect(app.runner.note == "capture cannot open an external application")
    }
}
