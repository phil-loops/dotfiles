import CanopyCore
import SwiftUI

struct WorkInputView: View {
    @Environment(\.theme) private var theme
    let direction: WorkContext.Direction?
    var work: WorkFreshness? = nil
    var lines: Int? = 2

    init(direction: WorkContext.Direction?, work: WorkFreshness? = nil, lines: Int? = 2) {
        self.direction = direction; self.work = work; self.lines = lines
    }

    init(item: TodoItem, lines: Int? = 2) {
        self.init(direction: WorkContext.direction(item), work: item.work, lines: lines)
    }

    static func label(_ direction: WorkContext.Direction?, _ work: WorkFreshness?) -> String {
        switch direction {
        case .journal(let l):
            let when = l.sourceTime.map { "sent \(WorkContext.instant($0))" } ?? "received \(WorkContext.instant(l.receivedAt))"
            return "Your latest instruction · \(when)" + (l.truncated ? " · shortened" : "")
        case .recorded(let r):
            return "Your latest chat instruction · recorded \(r.when) · not captured by the work journal"
        case nil:
            if work?.state == "unavailable" { return "Work journal unreadable · latest instruction unknown" }
            if work?.order == "ambiguous" { return "Instructions from more than one conversation · no single latest" }
            return work == nil ? "No chat instruction recorded" : "No instruction captured"
        }
    }

    /// The last progress report's own words, only where the record is read in full; compact rows keep its dated label.
    static func progressText(_ work: WorkFreshness?, expanded: Bool) -> String? {
        guard expanded, let p = work?.progress, !p.text.isEmpty else { return nil }
        return p.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.label(direction, work)).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
            if let direction {
                Text(direction.text).font(Theme.text(12.5)).foregroundStyle(theme.ink)
                    .lineLimit(lines).textSelection(.enabled)
            }
            if let work {
                Text(WorkContext.freshness(work)).font(Theme.text(11))
                    .foregroundStyle(work.state == "pending" ? theme.goldLeaf : theme.inkFaint).lineLimit(lines == nil ? nil : 2)
                if let p = work.progress { Text(WorkContext.progress(p)).font(Theme.text(11)).foregroundStyle(theme.inkFaint) }
                if let said = Self.progressText(work, expanded: lines == nil) {
                    Text(said).font(Theme.text(12)).foregroundStyle(theme.inkDim).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkContextView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let subject: WorkContext.Subject
    var compact = false
    var showsMissing = false

    var body: some View {
        let context = WorkContext(app.store.trackerItems(), subject: subject)
        if !context.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(context.summary).foregroundStyle(context.doing.isEmpty && context.reopened.isEmpty ? theme.inkDim : theme.goldLeaf)
                        Spacer(minLength: 0)
                        Text(WorkContext.updateLabel(context.updated)).foregroundStyle(theme.inkFaint)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.summary).foregroundStyle(context.doing.isEmpty && context.reopened.isEmpty ? theme.inkDim : theme.goldLeaf)
                        Text(WorkContext.updateLabel(context.updated)).foregroundStyle(theme.inkFaint)
                    }
                }
                .font(Theme.text(11))
                if let shown = context.presentation {
                    Button(shown.item.title) { app.runner.dispatch("todo.show", via: .click, arg: shown.item.id) }
                        .buttonStyle(.plain).font(Theme.text(11)).foregroundStyle(theme.inkDim).lineLimit(1)
                        .labelTarget(pane: "work-context", key: "\(subject.key):\(shown.item.id)", title: shown.item.title, run: RouteTo("todo.show", arg: shown.item.id))
                        .id("\(subject.key):\(shown.item.id)")
                    WorkInputView(direction: shown.direction, work: shown.item.work, lines: compact ? 1 : 2)
                } else if !compact {
                    WorkInputView(direction: nil)
                }
            }
            .padding(.vertical, 5)
        } else if showsMissing {
            Text("No linked work record · no chat instruction recorded")
                .font(Theme.text(11)).foregroundStyle(theme.inkFaint).padding(.vertical, 5)
        }
    }
}

