import CanopyCore
import Observation
import SwiftUI

/// One line of saved text written in place: a branch's description, a forest's line or name. The
/// field's id names the text ("words.desc|<branch>"); what's typed is a draft kept under that id
/// until `save` sends it. `esc` leaves the field and keeps the draft, so going back in picks up where
/// you were; the row shows it as unsaved meanwhile.
@MainActor
@Observable
public final class LineEdit {
    public private(set) var drafts: [String: String] = [:]

    public static func of(_ app: AppModel) -> LineEdit { app.state { LineEdit() } }

    /// The text the field shows: the draft while there is one, else what's saved.
    public func text(_ field: String, saved: String) -> String { drafts[field] ?? saved }

    /// A draft that would change what's saved.
    public func unsaved(_ field: String, saved: String) -> Bool {
        drafts[field].map { Self.oneLine($0) != Self.oneLine(saved) } ?? false
    }

    public func binding(_ field: String, saved: String) -> Binding<String> {
        Binding(get: { self.text(field, saved: saved) },
                set: { self.drafts[field] = $0.replacingOccurrences(of: "\n", with: " ") })
    }

    public func open(_ app: AppModel, _ field: String) { app.beginInsert(field) }

    /// Leave the field and send the draft through `command` (its target, the text as its arg) when it
    /// changes what's saved; the draft goes either way.
    public func save(_ app: AppModel, _ field: String, saved: String, command: String, target: String) {
        let draft = drafts.removeValue(forKey: field)
        if app.insertField == field { app.keys.setMode(.normal) }
        guard let draft, Self.oneLine(draft) != Self.oneLine(saved) else { return }
        app.runner.dispatch(command, via: .key, target: target, arg: draft)
    }

    /// What's under a field id's `|`: the branch or forest it writes.
    public static func target(_ field: String?, prefix: String) -> String? {
        guard let field, field.hasPrefix(prefix + "|") else { return nil }
        return String(field.dropFirst(prefix.count + 1))
    }

    /// The text as the server stores it: one line, runs of space folded (srv/outline.py).
    public static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

/// Beside text that shows a draft: it isn't saved yet.
public struct UnsavedMark: View {
    @Environment(\.theme) private var theme
    public init() {}
    public var body: some View {
        Text("◆ unsaved").font(Theme.text(11)).foregroundStyle(theme.goldLeaf).fixedSize()
    }
}
