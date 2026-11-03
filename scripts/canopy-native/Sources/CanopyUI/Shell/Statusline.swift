import CanopyCore
import SwiftUI

/// Helix's statusline, always on: the mode (and layer), the pending chord, the focused pane and the
/// cursor's place in it, the selection size, the quiet line, the connection. In command mode it
/// becomes the `:` line, with its fuzzy completions above it.
struct Statusline: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.keys.mode == .command && app.keys.layer == nil { Completions() }
            HStack(spacing: 10) {
                if app.keys.active != .normal {
                    Text(app.keys.active.badge)
                        .font(Theme.text(11, weight: .semibold))
                        .foregroundStyle(theme.vellumNight)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(badgeColor)
                }
                if app.keys.mode == .command && app.keys.layer == nil {
                    CommandLine()
                } else if PageSearch.of(app).typing {
                    SearchLine()
                } else {
                    if !app.keys.pendingKeys.isEmpty { Text(glyph(app.keys.pendingKeys)).foregroundStyle(theme.goldLeaf) }
                    if let l = app.labeling { Text("label \(l.typed)…").foregroundStyle(theme.goldLeaf) }
                    if let pos = app.position {
                        Text(pos).foregroundStyle(theme.inkFaint)
                        if app.keys.mode == .select { Text("\(app.selection.count) selected").foregroundStyle(theme.goldLeaf) }
                    }
                    let search = PageSearch.of(app)
                    if search.active {
                        let ms = search.matches(app)
                        let at = app.selected.flatMap { ms.firstIndex(of: $0) }.map { "\($0 + 1)/" } ?? ""
                        Text("/\(search.query)  \(at)\(ms.count)").foregroundStyle(ms.isEmpty ? theme.ember : theme.goldLeaf)
                    }
                    if let note = app.runner.note {
                        Text(note).foregroundStyle(theme.inkDim).lineLimit(1).accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer(minLength: 8)
                    ModeKeys()
                    if app.store.conn != .live {
                        Text(app.store.conn.rawValue).foregroundStyle(app.store.conn == .down ? theme.ember : theme.inkFaint)
                    }
                }
            }
            .font(Theme.text(11))
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var badgeColor: Color {
        switch app.keys.active {
        case .insert: theme.patina
        case .select: theme.ember
        case .command: theme.goldLeaf
        case .normal: theme.inkDim
        default: theme.goldDeep
        }
    }
}

extension AppModel {
    /// Where the cursor is: the page's own words for it, else the focused pane and the row's place in it.
    var position: String? {
        guard let p = pane else { return nil }
        let at = selected.flatMap { p.rows.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return provider?.position(self) ?? "\(p.title.isEmpty ? p.id : p.title) \(at)/\(p.rows.count)"
    }
}

/// Outside normal mode, the keys that act in this mode and esc: every mode says its own way out.
private struct ModeKeys: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let keys = app.keys.modeKeys()
        if !keys.isEmpty { Text(keys.prefix(5).joined(separator: " · ")).foregroundStyle(theme.inkFaint).lineLimit(1) }
    }
}

/// The `:` field. Its keys are the engine's first (ret runs, tab/C-n/C-p choose); typing goes here.
/// `/`'s line: what you type moves the page as you type it.
private struct SearchLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let search = PageSearch.of(app)
        let n = search.matches(app).count
        HStack(spacing: 2) {
            Text("/").foregroundStyle(theme.goldLeaf)
            TextField("", text: Binding(get: { search.query }, set: { search.typed(app, $0) }))
                .textFieldStyle(.plain)
                .focused($focused)
            if !search.query.isEmpty { Text("\(n)").foregroundStyle(n == 0 ? theme.ember : theme.inkFaint) }
            Spacer(minLength: 8)
            ModeKeys()
        }
        .onAppear { focused = true }
    }
}

private struct CommandLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 2) {
            Text(":").foregroundStyle(theme.goldLeaf)
            TextField("", text: $app.cmdline)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: app.cmdline) { app.cmdIndex = 0 }
        }
        .onAppear { focused = true }
    }
}

private struct Completions: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        // a window of 12 that keeps the highlighted completion in view as tab/C-n walk past the fold
        let all = app.completions
        let lo = max(0, min(app.cmdIndex - 11, all.count - 12))
        let cs = Array(all.enumerated().dropFirst(lo).prefix(12))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(cs, id: \.element.id) { i, c in
                HStack(spacing: 12) {
                    Text(c.id).foregroundStyle(i == app.cmdIndex ? theme.goldLeaf : theme.ink)
                    Text(c.title).foregroundStyle(theme.inkDim).lineLimit(1)
                    Spacer()
                    Text(c.keys.first.map { k in glyph(k) + (c.verbs.first.map { " · \($0.name)" } ?? " · page") } ?? "")
                        .foregroundStyle(i == app.cmdIndex ? theme.goldLeaf : theme.inkFaint)
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(i == app.cmdIndex ? theme.goldWash : .clear)
                .overlay(alignment: .leading) { (i == app.cmdIndex ? theme.goldLeaf : .clear).frame(width: 2) }
            }
            if all.count > 12 { Text("\(app.cmdIndex + 1)/\(all.count)").foregroundStyle(theme.inkFaint).padding(.horizontal, 10) }
            if cs.isEmpty { Text("no command matches").foregroundStyle(theme.inkFaint).padding(.horizontal, 10) }
        }
        .font(Theme.text(11.5))
        .padding(.vertical, 4)
        .background(theme.vellumRaise)
        .overlay(alignment: .top) { theme.rule.frame(height: 1) }
    }
}
