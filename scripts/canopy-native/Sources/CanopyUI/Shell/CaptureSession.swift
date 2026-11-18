import AppKit
import CanopyCore
import Foundation

@MainActor
enum CaptureSession {
    static func configure(_ app: AppModel) {
        Clipboard.board = NSPasteboard(name: NSPasteboard.Name("canopy-capture-\(UUID())"))
        app.runner.refusal = { command in
            command.write != nil || command.verbs.contains(.editor) || ["review.open", "review.compose.edit"].contains(command.id)
                ? "capture is read-only · \(command.id) refused" : nil
        }
        let ship = ShipState.of(app)
        let defaults = MemoryDefaults()
        for (key, value) in ship.defaults.dictionaryRepresentation() { defaults.set(value, forKey: key) }
        ship.defaults = defaults
        ship.openURL = { [weak app] _ in app?.runner.say("capture cannot open an external application") }
        app.state { Workstation(app: app) }.openURL = { [weak app] _ in app?.runner.say("capture cannot open an external application") }
        BenchOpening.of(app).openDocument = { _ in throw Refusal("capture cannot open Show") }
        MachineRuns.of(app).openDocument = { _ in throw Refusal("capture cannot open Show") }
        TutorArea.state(app).sessionsFile = nil
        let tutor = KeyTutor.of(app)
        tutor.store = MemoryProgress(tutor.store.load())
    }
}

