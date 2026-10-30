import CanopyCore
import SwiftUI

/// `?` (KeySheet.tsx): what you can do right now — the keys that act on the thing under the cursor,
/// as the commands they'd run here, grouped by what they act on; then what works anywhere; then
/// this page's keys that do nothing at the moment. Generated from the registry, so it can't drift
/// from what the keys do. j/k (C-d/C-u) scroll it; `?` or esc closes it.
@MainActor
enum KeySheet {
    struct Group: Equatable {
        var label: String
        var lines: [SheetLine]
    }

    struct Hint: Equatable {
        var title: String
        var keys: String
    }

    struct Model: Equatable {
        var here: String
        var problems: [String]
        var now: [Group]
        /// commands whose keys a component handles itself (shown, never bound)
        var hints: [Hint]
        var everywhere: [SheetLine]
        var notNow: [SheetLine]
        var customized: Set<String>
    }

    /// What a scope's commands act on right now, in words.
    static func labelOf(_ scope: Scope, _ app: AppModel) -> String {
        let t = app.target(for: scope)
        let s = app.store
        switch scope {
        case .branch: return t.flatMap { s.view(Branch.self, $0)?.name } ?? "this branch"
        case .project: return "the forest \(t.flatMap { s.view(Project.self, $0)?.name } ?? "")".trimmingCharacters(in: .whitespaces)
        case .forest: return "\(app.router.route.projectID.flatMap { s.view(Project.self, $0)?.name } ?? "this forest")'s page"
        case .row: return RowKey.id(app.selected, "b") != nil ? labelOf(.branch, app) : labelOf(.project, app)
        case .item: return t.flatMap { s.view(TodoItem.self, $0)?.title } ?? "this item"
        case .server: return t.map { "the server \($0)" } ?? "this server"
        case .article: return app.state { WikiState() }.page(t)?.title ?? "this page"
        case .concept: return t.map { $0.replacingOccurrences(of: "-", with: " ") } ?? "this concept"
        case .lesson, .session: return "this session"
        case .line: return "this line"
        case .thread: return "this conversation"
        case .gap: return "the hidden lines"
        case .pending: return "your draft"
        default: return "the \(app.router.surface.title) page"
        }
    }

    static func model(_ app: AppModel) -> Model {
        let liveScopes = app.liveScopes()
        let live = liveScopes.map(\.rawValue)
        let cmds = app.registry.commands.filter { !$0.keys.isEmpty }.map {
            SheetCmd(id: $0.id, title: $0.title, scope: $0.scope.rawValue, keys: $0.keys, available: $0.available?(app.target(for: $0.scope)) ?? true)
        }
        let sheet = sheetNow(surface: app.router.surface.id, live: live, cmds: cmds,
                             surfaceScopes: app.registry.surfaceScopes.mapValues { $0.map(\.rawValue) })
        var groups: [Group] = []
        for l in sheet.now {
            let label = labelOf(Scope(rawValue: l.cmd.scope), app)
            if let i = groups.firstIndex(where: { $0.label == label }) { groups[i].lines.append(l) } else { groups.append(Group(label: label, lines: [l])) }
        }
        let hints = app.registry.commands.filter { !$0.hint.isEmpty && liveScopes.contains($0.scope) }.map {
            Hint(title: $0.title, keys: $0.hint.joined(separator: " · "))
        }
        return Model(here: labelOf(liveScopes.first ?? .global, app), problems: app.registry.keyProblems, now: groups, hints: hints,
                     everywhere: sheet.everywhere, notNow: sheet.notNow, customized: Set(app.registry.commands.filter { $0.verbs.contains(where: app.registry.customized.contains) }.map(\.id)))
    }
}

/// One drawn line of the sheet, top to bottom: the sheet's keys scroll by these.
enum SheetEntry: Equatable {
    case heading(String, gold: Bool)
    case line(SheetLine, dim: Bool)
    case hint(KeySheet.Hint)
    case empty(String)
}

