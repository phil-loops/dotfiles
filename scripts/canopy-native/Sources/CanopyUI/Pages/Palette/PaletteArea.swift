import CanopyCore
import SwiftUI

/// The shell's overlays: the space menu (Menu.tsx), the `?` key sheet (KeySheet.tsx), the code
/// picker (Picker.tsx) and which-key (WhichKey.tsx). Phase 1 ships working minimal versions; the
/// Palette porter owns making them match the web app (finds, groups, the sheet's sections).
enum PaletteArea: PageArea {
    static let name = "palette"

    /// The menu layer's own keys; printable keys go to its filter field.
    static func install(_ app: AppModel) {
        let menu = app.state { MenuState() }
        app.registry.register(Command(id: "menu.next", title: "Next in the menu", scope: .global, keys: ["down", "C-n", "tab"], modes: [.menu], quiet: true,
                                      local: { [weak app] _, _ in if let app { menu.index = min(max(0, menu.items(app).count - 1), menu.index + 1) } }))
        app.registry.register(Command(id: "menu.prev", title: "Previous in the menu", scope: .global, keys: ["up", "C-p"], modes: [.menu], quiet: true,
                                      local: { _, _ in menu.index = max(0, menu.index - 1) }))
        app.registry.register(Command(id: "menu.run", title: "Run the highlighted command", scope: .global, keys: ["ret"], modes: [.menu], quiet: true,
                                      local: { [weak app] _, _ in
                                          guard let app else { return }
                                          let items = menu.items(app)
                                          guard items.indices.contains(menu.index) else { return }
                                          app.runner.dispatch(items[menu.index].id, via: menu.query.isEmpty ? .menu : .palette)
                                      }))
    }
}

/// The space menu's filter and highlight (Menu.tsx's signals).
@Observable
final class MenuState {
    var query = ""
    var index = 0

    @MainActor
    func items(_ app: AppModel) -> [Command] {
        let scopes = app.liveScopes()
        let q = query.lowercased()
        return app.registry.commands.filter { c in
            !c.quiet && !c.needsArg && c.modes.contains(.normal) && scopes.contains(c.scope) && (c.available?(app.target(for: c.scope)) ?? true)
                && (q.isEmpty || "\(c.title) \(c.id)".lowercased().contains(q))
        }
    }
}

/// Helix's which-key: a half-typed prefix opens a box in the corner listing what can follow it here.
struct WhichKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if !app.keys.pendingKeys.isEmpty {
            let rows = app.keys.whichKeyRows()
            VStack(alignment: .leading, spacing: 1) {
                Text(glyph(app.keys.pendingKeys)).foregroundStyle(theme.goldLeaf).padding(.bottom, 4)
                if rows.isEmpty {
                    Text("nothing here").foregroundStyle(theme.inkFaint)
                }
                ForEach(rows, id: \.key) { r in
                    HStack(spacing: 12) {
                        Text(glyph(r.key)).foregroundStyle(theme.goldLeaf).frame(width: 32, alignment: .leading)
                        Text(r.what).foregroundStyle(theme.inkDim)
                    }
                }
            }
            .font(Theme.mono(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
            .background(theme.vellumRaise)
            .border(theme.rule)
            .shadow(radius: 12)
        }
    }
}

/// `space`: every command in reach, filterable; its keys are the `menu` layer's (menu.next/prev/run).
struct CommandMenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        if app.menuOpen {
            @Bindable var menu = app.state { MenuState() }
            let items = menu.items(app)
            VStack(spacing: 0) {
                TextField("run a command…", text: $menu.query)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .focused($focused)
                    .onChange(of: menu.query) { menu.index = 0 }
                theme.rule.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                                HStack {
                                    Text(c.title).lineLimit(1)
                                    Spacer()
                                    Text(c.keys.map(glyph).joined(separator: " · ")).foregroundStyle(theme.inkFaint)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .foregroundStyle(i == menu.index ? theme.goldLeaf : theme.inkDim)
                                .background(i == menu.index ? theme.goldWash : .clear)
                                .id(i)
                            }
                        }
                    }
                    .onChange(of: menu.index) { _, i in proxy.scrollTo(i) }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 520)
            .background(theme.vellumRaise)
            .border(theme.rule)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 80)
            .background(theme.vellumNight.opacity(0.7))
            .onAppear { menu.query = ""; menu.index = 0; focused = true }
        }
    }
}

/// `?`: what every key does here (sheet.ts sheetNow).
struct KeySheetView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if app.sheetOpen {
            let live = app.liveScopes().map(\.rawValue)
            let cmds = app.registry.commands.map {
                SheetCmd(id: $0.id, title: $0.title, scope: $0.scope.rawValue, keys: $0.keys, available: $0.available?(app.target(for: $0.scope)) ?? true)
            }
            let sheet = sheetNow(surface: app.router.surface.id, live: live, cmds: cmds,
                                 surfaceScopes: app.registry.surfaceScopes.mapValues { $0.map(\.rawValue) })
            ZStack {
                theme.vellumNight.opacity(0.7)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.registry.keyProblems, id: \.self) { Text($0).foregroundStyle(theme.ember) }
                        section("here", sheet.now)
                        section("everywhere", sheet.everywhere)
                        section("not now", sheet.notNow)
                    }
                    .padding(16)
                }
                .frame(width: 560, height: 480)
                .background(theme.vellumRaise)
                .border(theme.rule)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [SheetLine]) -> some View {
        if !lines.isEmpty {
            Text(title.uppercased()).font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint).padding(.top, 8)
            ForEach(lines, id: \.cmd.id) { l in
                HStack(spacing: 12) {
                    Text(l.key.split(separator: " · ").map { glyph(String($0)) }.joined(separator: " · "))
                        .foregroundStyle(theme.goldLeaf).frame(width: 90, alignment: .leading)
                    Text(l.cmd.title).foregroundStyle(theme.inkDim)
                }
            }
        }
    }
}

/// The code picker: places with more than one answer (references, symbols), filterable.
struct PickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let p = app.nav.picker {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).foregroundStyle(theme.goldLeaf)
                ForEach(Array(app.nav.shown.enumerated()), id: \.offset) { i, it in
                    Text("\(it.label)  \(it.text ?? "")").lineLimit(1)
                        .foregroundStyle(i == app.nav.index ? theme.goldLeaf : theme.inkDim)
                }
            }
            .padding(12)
            .frame(width: 560, alignment: .leading)
            .background(theme.vellumRaise)
            .border(theme.rule)
        }
    }
}
