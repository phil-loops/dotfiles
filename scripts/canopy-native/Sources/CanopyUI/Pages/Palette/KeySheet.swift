import CanopyCore
import SwiftUI

/// `?` (KeySheet.tsx): what you can do right now — the keys that act on the thing under the cursor,
/// as the commands they'd run here; then the page's own by what they act on (show, this branch,
/// other branches); then what works anywhere; then every motion on one line; then this page's keys
/// that do nothing at the moment. The order is `sheetSections`'; this only draws it. Generated from
/// the registry, so it can't drift from what the keys do. j/k (C-d/C-u) scroll it; `?` or esc closes it.
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
        /// keys.toml lines read past (v2's command ids)
        var warnings: [String]
        var now: [Group]
        /// commands whose keys a component handles itself (shown, never bound)
        var hints: [Hint]
        var everywhere: [SheetLine]
        /// every motion's keys, shown as one line
        var moves: [SheetLine]
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
        case .history: return "this commit"
        case .line: return "this line"
        case .thread: return "this conversation"
        case .gap: return "the hidden lines"
        case .pending: return "your draft"
        default: return "the \(app.router.surface.title) page"
        }
    }

    /// Keys that work anywhere shown, the most used first; `:` finds the rest.
    static let anywhereShown = 8

    /// A page-wide group's heading.
    static func groupLabel(_ g: KeyGroup, _ app: AppModel) -> String {
        switch g {
        case .show: return "show"
        case .branch: return labelOf(.branch, app) == "this branch" ? "this branch" : "this branch · \(labelOf(.branch, app))"
        case .others: return "other branches"
        case .anywhere: return "anywhere"
        case .move: return "move"
        }
    }

    static func model(_ app: AppModel) -> Model {
        let liveScopes = app.liveScopes()
        let live = liveScopes.map(\.rawValue)
        let cmds = app.registry.commands.filter { !$0.keys.isEmpty }.map {
            SheetCmd(id: $0.id, title: $0.title, scope: $0.scope.rawValue, keys: $0.keys, available: $0.available?(app.target(for: $0.scope)) ?? true,
                     verb: $0.verbs.first?.name, group: $0.sheetGroup?.rawValue, pair: $0.pair, uses: app.keyUses.score($0.id), label: $0.label)
        }
        let surface = app.router.surface.id
        let sheet = sheetNow(surface: surface, live: live, cmds: cmds,
                             surfaceScopes: app.registry.surfaceScopes.mapValues { $0.map(\.rawValue) })
        var groups: [Group] = []
        var everywhere: [SheetLine] = []
        var moves: [SheetLine] = []
        for sec in sheetSections(sheet, surface: surface, live: live) {
            switch sec.kind {
            case .group(.anywhere): everywhere = sec.lines
            case .group(.move): moves = sec.lines
            case .group(let g): groups.append(Group(label: groupLabel(g, app), lines: sec.lines))
            case .scope(let sc): groups.append(Group(label: labelOf(Scope(rawValue: sc), app), lines: sec.lines))
            }
        }
        let hints = app.registry.commands.filter { !$0.hint.isEmpty && liveScopes.contains($0.scope) }.map {
            Hint(title: $0.title, keys: $0.hint.joined(separator: " · "))
        }
        return Model(here: labelOf(liveScopes.first ?? .global, app), problems: app.registry.keyProblems, warnings: app.registry.keyWarnings, now: groups, hints: hints,
                     everywhere: everywhere, moves: moves, notNow: sheet.notNow, customized: Set(app.registry.commands.filter { $0.verbs.contains(where: app.registry.customized.contains) }.map(\.id)))
    }
}

/// One drawn line of the sheet, top to bottom: the sheet's keys scroll by these.
enum SheetEntry: Equatable {
    case heading(String, gold: Bool)
    case line(SheetLine, dim: Bool)
    case hint(KeySheet.Hint)
    /// every motion's keys on one line
    case moves(String)
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
        out += everywhere.prefix(KeySheet.anywhereShown).map { .line($0, dim: false) }
        if everywhere.count > KeySheet.anywhereShown {
            out.append(.empty("\(everywhere.count - KeySheet.anywhereShown) more work anywhere — : finds any of them by name"))
        }
        if !moves.isEmpty {
            out.append(.heading("Move", gold: false))
            out.append(.moves(moves.map { $0.key.components(separatedBy: " · ").first ?? $0.key }.map { k in k.split(separator: " ").map { glyph(String($0)) }.joined(separator: " ") }.joined(separator: " · ")))
        }
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
                        LazyVStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Right now").foregroundStyle(theme.ink)
                                Text("· \(m.here)").foregroundStyle(theme.inkFaint)
                            }
                            .font(Theme.display(20)).padding(.bottom, 12)
                            if !m.problems.isEmpty || !m.warnings.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(m.problems, id: \.self) { Text($0) }
                                    ForEach(m.warnings, id: \.self) { Text($0).foregroundStyle(theme.inkFaint) }
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
                                Text("canopy/keys-native.toml").foregroundStyle(theme.inkDim)
                                Text(" (").foregroundStyle(theme.inkFaint)
                                Text("underlined").underline(pattern: .dot).foregroundStyle(theme.inkFaint)
                                Text(") · keys belong to verbs · , is this page's own · j/k scroll · ? or esc closes").foregroundStyle(theme.inkFaint)
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
        case .moves(let keys):
            Text(keys).foregroundStyle(theme.goldLeaf).fixedSize(horizontal: false, vertical: true).padding(.vertical, 1)
        case .hint(let h):
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(h.title).foregroundStyle(theme.inkDim)
                Spacer(minLength: 8)
                Text(h.keys).foregroundStyle(theme.goldLeaf)
            }
            .padding(.vertical, 1)
        case .line(let l, let dim):
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(l.cmd.verb ?? "page").foregroundStyle(dim ? theme.inkFaint : l.cmd.verb == nil ? theme.inkFaint : theme.ink)
                        .frame(minWidth: 96, alignment: .leading)
                    Text(l.cmd.title).foregroundStyle(dim ? theme.inkFaint : theme.inkDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(l.key.components(separatedBy: " · ").map(glyph).joined(separator: " · "))
                    .foregroundStyle(dim ? theme.inkFaint : theme.goldLeaf)
                    .underline(customized.contains(l.cmd.id), pattern: .dot)
            }
            .padding(.vertical, 1)
        }
    }
}
