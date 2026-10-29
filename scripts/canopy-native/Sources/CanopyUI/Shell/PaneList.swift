import CanopyCore
import SwiftUI

/// A pane drawn as a list: the focus ring when it's the focused pane, the cursor row lit, the
/// select range washed, and the cursor kept on screen as j/k/G/C-d move it. Pages render their
/// rows through this (or copy its three rules: ring, cursor, follow) so focus always shows.
public struct PaneList<Row: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pane: String
    let rows: [String]
    let row: (String, _ cursor: Bool) -> Row

    /// `rows` must be the same keys (same order) the surface's `panes()` returns for `pane`.
    public init(pane: String, rows: [String], @ViewBuilder row: @escaping (String, _ cursor: Bool) -> Row) {
        self.pane = pane; self.rows = rows; self.row = row
    }

    public var body: some View {
        let focused = app.isFocused(pane)
        let cursor = focused ? app.selected : nil
        let selection = focused ? Set(app.selection) : []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { key in
                        row(key, key == cursor)
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(key == cursor ? theme.goldWash : selection.contains(key) ? theme.emberWash : .clear)
                            .overlay(alignment: .leading) { if key == cursor { theme.goldLeaf.frame(width: 2) } }
                            .labelTarget(pane: pane, key: key)
                            .id(key)
                    }
                }
                .padding(4)
            }
            .onChange(of: cursor) { _, k in if let k { proxy.scrollTo(k) } }
        }
        .labelPane(pane)
        .overlay { Rectangle().stroke(focused ? theme.goldDeep : theme.rule.opacity(0.5), lineWidth: 1) }
    }
}

/// A text field that is focused exactly while insert mode is typing into it (`app.beginInsert(id)`),
/// and drops focus when esc leaves insert. Pages use this, never a bare focused TextField.
public struct ModalTextField: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    let id: String
    let prompt: String
    @Binding var text: String

    public init(_ id: String, prompt: String = "", text: Binding<String>) {
        self.id = id; self.prompt = prompt; self._text = text
    }

    public var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .onChange(of: app.insertField == id, initial: true) { _, on in focused = on }
    }
}
