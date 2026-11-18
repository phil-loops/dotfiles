import CanopyCore
import Foundation

@MainActor
struct HelixReturn {
    enum Destination {
        case diff
        case file(ReviewWindow, Loc)
    }

    private struct Intent: Equatable {
        let visit: Int
        let focus: Int
        let mode: Int
        let picker: Int
        let cursor: Int
        let diffCursor: Int
        let word: Int
        let codeWord: Int?
        let tab: Int

        @MainActor init(_ app: AppModel) {
            let page = ReviewPageState.of(app)
            visit = app.navigationGeneration
            focus = app.focusGeneration
            mode = app.modeGeneration
            picker = app.nav.pickerGeneration
            cursor = app.cursorGeneration(in: app.pane?.id ?? "main")
            diffCursor = page.cursorMoved
            word = page.sourceGeneration
            codeWord = page.code?.cursorGeneration
            tab = page.tabGeneration
        }
    }

    let session: UUID
    let source: BranchSource
    let path: String
    let line: Int
    let destination: Destination
    var commit: String?
    private let intent: Intent

    init(_ app: AppModel, open: HelixOpen, path: String, line: Int, destination: Destination) {
        session = open.session
        source = open.source
        self.path = path
        self.line = line
        self.destination = destination
        intent = Intent(app)
    }

    func current(_ app: AppModel) -> Bool {
        let page = ReviewPageState.of(app)
        return page.helixSession == session && page.id == source.id && app.store.epoch == source.epoch && intent == Intent(app)
    }
}

extension ReviewPageState {
    @discardableResult func takeHelixReturn(_ app: AppModel) -> Bool {
        guard let pending = pendingHelixReturn else { return false }
        guard pending.current(app) else { pendingHelixReturn = nil; return false }
        guard let commit = pending.commit else { return false }
        switch pending.destination {
        case .diff:
            guard tip == pending.source.tip || tip == commit else { pendingHelixReturn = nil; return false }
            guard diffCurrent, tip == commit else { return false }
            Log.line("helix \(pending.session): updated diff ready · \(pending.source.id)")
            pendingHelixReturn = nil
            guard let key = stopNear(path: pending.path, line: pending.line) else { return false }
            setCursor(key)
        case .file(let window, let previous):
            pendingHelixReturn = nil
            guard windows.contains(where: { $0 === window }), window.doc == previous else { return false }
            show(Loc(repo: pending.source.repo, sha: commit, path: pending.path, line: pending.line), in: window)
        }
        return true
    }
}
