import CanopyCore
import SwiftUI

/// The picker, as Helix's (Picker.tsx): a title, a filter you type into, the matching items with
/// their source line, and how many match of how many. It is generic: any area opens it with
/// `app.nav.pick(title, items) { index in … }` (`PickItem(label:text:)`; the index is into `items`),
/// code navigation with `app.nav.pick(title, places)` (choosing goes there through the jumplist),
/// and `app.nav.reopen()` brings back the last one with its query. Its keys are the `picker` layer's
/// (shell: picker.down/up/open — ↓/↑, C-n/C-p, C-j/C-k, tab, ↵; esc closes); typing goes to its filter.
struct PickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        if let p = app.nav.picker {
            let nav = app.nav
            let shown = nav.shown
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(p.title).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    TextField("filter", text: Binding(get: { nav.filter }, set: { nav.typed($0) }))
                        .textFieldStyle(.plain)
                        .font(Theme.text(13))
                        .focused($focused)
                    Text("\(shown.count)/\(p.items.count)").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(alignment: .bottom) { theme.rule.frame(height: 1) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if shown.isEmpty { Text("nothing matches").foregroundStyle(theme.inkFaint).padding(.horizontal, 12).padding(.vertical, 4) }
                            ForEach(Array(shown.enumerated()), id: \.offset) { i, it in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(it.label).fixedSize()
                                    Text(it.text ?? "…").foregroundStyle(theme.inkFaint).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(i == nav.index ? theme.ink : theme.inkDim)
                                .padding(.horizontal, 12).padding(.vertical, 2)
                                .background(i == nav.index ? theme.goldWash : .clear)
                                .overlay(alignment: .leading) { (i == nav.index ? theme.goldLeaf : .clear).frame(width: 2) }
                                .contentShape(Rectangle())
                                .onTapGesture { app.runner.dispatch("picker.open", via: .click, target: String(i)) }
                                .id(i)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: nav.index, initial: true) { _, i in proxy.scrollTo(i) }
                }
            }
            .font(Theme.text(11.5))
            .frame(maxWidth: 860, maxHeight: 520)
            .background(theme.vellumRaise)
            .overlay { Rectangle().stroke(theme.goldDeep, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
            .padding(.horizontal, 16).padding(.top, 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { focused = true }
        }
    }
}
