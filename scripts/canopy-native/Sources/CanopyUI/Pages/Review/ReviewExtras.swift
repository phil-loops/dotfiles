import CanopyCore
import SwiftUI

/// What hangs under a diff row — Ship's ThreadView / PendingView / ComposerView (area C), lit
/// when the diff cursor is on them.
@MainActor
enum ReviewExtrasView {
    static func thread(_ app: AppModel, _ id: String, aside: Bool) -> AnyView {
        AnyView(Lit(key: "t|\(id)") { ThreadView(id: id, selected: $0, aside: aside) })
    }

    static func row(_ app: AppModel, threads: [String], pending: [DraftItem], composing: Bool) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            ForEach(threads, id: \.self) { id in Lit(key: "t|\(id)") { ThreadView(id: id, selected: $0) } }
            ForEach(pending, id: \.key) { it in Lit(key: "p|\(it.key)") { PendingView(item: it, selected: $0) } }
            if composing { ComposerView() }
        })
    }
}

/// A hosted view that knows whether the diff cursor is on its stop.
private struct Lit<V: View>: View {
    @Environment(AppModel.self) private var app
    let key: String
    @ViewBuilder let content: (Bool) -> V
    var body: some View {
        let pg = ReviewPageState.of(app)
        content(app.pane?.id == reviewDiffPane && pg.here?.key == key)
    }
}
