import CanopyCore
import Foundation
import SwiftUI

/// `space ?` (Menu.tsx): every command in reach, filterable, grouped, each showing its key so using
/// the menu teaches it; then the branches, forests, wiki pages and concepts the text finds. `ret`
/// runs the highlighted one. Its keys are the `menu` layer's (menu.next/prev/run); typing goes to
/// its filter.
enum MenuGroups {
    /// The palette's sections, in this order; within one, what the cursor is on comes first.
    static let order = ["move", "view", "review", "words & push", "machine", "wiki", "tutor", "go", "forests", "branches", "wiki pages", "concepts"]

    static func of(_ id: String) -> String {
        if Rx.test("^machine\\.", id) { return "machine" }
        if Rx.test("^wiki\\.", id) { return "wiki" }
        if Rx.test("^tutor\\.", id) { return "tutor" }
        if Rx.test("^(nav|place)\\.|^help\\.|^branch\\.(pr|open)$|^forest\\.page$|^review\\.(definition|open|finish)$", id) { return "go" }
        if Rx.test("^(cursor|focus|history|commit)\\.|^review\\.(down|up|top|bottom|thread\\.(next|prev)|file\\.(next|prev)|leave|back)$|^forest\\.(expand|collapse|leave)$|^todo\\.(up|down)$", id) { return "move" }
        if Rx.test("^review\\.(tab|split|outdated|map|filter|types|history)|^(forest\\.face|ready\\.toggle|archive\\.toggle|dashboard\\.range|todo\\.open)$", id) { return "view" }
        if Rx.test("words|^story\\.|push|^forest\\.launch$|^project\\.|^hold\\.|^todo\\.|^undo$", id) { return "words & push" }
        return "review"
    }

    static let ofFind = ["find.forest": "forests", "find.wiki": "wiki pages", "find.concept": "concepts", "find.branch": "branches"]
}

struct MenuRow: Equatable {
    var id: String
    var arg: String?
    var title: String
    var side: String
    var group: String
}

/// The space menu's filter, highlight, and what it found beyond the live store (Menu.tsx's signals).
@MainActor
@Observable
final class MenuState {
    var query = ""
    var index = 0
    /// Every branch and PR, archived forests' too — the live store leaves those out, the finder can't.
    var archived = FindWorld()
    /// The tutor's concepts (GET /learning-state), when the tutor registers `find.concept`.
    var concepts: [FindWorld.Concept] = []

    /// The menu just opened: start from the top, and fetch what the finder reads beyond the store.
    func opened(_ app: AppModel) {
        query = ""
        index = 0
        let t = app.transport
        Task { @MainActor [weak self] in
            if let s = try? await t.getJSON("/state?archived=1", as: ArchivedState.self) { self?.archived = s.world }
        }
        app.state { WikiState() }.load(app)
        if app.registry.command("find.concept") != nil, concepts.isEmpty {
            Task { @MainActor [weak self] in
                if let l = try? await t.getJSON("/learning-state", as: LearningConcepts.self) {
                    self?.concepts = l.concepts.map { FindWorld.Concept(id: $0.key, name: $0.value.name ?? $0.key.replacingOccurrences(of: "-", with: " ")) }
                        .sorted { $0.id < $1.id }
                }
            }
        }
    }

    /// The commands in reach that match, grouped, the cursor's narrowest scope first within a group.
    func commands(_ app: AppModel) -> [Command] {
        let scopes = app.liveScopes()
        let q = query.lowercased()
        let group = Dictionary(uniqueKeysWithValues: MenuGroups.order.enumerated().map { ($1, $0) })
        return app.registry.commands.enumerated().filter { _, c in
            !c.quiet && !c.needsArg && c.modes.contains(.normal) && scopes.contains(c.scope) && (c.available?(app.target(for: c.scope)) ?? true)
                && (q.isEmpty || "\(c.title) \(c.id)".lowercased().contains(q))
        }
        .sorted { a, b in
            let ga = group[MenuGroups.of(a.element.id)] ?? 0, gb = group[MenuGroups.of(b.element.id)] ?? 0
            let sa = scopes.firstIndex(of: a.element.scope) ?? 0, sb = scopes.firstIndex(of: b.element.scope) ?? 0
            return (ga, sa, a.offset) < (gb, sb, b.offset)
        }
        .map(\.element)
    }

