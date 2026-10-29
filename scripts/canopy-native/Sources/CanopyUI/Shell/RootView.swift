import CanopyCore
import SwiftUI

/// The window (App.tsx): the crumbs header with the connection dot, the routed page, the quiet
/// line, and the overlays (which-key, the space menu, the key sheet, the picker).
public struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = Theme.forScheme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            Header()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .bottomTrailing) { WhichKeyView().padding(16) }
                .overlay { PickerView() }
                .overlay { KeySheetView() }
                .overlay { CommandMenuView() }
            Statusline()
        }
        .overlay { LabelsView() }
        .background(theme.vellumNight)
        .foregroundStyle(theme.ink)
        .font(Theme.mono())
        .environment(\.theme, theme)
    }

    @ViewBuilder private var page: some View {
        if let p = app.provider {
            p.view(app, route: app.router.route)
        } else {
            Text("no area registered surface \(app.router.surface.id)").padding(16)
        }
    }
}

/// Where you are, as the ladder `h` climbs: canopy › forest › branch.
struct Header: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { app.runner.dispatch("nav.forests", via: .click) } label: {
                Text("canopy").font(Theme.display(17)).foregroundStyle(theme.goldLeaf)
            }
            .buttonStyle(.plain)
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                Text("›").foregroundStyle(theme.inkFaint.opacity(0.6))
                if let cmd = c.command {
                    Button(c.title) { app.runner.dispatch(cmd, via: .click) }.buttonStyle(.plain).foregroundStyle(theme.inkFaint)
                } else {
                    Text(c.title).foregroundStyle(i == crumbs.count - 1 ? theme.inkDim : theme.inkFaint).lineLimit(1)
                }
            }
            Spacer()
            if app.store.conn != .live {
                Circle()
                    .fill(app.store.conn == .down ? theme.ember : theme.inkFaint)
                    .frame(width: 7, height: 7)
                    .help(app.store.conn == .down ? "reconnecting to the server" : "connecting")
            }
        }
        .font(Theme.mono(12))
        .foregroundStyle(theme.inkFaint)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var crumbs: [Crumb] {
        let r = app.router.route
        if r.surfaceID == "forests" { return [] }
        return app.provider?.crumbs(app, route: r) ?? [Crumb(r.surface.title.lowercased())]
    }
}

/// A page not ported yet, described as data: what it is, where its web source is, a few live facts.
/// Its two panes — facts, then sources — are real focusable lists, so j/k, gg/G, C-w h/l, v and
/// the statusline work on every page from day one. Replace it as the page is ported.
public struct Placeholder {
    public var title: String
    public var area: String
    public var sources: [String]
    public var notes: [String]

    public init(title: String, area: String, sources: [String], notes: [String] = []) {
        self.title = title; self.area = area; self.sources = sources; self.notes = notes
    }

    var noteRows: [String] { notes.indices.map { "note:\($0)" } }
    var sourceRows: [String] { sources.map { "src:\($0)" } }

    public var panes: [Pane] {
        [Pane(id: "facts", title: "facts", rows: noteRows, column: 0), Pane(id: "sources", title: "sources", rows: sourceRows, column: 1)]
    }
}

/// A surface still showing its placeholder: one method, and the view and panes follow.
@MainActor
public protocol PlaceholderSurface: SurfaceProvider {
    func placeholder(_ app: AppModel, route: Route) -> Placeholder
}

public extension PlaceholderSurface {
    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(PlaceholderPage(placeholder(app, route: route))) }
    func panes(_ app: AppModel) -> [Pane] { placeholder(app, route: app.router.route).panes }
}

public struct PlaceholderPage: View {
    @Environment(\.theme) private var theme
    let p: Placeholder

    public init(_ p: Placeholder) { self.p = p }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.title).font(Theme.display(22)).foregroundStyle(theme.goldLeaf)
            Text("area: \(p.area) · not ported yet · j/k move · C-w h/l switch pane · v select · : command").foregroundStyle(theme.inkFaint)
            HStack(alignment: .top, spacing: 12) {
                PaneList(pane: "facts", rows: p.noteRows) { key, _ in
                    Text(p.notes[Int(key.dropFirst(5)) ?? 0]).foregroundStyle(theme.inkDim).lineLimit(1)
                }
                PaneList(pane: "sources", rows: p.sourceRows) { key, _ in
                    Text("viewer-solid/src/v2/\(key.dropFirst(4))").foregroundStyle(theme.inkFaint).font(Theme.mono(11))
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
