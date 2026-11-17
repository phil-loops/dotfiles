import CanopyCore
import SwiftUI

struct WorkInputView: View {
    @Environment(\.theme) private var theme
    let input: RecordedWorkInput?
    var lines: Int? = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let input {
                Text("Your latest chat instruction · recorded \(input.when)")
                    .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                Text(input.text).font(Theme.text(12.5)).foregroundStyle(theme.ink)
                    .lineLimit(lines).textSelection(.enabled)
            } else {
                Text("No chat instruction recorded").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
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
                        Text(context.summary).foregroundStyle(context.doing.isEmpty ? theme.inkDim : theme.goldLeaf)
                        Spacer(minLength: 0)
                        Text(WorkContext.updateLabel(context.updated)).foregroundStyle(theme.inkFaint)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.summary).foregroundStyle(context.doing.isEmpty ? theme.inkDim : theme.goldLeaf)
                        Text(WorkContext.updateLabel(context.updated)).foregroundStyle(theme.inkFaint)
                    }
                }
                .font(Theme.text(11))
                if let latest = context.latestInput {
                    Button(latest.item.title) { app.runner.dispatch("todo.show", via: .click, arg: latest.item.id) }
                        .buttonStyle(.plain).font(Theme.text(11)).foregroundStyle(theme.inkDim).lineLimit(1)
                        .labelTarget(pane: "work-context", key: "\(subject.key):\(latest.item.id)", title: latest.item.title, run: RouteTo("todo.show", arg: latest.item.id))
                        .id("\(subject.key):\(latest.item.id)")
                    WorkInputView(input: latest.input, lines: compact ? 1 : 2)
                } else if !compact {
                    WorkInputView(input: nil)
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
        app.forestModel.readyOnly ? [] : app.store.trackerItems().filter { $0.state == .doing }.sorted(by: Tracker.byQueue)
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
                            WorkInputView(input: RecordedWorkInput.chat(in: item.body), lines: 2)
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