    func world(_ app: AppModel) -> FindWorld {
        let s = app.store
        func merged<T: Equatable>(_ live: [T], _ more: [T], _ id: (T) -> String) -> [T] {
            let have = Set(live.map(id))
            return live + more.filter { !have.contains(id($0)) }
        }
        let branches = s.list(Branch.self).map { FindWorld.Branch(id: $0.id, name: $0.name, project: $0.project) }
        let prs = s.list(Pr.self).map { FindWorld.Pr(id: $0.id, number: $0.number) }
        let wiki = app.state { WikiState() }
        return FindWorld(branches: merged(branches, archived.branches, \.id),
                         projects: s.list(Project.self).map { FindWorld.Project(id: $0.id, name: $0.name, archived: $0.state == .archive) },
                         prs: merged(prs, archived.prs, \.id),
                         pages: wiki.pages.map { FindWorld.Page(slug: $0.slug, title: $0.title, section: $0.section) },
                         concepts: concepts)
    }

    func rows(_ app: AppModel) -> [MenuRow] {
        let cmds = commands(app).map { c in
            MenuRow(id: c.id, title: c.title, side: c.keys.map(glyph).joined(separator: " · "), group: MenuGroups.of(c.id))
        }
        let found = Finder.finds(query, world(app))
            .filter { app.registry.command($0.cmd) != nil }
            .map { MenuRow(id: $0.cmd, arg: $0.id, title: $0.title, side: $0.sub, group: MenuGroups.ofFind[$0.cmd] ?? "") }
        return cmds + found
    }

    func run(_ app: AppModel) {
        let rs = rows(app)
        guard rs.indices.contains(index) else { return }
        let r = rs[index]
        app.runner.dispatch(r.id, via: query.isEmpty ? .menu : .palette, arg: r.arg)
    }
}

/// `/state?archived=1`, read for just what the finder needs.
struct ArchivedState: Decodable {
    struct B: Decodable { var id: String; var name: String; var project: String? }
    struct P: Decodable { var id: String; var number: Int? }
    struct E: Decodable {
        var branch: [String: B]?
        var pr: [String: P]?
    }
    var entities: E

    var world: FindWorld {
        FindWorld(branches: (entities.branch ?? [:]).values.map { FindWorld.Branch(id: $0.id, name: $0.name, project: $0.project ?? "") }.sorted { $0.id < $1.id },
                  prs: (entities.pr ?? [:]).values.compactMap { p in p.number.map { FindWorld.Pr(id: p.id, number: $0) } }.sorted { $0.id < $1.id })
    }
}

/// `/learning-state`, read for the concepts' names.
struct LearningConcepts: Decodable {
    struct C: Decodable { var name: String? }
    var concepts: [String: C]
}

struct CommandMenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        if app.menuOpen {
            @Bindable var menu = app.state { MenuState() }
            let rows = menu.rows(app)
            ZStack(alignment: .top) {
                theme.vellumNight.opacity(0.7)
                    .onTapGesture { app.menuOpen = false }
                VStack(spacing: 0) {
                    TextField("run a command, or find a branch, a page, a concept…", text: $menu.query)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .focused($focused)
                        .onChange(of: menu.query) { menu.index = 0 }
                    theme.rule.frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if rows.isEmpty { Text("no match").foregroundStyle(theme.inkFaint).padding(.horizontal, 12).padding(.vertical, 8) }
                                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                                    if i == 0 || rows[i - 1].group != r.group {
                                        Text(r.group.uppercased()).font(Theme.mono(10.5)).tracking(1.2).foregroundStyle(theme.inkFaint)
                                            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                                    }
                                    HStack(spacing: 12) {
                                        Text(r.title).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(r.side).foregroundStyle(theme.inkFaint).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .foregroundStyle(i == menu.index ? theme.goldLeaf : theme.inkDim)
                                    .background(i == menu.index ? theme.goldWash : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { menu.index = i; menu.run(app) }
                                    .id(i)
                                }
                            }
                            .padding(4)
                        }
                        .onChange(of: menu.index) { _, i in proxy.scrollTo(i) }
                    }
                    .frame(maxHeight: 420)
                }
                .frame(width: 560)
                .background(theme.vellumRaise)
                .overlay { Rectangle().stroke(theme.rule, lineWidth: 1) }
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .padding(.top, 90)
            }
            .font(Theme.mono(12.5))
            .onAppear { menu.opened(app); focused = true }
        }
    }
}
