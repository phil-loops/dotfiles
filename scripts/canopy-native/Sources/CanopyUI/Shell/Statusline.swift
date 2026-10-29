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
                Text(app.keys.active.badge)
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(theme.vellumNight)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(badgeColor)
                if app.keys.mode == .command && app.keys.layer == nil {
                    CommandLine()
                } else {
                    if !app.keys.pendingKeys.isEmpty { Text(glyph(app.keys.pendingKeys)).foregroundStyle(theme.goldLeaf) }
                    if let l = app.labeling { Text("label \(l.typed)…").foregroundStyle(theme.goldLeaf) }
                    if let p = app.pane {
                        let n = p.rows.count
                        let at = app.selected.flatMap { p.rows.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                        Text("\(p.title.isEmpty ? p.id : p.title) \(at)/\(n)").foregroundStyle(theme.inkFaint)
                        if app.keys.mode == .select { Text("\(app.selection.count) selected").foregroundStyle(theme.goldLeaf) }
                    }
                    if let note = app.runner.note {
                        Text(note).foregroundStyle(theme.inkDim).lineLimit(1).accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer(minLength: 8)
                    Text(app.router.route.path).foregroundStyle(theme.inkFaint).lineLimit(1).truncationMode(.middle)
                    Text(app.store.conn.rawValue).foregroundStyle(app.store.conn == .live ? theme.patina : app.store.conn == .down ? theme.ember : theme.inkFaint)
                }
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(theme.vellumRaise)
            .overlay(alignment: .top) { theme.rule.frame(height: 1) }
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

/// The `:` field. Its keys are the engine's first (ret runs, tab/C-n/C-p choose); typing goes here.
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
                    Text(c.keys.map(glyph).joined(separator: " · ")).foregroundStyle(i == app.cmdIndex ? theme.goldLeaf : theme.inkFaint)
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(i == app.cmdIndex ? theme.goldWash : .clear)
                .overlay(alignment: .leading) { (i == app.cmdIndex ? theme.goldLeaf : .clear).frame(width: 2) }
            }
            if all.count > 12 { Text("\(app.cmdIndex + 1)/\(all.count)").foregroundStyle(theme.inkFaint).padding(.horizontal, 10) }
            if cs.isEmpty { Text("no command matches").foregroundStyle(theme.inkFaint).padding(.horizontal, 10) }
        }
        .font(Theme.mono(11.5))
        .padding(.vertical, 4)
        .background(theme.vellumRaise)
        .overlay(alignment: .top) { theme.rule.frame(height: 1) }
    }
}
