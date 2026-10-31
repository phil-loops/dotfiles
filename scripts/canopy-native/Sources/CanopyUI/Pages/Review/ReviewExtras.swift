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

/// The edit in place, under the lines it replaces: their text, editable; ⌃↵ commits it to the branch.
struct InlineEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        if let e = pg.edit {
            VStack(alignment: .leading, spacing: 4) {
                ShipTextEditor(ReviewPageState.editField, code: true, text: Binding(get: { pg.edit?.text ?? "" }, set: { pg.edit?.text = $0 }))
                HStack(spacing: 10) {
                    Text(e.start == e.end ? "line \(e.start)" : "lines \(e.start)–\(e.end)")
                    Spacer(minLength: 0)
                    Text(app.keys.mode == .insert && app.insertField == ReviewPageState.editField
                         ? "\(app.registry.verbKey(.send)) commits it · esc stops writing" : "\(app.registry.keyOf("review.compose.edit")) writes · esc drops it")
                }
                .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
            }
            .padding(6)
            .background(theme.vellumRaise)
        }
    }
}
