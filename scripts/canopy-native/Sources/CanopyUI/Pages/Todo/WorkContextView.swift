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
    @MainActor static func listedViews(_ app: AppModel) -> [BranchView] {
        let m = app.forestModel, p = m.projects(), fs = m.forests()
        return (p.focus + p.workbench + (m.showArchive ? p.archive : [])).compactMap { fs[$0.id] }.filter { !$0.closed }.flatMap(\.branches)
    }

    @MainActor static func listedBranches(_ app: AppModel) -> [Branch] { listedViews(app).map(\.b) }

    @MainActor static func chats(_ app: AppModel) -> [WorkContext.Chat] {
        app.store.rawAll("chat").values.compactMap { try? JSONValue.object($0).decode(WorkContext.Chat.self) }
    }

    /// Chats no dot shows that did something lately; a stale one is never listed.
    @MainActor static func noDot(_ app: AppModel) -> [WorkContext.Chat] {
        let onDots = Set(listedViews(app).flatMap { $0.chats.map(\.id) })
        return WorkContext.onNoWork(chats(app), onDots: onDots, now: app.forestModel.now.timeIntervalSince1970)
    }

    /// The work pane's rows: each in-progress item, then the one line for chats on no branch.
    @MainActor static func rows(_ app: AppModel) -> [String] {
        items(app).map { RowKey.todo($0.id) } + (noDot(app).isEmpty ? [] : [RowKey.looseChats])
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
                SectionHead(text: "In progress").padding(.leading, 44).padding(.bottom, 6)
                if items.isEmpty {
                    Text(app.forestModel.readyOnly ? "Hidden by the ready filter" : "No work is marked in progress")
                        .font(Theme.text(12)).foregroundStyle(theme.inkFaint)
                        .padding(.leading, 44).padding(.vertical, 8)
                }
                // one line each: the title and who holds it; its next step and latest direction are ↵ away, on the item
                ForEach(items, id: \.id) { item in
                    CursorRow(pane: "work", key: RowKey.todo(item.id)) { on in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.title).font(Theme.display(15)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(WorkContext.workedBy(item, app.store)).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                        }
                        .help(WorkContext.doingNow(item).map { "next: \($0)" } ?? item.title)
                        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 6)
                    }
                    .labelTarget(pane: "work", key: RowKey.todo(item.id), title: item.title)
                }
                LooseChatsLine(chats: Self.noDot(app))
            }
            .cursorMarks("work").paneRing("work").padding(.bottom, 22)
        }
    }
}

/// Chats on no branch: one quiet line that ↵ (or a click) opens into where each stands, never a guess at what
/// it's doing (rounds 27–28). A chat idle past `WorkContext.staleAfter` isn't counted or listed.
struct LooseChatsLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let chats: [WorkContext.Chat]

    var body: some View {
        if !chats.isEmpty {
            let open = app.forestModel.showLooseChats
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    CursorRow(pane: "work", key: RowKey.looseChats) { on in
                        Button { app.runner.dispatch("chats.loose.toggle", via: .click) } label: {
                            Text("\(open ? "▾" : "▸") \(WorkContext.looseLine(chats, now: ctx.date.timeIntervalSince1970))")
                                .font(Theme.text(11)).foregroundStyle(on ? theme.goldLeaf : theme.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Claude Code chats that edited, committed or bound to no listed branch, active in the last two hours")
                        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 4)
                    }
                    .labelTarget(pane: "work", key: RowKey.looseChats, title: "chats on no branch", run: RouteTo("chats.loose.toggle"))
                    if open {
                        ForEach(chats, id: \.id) { c in
                            HStack(spacing: 10) {
                                ChatButton(chat: c) {
                                    Text(WorkContext.whereItStands(c, now: ctx.date.timeIntervalSince1970)).foregroundStyle(theme.inkDim).lineLimit(1)
                                }
                                Button("bind…") { app.runner.dispatch("chat.bind", via: .click, arg: c) }
                                    .buttonStyle(.plain).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                                    .help("bind this chat to a branch's work")
                            }
                            .padding(.leading, 58).padding(.trailing, 16)
                        }
                    }
                }
                .padding(.top, 6)
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

/// A forest's chats in one phrase on the forest's own line (rounds 27–29): a click brings the newest one's pane forward,
/// the hover names each by id with its evidence branch by branch. Under the cursor, × hides the chats only evidence put
/// on the forest, from every branch it put them on, until they act there again.
struct ForestChats: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let f: ForestView
    let cursor: Bool

    var body: some View {
        let chats = WorkContext.onForest(f.branches)
        let panes = PaneBranches.addresses(on: f.branches, rows: PaneBranches.of(app).rows)
        if cursor && !panes.isEmpty {
            Text(panes.joined(separator: " ")).font(Theme.text(11)).foregroundStyle(theme.inkFaint).fixedSize()
                .help("the tmux panes working on this forest, as window:pane — ⌃a and a pane's number opens its branch")
        }
        if let newest = chats.first {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = ctx.date.timeIntervalSince1970
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let label = WorkContext.forestChatsLabel(chats, says: f.says, now: now) {
                        ChatButton(chat: newest) { Text(label).font(Theme.text(11)).foregroundStyle(theme.inkFaint) }
                            .help(chats.map { "chat \($0.id.prefix(8)): \(WorkContext.forestChatEvidence($0, f.branches, now: now))" }.joined(separator: "\n"))
                    }
                    let inferred = chats.flatMap { c in
                        f.branches.filter { $0.chats.contains { $0.id == c.id } && WorkContext.inferred(c, on: $0.b.id) }.map { (branch: $0.b.id, chat: c.id) }
                    }
                    if cursor && !inferred.isEmpty {
                        Button("×") { for x in inferred { app.runner.dispatch("chat.dismiss", via: .click, target: x.branch, arg: x.chat) } }
                            .buttonStyle(.plain).font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                            .help("these chats aren't on this forest — hide them until they edit or commit here again")
                    }
                }
                .fixedSize()
            }
        }
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