extension KeySheet.Model {
    var entries: [SheetEntry] {
        var out: [SheetEntry] = []
        if now.isEmpty && hints.isEmpty { out.append(.empty("nothing under the cursor")) }
        for g in now {
            out.append(.heading(g.label, gold: true))
            out += g.lines.map { .line($0, dim: false) }
        }
        out += hints.map { .hint($0) }
        out.append(.heading("Anywhere", gold: false))
        out += everywhere.map { .line($0, dim: false) }
        if !notNow.isEmpty {
            out.append(.heading("not here", gold: false))
            out += notNow.map { .line($0, dim: true) }
        }
        return out
    }
}

/// The sheet's scroll position (the entry at the top), moved by its own keys.
@MainActor
@Observable
final class SheetState {
    var top = 0

    func move(_ by: Int, _ app: AppModel) {
        top = max(0, min(KeySheet.model(app).entries.count - 1, top + by))
    }
}

struct KeySheetView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if app.sheetOpen {
            let m = KeySheet.model(app)
            let entries = m.entries
            let st = app.state { SheetState() }
            ZStack {
                theme.vellumNight.opacity(0.7).onTapGesture { app.sheetOpen = false }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Right now").foregroundStyle(theme.ink)
                                Text("· \(m.here)").foregroundStyle(theme.inkFaint)
                            }
                            .font(Theme.display(20)).padding(.bottom, 12)
                            if !m.problems.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(m.problems, id: \.self) { Text($0) }
                                }
                                .font(Theme.mono(12)).foregroundStyle(theme.ink)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { theme.goldLeaf.frame(width: 2) }
                                .padding(.bottom, 12)
                            }
                            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                                entry(e, customized: m.customized).id(i)
                            }
                            HStack(spacing: 0) {
                                Text("yours: ").foregroundStyle(theme.inkFaint)
                                Text("canopy/keys.toml").foregroundStyle(theme.inkDim)
                                Text(" (").foregroundStyle(theme.inkFaint)
                                Text("underlined").underline(pattern: .dot).foregroundStyle(theme.inkFaint)
                                Text(") · j/k scroll · ? or esc closes").foregroundStyle(theme.inkFaint)
                            }
                            .font(Theme.mono(11)).padding(.top, 16)
                        }
                        .padding(.horizontal, 24).padding(.vertical, 20)
                    }
                    .onChange(of: st.top) { _, t in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(t, anchor: .top) } }
                }
                .frame(width: 640)
                .frame(maxHeight: 640)
                .background(theme.vellumRaise)
                .overlay { Rectangle().stroke(theme.rule, lineWidth: 1) }
            }
            .font(Theme.mono(12.5))
            .onAppear { st.top = 0 }
        }
    }

    @ViewBuilder private func entry(_ e: SheetEntry, customized: Set<String>) -> some View {
        switch e {
        case .empty(let s):
            Text(s).foregroundStyle(theme.inkFaint).padding(.bottom, 12)
        case .heading(let s, let gold):
            Text(s.uppercased()).font(Theme.mono(11)).tracking(1.3).foregroundStyle(gold ? theme.goldLeaf : theme.inkFaint)
                .padding(.top, gold ? 4 : 12).padding(.bottom, 2)
        case .hint(let h):
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(h.title).foregroundStyle(theme.inkDim)
                Spacer(minLength: 8)
                Text(h.keys).foregroundStyle(theme.goldLeaf)
            }
            .padding(.vertical, 1)
        case .line(let l, let dim):
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(l.cmd.title).foregroundStyle(dim ? theme.inkFaint : theme.inkDim)
                Spacer(minLength: 8)
                Text(l.key.components(separatedBy: " · ").map(glyph).joined(separator: " · "))
                    .foregroundStyle(dim ? theme.inkFaint : theme.goldLeaf)
                    .underline(customized.contains(l.cmd.id), pattern: .dot)
            }
            .padding(.vertical, 1)
        }
    }
}