struct WorkInProgressView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @MainActor static func all(_ app: AppModel) -> [TodoItem] {
        app.forestModel.readyOnly ? [] : app.store.trackerItems().filter { $0.state == .doing || WorkContext.reopened($0) }.sorted(by: Tracker.byQueue)
    }

    /// In-progress work on a branch of a forest the home lists: it reads on that forest's row, at its dot.
    @MainActor static func placed(_ app: AppModel) -> [String: [TodoItem]] {
        let m = app.forestModel, p = m.projects(), fs = m.forests()
        let listed = (p.focus + p.workbench + (m.showArchive ? p.archive : [])).compactMap { fs[$0.id] }.filter { !$0.closed }
        return WorkContext.onBranches(all(app), listed.flatMap { $0.branches.map(\.b) })
    }

    /// The bound chats on each listed branch, by its own work or an item placed on it.
    @MainActor static func chatsPlaced(_ app: AppModel, _ placed: [String: [TodoItem]]) -> [String: [WorkContext.Chat]] {
        let chats = chats(app)
        guard !chats.isEmpty else { return [:] }
        let m = app.forestModel, p = m.projects(), fs = m.forests()
        let listed = (p.focus + p.workbench + (m.showArchive ? p.archive : [])).compactMap { fs[$0.id] }.filter { !$0.closed }
        var work: [String: String] = [:]
        for v in listed.flatMap(\.branches) {
            if let w = app.store.rawView("branch", v.b.id)?["work"]?.string { work[v.b.id] = w }
        }
        return WorkContext.chatsOnBranches(chats, branchWork: work, placed: placed)
    }

    @MainActor static func chats(_ app: AppModel) -> [WorkContext.Chat] {
        app.store.rawAll("chat").values.compactMap { try? JSONValue.object($0).decode(WorkContext.Chat.self) }
    }

    /// The rest: work no listed branch carries, so it keeps its own line at the top.
    @MainActor static func items(_ app: AppModel) -> [TodoItem] {
        let onDots = Set(placed(app).values.flatMap { $0.map(\.id) })
        return all(app).filter { !onDots.contains($0.id) }
    }

    @MainActor static func visible(_ app: AppModel) -> Bool {
        !items(app).isEmpty || !WorkContext.onNoWork(chats(app)).isEmpty || app.focusedPane["forests"] == "work"
    }

    var body: some View {
        let items = Self.items(app)
        if Self.visible(app) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHead(text: "In progress · \(items.count)").padding(.leading, 44).padding(.bottom, 6)
                if items.isEmpty {
                    Text(app.forestModel.readyOnly ? "Hidden by the ready filter" : "No work is marked in progress")
                        .font(Theme.text(12)).foregroundStyle(theme.inkFaint)
                        .padding(.leading, 44).padding(.vertical, 8)
                }
                ForEach(items, id: \.id) { item in
                    CursorRow(pane: "work", key: RowKey.todo(item.id)) { on in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.title).font(Theme.display(15)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(WorkContext.workedBy(item, app.store)).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                            }
                            if let now = WorkContext.doingNow(item) {
                                Text("→ \(now)").font(Theme.text(12)).foregroundStyle(theme.inkDim).lineLimit(on ? 3 : 1)
                            }
                            if WorkContext.direction(item) != nil || item.work != nil { WorkInputView(item: item, lines: 1) }
                        }
                        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 6)
                    }
                    .labelTarget(pane: "work", key: RowKey.todo(item.id), title: item.title)
                }
                UnboundChatsList(chats: WorkContext.onNoWork(Self.chats(app)))
            }
            .cursorMarks("work").paneRing("work").padding(.bottom, 22)
        }
    }
}

/// Live chats bound to no work: where each stands, never a guess at what it's doing (round 27, P1).
struct UnboundChatsList: View {
    @Environment(\.theme) private var theme
    let chats: [WorkContext.Chat]

    var body: some View {
        if !chats.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    Text("On no work · \(chats.count)").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    ForEach(chats, id: \.id) { c in
                        Text(WorkContext.whereItStands(c, now: ctx.date.timeIntervalSince1970)).font(Theme.text(12)).foregroundStyle(theme.inkDim).lineLimit(1)
                    }
                }
                .help("live Claude Code chats whose binding names no work: claim an item or start a branch from one to bind it")
                .padding(.leading, 44).padding(.trailing, 16).padding(.top, 10)
            }
        }
    }
}

/// The chats bound to a branch, apart from who is assigned its items (round 27, P2).
struct BranchChatsLine: View {
    @Environment(\.theme) private var theme
    let branch: Branch
    let chats: [WorkContext.Chat]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("◌").foregroundStyle(theme.goldLeaf)
                Text(leaf(branch.name)).foregroundStyle(theme.ink).fixedSize()
                Text(WorkContext.chatsLine(chats, now: ctx.date.timeIntervalSince1970)).foregroundStyle(theme.inkDim).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.text(12))
        }
        .help("the Claude Code chats bound to this branch's work")
        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 2)
    }
}

/// Work in progress on one of a forest's branches, under the forest's row: the branch, what it's doing now, who holds it.
struct BranchWorkLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch
    let item: TodoItem

    var body: some View {
        Button { app.runner.dispatch("todo.show", via: .click, arg: item.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("◉").foregroundStyle(theme.goldLeaf)
                Text(leaf(branch.name)).foregroundStyle(theme.ink).fixedSize()
                Text(WorkContext.doingNow(item).map { "→ \($0)" } ?? item.title).foregroundStyle(theme.inkDim).lineLimit(1)
                Spacer(minLength: 0)
                Text(WorkContext.workedBy(item, app.store)).foregroundStyle(theme.inkFaint).fixedSize()
            }
            .font(Theme.text(12))
        }
        .buttonStyle(.plain)
        .help(item.title)
        .labelTarget(pane: "work-context", key: "dot:\(branch.id):\(item.id)", title: item.title, run: RouteTo("todo.show", arg: item.id))
        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 2)
    }
}
