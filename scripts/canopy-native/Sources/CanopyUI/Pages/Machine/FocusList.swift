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

    @Environment(\.cursorMarks) private var given

    var body: some View {
        let marks = given?.pane == pane ? given! : app.cursorMarks(pane)
        let state = marks.state(of: key)
        // only the focused pane's row is live: a row merely left there shows its mark, not its levers
        content(state == .here)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cursorChrome(state, inRange: state != .here && marks.range.contains(key))
            .contentShape(Rectangle())
            .onTapGesture { app.runner.dispatch("pane.focus", via: .click, target: pane); app.runner.dispatch("cursor.set", via: .click, target: key) }
            .id(key)
    }
}

/// Where a pane's cursor and select range sit, worked out once for a whole list of `CursorRow`s
/// (`.cursorMarks(pane)` on the list) instead of once per row.
struct CursorMarks {
    var pane: String
    var on: String?
    var range: Set<String>
    /// whether the keyboard is in this pane: false means `on` is where its cursor was left
    var focused = true

    func state(of key: String) -> CursorState { on == key ? (focused ? .here : .left) : .none }
}

/// A row's cursor: where the keyboard is, where a pane's cursor was left, or neither.
enum CursorState { case here, left, none }

extension AppModel {
    func cursorMarks(_ id: String) -> CursorMarks {
        guard let p = pane, p.id == id else {
            // another pane holds the keyboard: this one shows where its cursor was left (one dictionary read)
            return CursorMarks(pane: id, on: cursor(in: id), range: [], focused: false)
        }
        return CursorMarks(pane: id, on: selected(in: p), range: Set(selection(in: p)))
    }
}

/// The one cursor look (`CursorLook`) on a row.
struct CursorChrome: ViewModifier {
    @Environment(\.theme) private var theme
    let state: CursorState
    let inRange: Bool
    func body(content: Content) -> some View {
        content
            .background(state == .here ? theme.goldLeaf.opacity(CursorLook.hereWash)
                        : state == .left ? theme.goldLeaf.opacity(CursorLook.leftWash) : inRange ? theme.emberWash : .clear)
            .overlay(alignment: .leading) { (state == .here ? theme.goldLeaf : state == .left ? theme.goldDeep : .clear).frame(width: CursorLook.bar) }
    }
}

extension View {
    func cursorChrome(_ state: CursorState, inRange: Bool = false) -> some View { modifier(CursorChrome(state: state, inRange: inRange)) }
}

private struct CursorMarksKey: EnvironmentKey { static let defaultValue: CursorMarks? = nil }

extension EnvironmentValues {
    var cursorMarks: CursorMarks? {
        get { self[CursorMarksKey.self] }
        set { self[CursorMarksKey.self] = newValue }
    }
}

private struct ProvideCursorMarks: ViewModifier {
    @Environment(AppModel.self) private var app
    let pane: String
    func body(content: Content) -> some View { content.environment(\.cursorMarks, app.cursorMarks(pane)) }
}

extension View {
    func cursorMarks(_ pane: String) -> some View { modifier(ProvideCursorMarks(pane: pane)) }
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
            .font(Theme.text(11))
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
        Text(text.uppercased()).font(Theme.text(11)).tracking(1.5).foregroundStyle(gold ? theme.goldLeaf : theme.inkFaint)
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
