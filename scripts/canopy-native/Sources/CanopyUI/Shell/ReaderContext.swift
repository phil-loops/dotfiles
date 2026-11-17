import CanopyCore

@MainActor
struct ReaderContext {
    private struct Cursor: Equatable {
        let row: Int
        let source: Int
        let word: Int?
        let pane: Int

        @MainActor init(_ app: AppModel) {
            let page = ReviewPageState.of(app)
            row = page.cursorMoved
            source = page.sourceGeneration
            word = page.code?.cursorGeneration
            pane = app.cursorGeneration(in: app.pane?.id ?? "main")
        }
    }

    let visit: Int
    let place: Place
    let focus: Int
    let picker: Int
    private let cursor: Cursor

    init(_ app: AppModel) {
        visit = app.navigationGeneration
        place = app.here()
        focus = app.focusGeneration
        picker = app.nav.pickerGeneration
        cursor = Cursor(app)
    }

    func isCurrent(_ app: AppModel) -> Bool {
        visit == app.navigationGeneration && focus == app.focusGeneration && picker == app.nav.pickerGeneration && cursor == Cursor(app) && place.sameSpot(app.here())
    }
}
