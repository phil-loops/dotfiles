import CanopyCore
import SwiftUI

/// Getting a branch out the door, on the review page: the ship strip (sync, gates, prep, push),
/// the conversation (PR, threads, the ledger of drafts), the words (description, outline, PR text)
/// and the history. No surface of its own — its views sit inside ReviewPage (area B), and
/// `ShipSeam` is how B hands it panes, scopes and targets. See ShipSeam.swift.
enum ShipArea: PageArea {
    static let name = "ship"

    static func install(_ app: AppModel) {
        let before = Set(app.registry.order)
        defer { ShipState.of(app).commandIDs = app.registry.order.filter { !before.contains($0) } }
        _ = WordsState.of(app)
        app.registry.addScopes([.words], to: "review")
        SyncCommands.install(app)
        WordsCommands.install(app)
        ReviewCommands.install(app)
        InsertCommands.install(app)
        // esc in normal backs out of what Ship has open (B's review.back calls ShipSeam.backOut first)
        app.addCloser(isOpen: { [weak app] in app.map(ShipSeam.canBackOut) ?? false }, close: { [weak app] in if let app { ShipSeam.backOut(app) } })
    }
}

/// Keys that act on whatever insert mode is writing: ⌃↵ is "done" in every Ship field.
@MainActor
enum InsertCommands {
    static func install(_ app: AppModel) {
        weak let weakApp = app
        app.registry.register(Command(
            id: "words.submit", title: "Save what you're writing — the words, or the description", scope: .words,
            verb: .send, modes: [.normal, .insert], label: "save", quiet: true,
            local: { _, _ in
                guard let app = weakApp, let id = WordsCommands.branchOf(app, nil) else { return }
                let describing = app.insertField?.hasPrefix("words.desc|") == true
                app.keys.setMode(.normal)
                if describing { return }
                guard WordsState.of(app).pending(id) > 0 else { throw Refusal("nothing to save") }
                app.runner.dispatch("words.save", via: .key, target: id)
            }))
    }
}
