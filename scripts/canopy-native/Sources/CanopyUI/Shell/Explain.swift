import CanopyCore
import SwiftUI

/// `?`'s first press: a short note beside each thing on screen that says what it is. A view opts
/// in with `.explains(id, text)`, so a note is written beside the view that draws the thing and
/// can't drift from it. The second `?` is the key sheet; esc closes either.
@MainActor @Observable
public final class ExplainState {
    public struct Note: Equatable {
        public var id: String
        public var text: String
        public var rect: CGRect
    }

    /// the notes layer is up
    public var open = false
    @ObservationIgnored private var notes: [String: Note] = [:]
    @ObservationIgnored private var order: [String] = []

    public static func of(_ app: AppModel) -> ExplainState { app.state { ExplainState() } }

    func note(_ n: Note) {
        if notes.updateValue(n, forKey: n.id) == nil { order.append(n.id) }
    }

    func drop(_ id: String) {
        if notes.removeValue(forKey: id) != nil { order.removeAll { $0 == id } }
    }

    /// What the layer draws: every note on screen, each text once (the topmost of a repeated one),
    /// top to bottom.
    public var shown: [Note] {
        var seen = Set<String>()
        return order.compactMap { notes[$0] }
            .filter { !$0.rect.isEmpty }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .filter { seen.insert($0.text).inserted }
    }

    /// `?`: the notes first when there are any, then the key sheet, then closed.
    func step(_ app: AppModel) {
        if open { open = false; app.sheetOpen = true }
        else if app.sheetOpen { app.sheetOpen = false }
        else if shown.isEmpty { app.sheetOpen = true }
        else { open = true }
    }
}

/// A word canopy shows and what it means, as one value, so the word can't appear without its
/// meaning and a new state can't be added without one (each Term is an exhaustive switch).
public protocol Term {
    var word: String { get }
    /// one plain line for `?`'s notes; nil when the word says it all
    var meaning: String? { get }
}

public extension View {
    /// What this thing on screen is, for `?`'s notes layer — one plain line.
    func explains(_ id: String, _ text: String) -> some View { modifier(ExplainModifier(id: id, text: text)) }

    /// This view shows `term`: its meaning is the note.
    func explains(_ id: String, _ term: any Term) -> some View { modifier(ExplainModifier(id: id, text: term.meaning)) }
}

/// A term's word, its meaning registered as the note.
struct TermText: View {
    let id: String
    let term: any Term
    init(_ id: String, _ term: any Term) { self.id = id; self.term = term }
    var body: some View { Text(term.word).explains(id, term) }
}

struct ExplainModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let id: String
    let text: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let text { noted(content, text) } else { content }
    }

    private func noted(_ content: Content, _ text: String) -> some View {
        content.background {
            GeometryReader { g in
                let rect = g.frame(in: .global)
                let e = ExplainState.of(app)
                Color.clear
                    .onAppear { e.note(.init(id: id, text: text, rect: rect)) }
                    .onChange(of: rect) { _, r in e.note(.init(id: id, text: text, rect: r)) }
                    .onChange(of: text) { _, t in e.note(.init(id: id, text: t, rect: rect)) }
                    .onDisappear { e.drop(id) }
            }
        }
    }
}

/// The notes layer: each note in a small raised box just under the thing it explains, and a line at
/// the foot saying what the next `?` does.
struct ExplainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let e = ExplainState.of(app)
        if e.open {
            GeometryReader { g in
                let origin = g.frame(in: .global).origin
                ZStack(alignment: .topLeading) {
                    ForEach(e.shown, id: \.id) { n in
                        Text(n.text)
                            .font(Theme.text(11))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.vellumRaise)
                            .overlay { Rectangle().stroke(theme.goldDeep, lineWidth: 1) }
                            .fixedSize()
                            .offset(x: max(0, n.rect.minX - origin.x), y: n.rect.maxY - origin.y + 2)
                    }
                    Text("? again: every key · esc closes")
                        .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .allowsHitTesting(false)
        }
    }
}
