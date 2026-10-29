import CanopyCore
import SwiftUI

// motion.ts: motion that explains where things went — rows glide to their new place, rows that appear
// unfold in, a state word that changes settles. 150–200 ms, never under reduced motion, and nothing
// animates on the first paint (SwiftUI doesn't animate a view's arrival with `animation(_:value:)`).

enum Motion {
    static let glide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.19)
    static let settle = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
}

extension View {
    /// FLIP: glide the rows when the row list `value` changes.
    func glides<V: Equatable>(_ value: V, reduced: Bool) -> some View {
        animation(reduced ? nil : Motion.glide, value: value)
    }

    /// A state word that replaces another settles in.
    func settles<V: Hashable>(_ value: V, reduced: Bool) -> some View {
        id(value)
            .transition(reduced ? .identity : .opacity.combined(with: .offset(y: 3)))
            .animation(reduced ? nil : Motion.settle, value: value)
    }
}

/// Key.tsx: a command's key as a faint label that lights for a moment when the key runs it, and
/// glows while a half-typed prefix waits for the key that would finish it. Reads keys.toml.
struct KeyHint: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let id: String

    var body: some View {
        let key = app.registry.keyOf(id)
        let fired = app.runner.fired.map { $0.ok && $0.id == id } ?? false
        let armed = !app.keys.pendingKeys.isEmpty && key.hasPrefix("\(glyph(app.keys.pendingKeys)) ")
        Text(key)
            .font(Theme.mono(11))
            .padding(.horizontal, 3)
            .foregroundStyle(fired || armed ? theme.goldLeaf : theme.inkFaint)
            .background(fired ? theme.goldWash : .clear, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// The three focus rules every list keeps (PORTING.md §0.4): the cursor row lit with the gold bar,
/// a select range washed, and the row keyed so the list can keep it on screen. A click only moves
/// the cursor there (cursor.set), like the web app.
struct RowChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let key: String
    let cursor: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cursor ? theme.goldWash : selected ? theme.emberWash : .clear)
            .overlay(alignment: .leading) { (cursor ? theme.goldLeaf : .clear).frame(width: 2) }
            .contentShape(Rectangle())
            .onTapGesture { app.runner.dispatch("cursor.set", via: .click, target: key) }
            .labelTarget(pane: "main", key: key)
            .id(key)
    }
}

extension View {
    func rowChrome(_ key: String, cursor: Bool, selected: Bool) -> some View {
        modifier(RowChrome(key: key, cursor: cursor, selected: selected))
    }
}
