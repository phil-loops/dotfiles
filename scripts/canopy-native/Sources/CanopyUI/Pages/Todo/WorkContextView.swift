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

    @MainActor static func items(_ app: AppModel) -> [TodoItem] {
        app.forestModel.readyOnly ? [] : app.store.trackerItems().filter { $0.state == .doing || WorkContext.reopened($0) }.sorted(by: Tracker.byQueue)
    }

    @MainActor static func visible(_ app: AppModel) -> Bool {
        !items(app).isEmpty || app.focusedPane["forests"] == "work"
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Theme.display(16)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(2)
                            Text([WorkContext.status(item), WorkContext.owner(item, app.store), WorkContext.updateLabel(item.updated)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                            WorkInputView(item: item, lines: 2)
                        }
                        .padding(.leading, 44).padding(.trailing, 16).padding(.vertical, 8)
                    }
                    .labelTarget(pane: "work", key: RowKey.todo(item.id), title: item.title)
                }
            }
            .cursorMarks("work").paneRing("work").padding(.bottom, 22)
        }
    }
}
