import CanopyCore
import SwiftUI

/// PaneList's three rules (focus ring, cursor lit, cursor kept on screen) for pages whose panes
/// aren't one flat list — sections with headers, a row that unfolds notes, several panes stacked in
/// one scroll. Machine, dashboard and tracker draw their rows through these.
struct FollowScroll<Content: View>: View {
    @Environment(AppModel.self) private var app
    /// the pane whose cursor this scroll follows (nil: every pane on the page)
    let panes: [String]
    @ViewBuilder let content: () -> Content

    init(panes: [String], @ViewBuilder content: @escaping () -> Content) {
        self.panes = panes; self.content = content
    }

    var body: some View {
        let followed = app.pane.map { panes.contains($0.id) } == true ? app.selected : nil
        ScrollViewReader { proxy in
            ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }
                .onChange(of: followed) { _, k in if let k { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(k) } } }
        }
    }
}

/// One cursor row: the gold rule on its left and the wash when it's the focused pane's cursor,
/// the ember wash when it's inside a select range. `.id(key)` so FollowScroll can find it.
struct CursorRow<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pane: String
    let key: String
    @ViewBuilder let content: (_ on: Bool) -> Content

    init(pane: String, key: String, @ViewBuilder content: @escaping (_ on: Bool) -> Content) {
        self.pane = pane; self.key = key; self.content = content
    }

    var body: some View {
        let focused = app.isFocused(pane)
        let on = focused && app.selected == key
        let inRange = focused && !on && app.selection.contains(key)
        content(on)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? theme.goldWash : inRange ? theme.emberWash : .clear)
            .overlay(alignment: .leading) { (on ? theme.goldLeaf : .clear).frame(width: 2) }
            .contentShape(Rectangle())
            .onTapGesture { app.runner.dispatch("pane.focus", via: .click, target: pane); app.runner.dispatch("cursor.set", via: .click, target: key) }
            .id(key)
    }
}

/// The ring around a focused pane's region.
struct PaneRing: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let pane: String
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) { (app.isFocused(pane) ? theme.goldDeep : .clear).frame(width: 1) }
    }
}

extension View {
    func paneRing(_ pane: String) -> some View { modifier(PaneRing(pane: pane)) }
}

/// A command's key and its word, as a button: the click dispatches exactly what the key does.
struct Lever: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let id: String
    var target: String?
    let word: String
    var danger = false

    var body: some View {
        Button { app.runner.dispatch(id, via: .click, target: target) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(app.registry.keyOf(id)).foregroundStyle(danger ? theme.del : theme.goldDeep)
                Text(word)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(danger ? theme.del : theme.inkDim)
            .background(RoundedRectangle(cornerRadius: 4).fill(danger ? theme.delBg : theme.vellumRaise))
        }
        .buttonStyle(.plain)
    }
}

/// The small uppercase section heading v2 uses across these pages.
struct SectionHead: View {
    @Environment(\.theme) private var theme
    let text: String
    var gold = false
    var body: some View {
        Text(text.uppercased()).font(Theme.mono(11)).tracking(1.5).foregroundStyle(gold ? theme.goldLeaf : theme.inkFaint)
    }
}

/// A status dot (v2's 7px circles); `breathe` pulses it.
struct Dot: View {
    let color: Color
    var breathe = false
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(breathe && dim ? 0.35 : 1)
            .onAppear { if breathe { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { dim = true } } }
    }
}
