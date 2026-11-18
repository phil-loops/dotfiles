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

    /// Every branch of a forest the home lists, in its forest's merge order.
    @MainActor static func listedBranches(_ app: AppModel) -> [Branch] {
        let m = app.forestModel, p = m.projects(), fs = m.forests()
        return (p.focus + p.workbench + (m.showArchive ? p.archive : [])).compactMap { fs[$0.id] }.filter { !$0.closed }.flatMap { $0.branches.map(\.b) }
    }

    /// The bound chats on each listed branch, by its own work or an item placed on it.
    @MainActor static func chatsPlaced(_ app: AppModel, _ placed: [String: [TodoItem]]) -> [String: [WorkContext.Chat]] {
        let chats = chats(app)
        guard !chats.isEmpty else { return [:] }
        let listed = listedBranches(app)
        var work: [String: String] = [:]
        for b in listed {
            if let w = app.store.rawView("branch", b.id)?["work"]?.string { work[b.id] = w }
        }
        return WorkContext.chatsOnBranches(chats, branches: listed.map(\.id), branchWork: work, placed: placed)
    }

    @MainActor static func chats(_ app: AppModel) -> [WorkContext.Chat] {
        app.store.rawAll("chat").values.compactMap { try? JSONValue.object($0).decode(WorkContext.Chat.self) }
    }

    /// Live chats no dot shows.
    @MainActor static func noDot(_ app: AppModel) -> [WorkContext.Chat] {
        let onDots = Set(chatsPlaced(app, placed(app)).values.flatMap { $0.map(\.id) })
        return WorkContext.onNoWork(chats(app), onDots: onDots)
    }

    /// The rest: work no listed branch carries, so it keeps its own line at the top.
    @MainActor static func items(_ app: AppModel) -> [TodoItem] {
        let onDots = Set(placed(app).values.flatMap { $0.map(\.id) })
        return all(app).filter { !onDots.contains($0.id) }
    }

    @MainActor static func visible(_ app: AppModel) -> Bool {
        !items(app).isEmpty || !noDot(app).isEmpty || app.focusedPane["forests"] == "work"
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
                UnboundChatsList(chats: Self.noDot(app))
            }
            .cursorMarks("work").paneRing("work").padding(.bottom, 22)
        }
    }
}

/// Live chats on no branch: where each stands, never a guess at what it's doing (rounds 27–28).
struct UnboundChatsList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let chats: [WorkContext.Chat]

    var body: some View {
        if !chats.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    Text("On no branch · \(chats.count)").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    ForEach(chats, id: \.id) { c in
                        HStack(spacing: 10) {
                            ChatButton(chat: c) {
                                Text(WorkContext.whereItStands(c, now: ctx.date.timeIntervalSince1970)).foregroundStyle(theme.inkDim).lineLimit(1)
                            }
                            Button("bind…") { app.runner.dispatch("chat.bind", via: .click, arg: c) }
                                .buttonStyle(.plain).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                                .help("bind this chat to a branch's work")
                        }
                    }
                }
                .help("live Claude Code chats that edited or committed on no listed branch in the last two hours")
                .padding(.leading, 44).padding(.trailing, 16).padding(.top, 10)
            }
        }
    }
}

/// A chat that a click brings forward in its tmux pane (claude-jump); it never types into it.
struct ChatButton<Label: View>: View {
    @Environment(AppModel.self) private var app
    let chat: WorkContext.Chat
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { app.runner.dispatch("chat.focus", via: .click, arg: chat.id) } label: { label().font(Theme.text(12)) }
            .buttonStyle(.plain)
            .help(chat.pane == nil ? "this chat isn't in tmux" : "bring this chat's pane forward")
            .disabled(chat.pane == nil)
    }
}

/// The chats on a branch, apart from who is assigned its items (rounds 27–28).
struct BranchChatsLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch
    let chats: [WorkContext.Chat]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("◌").foregroundStyle(theme.goldLeaf)
                Text(leaf(branch.name)).foregroundStyle(theme.ink).fixedSize()
                ForEach(chats, id: \.id) { c in
                    ChatButton(chat: c) { Text(WorkContext.chatLabel(c, on: branch.id, now: ctx.date.timeIntervalSince1970)).foregroundStyle(theme.inkDim) }
                    if WorkContext.inferred(c, on: branch.id) {
                        Button("×") { app.runner.dispatch("chat.dismiss", via: .click, target: branch.id, arg: c.id) }
                            .buttonStyle(.plain).foregroundStyle(theme.inkFaint)
                            .help("this chat isn't on this branch — hide it until it edits or commits here again")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(Theme.text(12))
        }
        .help("the Claude Code chats on this branch: each one edited or committed here lately, or is bound to its work")
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
