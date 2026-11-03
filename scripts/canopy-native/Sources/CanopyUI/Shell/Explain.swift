import CanopyCore
import SwiftUI

/// What each thing on screen is, for the `?` sheet's "on screen" section. A view opts in with
/// `.explains(id, text)` (or draws a `Term`), so a note is written beside the view that draws the
/// thing and can't drift from it; the sheet lists only the ones on screen.
@MainActor @Observable
public final class ExplainState {
    public struct Note: Equatable {
        public var id: String
        /// the word on screen it explains (a Term's), nil for a free-text note
        public var word: String?
        public var text: String
        public var rect: CGRect
    }

    @ObservationIgnored private var notes: [String: Note] = [:]
    @ObservationIgnored private var order: [String] = []

    public static func of(_ app: AppModel) -> ExplainState { app.state { ExplainState() } }

    func note(_ n: Note) {
        if notes.updateValue(n, forKey: n.id) == nil { order.append(n.id) }
    }

    func drop(_ id: String) {
        if notes.removeValue(forKey: id) != nil { order.removeAll { $0 == id } }
    }

    /// Every note on screen, each once (the topmost of a repeated one), top to bottom.
    public var shown: [Note] {
        var seen = Set<String>()
        return order.compactMap { notes[$0] }
            .filter { !$0.rect.isEmpty }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .filter { seen.insert("\($0.word ?? "")|\($0.text)").inserted }
    }
}

/// A word canopy shows and what it means, as one value, so the word can't appear without its
/// meaning and a new state can't be added without one (each Term is an exhaustive switch).
public protocol Term {
    var word: String { get }
    /// one plain line for the `?` sheet; nil when the word says it all
    var meaning: String? { get }
}

public extension View {
    /// What this thing on screen is, for the `?` sheet — one plain line.
    func explains(_ id: String, _ text: String) -> some View { modifier(ExplainModifier(id: id, word: nil, text: text)) }

    /// This view shows `term`: its meaning is the note.
    func explains(_ id: String, _ term: any Term) -> some View { modifier(ExplainModifier(id: id, word: term.word, text: term.meaning)) }
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
    let word: String?
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
                    .onAppear { e.note(.init(id: id, word: word, text: text, rect: rect)) }
                    .onChange(of: rect) { _, r in e.note(.init(id: id, word: word, text: text, rect: r)) }
                    .onChange(of: text) { _, t in e.note(.init(id: id, word: word, text: t, rect: rect)) }
                    .onDisappear { e.drop(id) }
            }
        }
    }
}
