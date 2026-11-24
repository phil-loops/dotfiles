import CanopyCore
import SwiftUI

struct MachineRunsRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let reports = MachineRuns.of(app)
        VStack(alignment: .leading, spacing: 4) {
            Text("reported runs").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
            if reports.unavailable { Text(reports.runs.isEmpty ? "run registry unavailable" : "run registry unavailable · showing last reports").foregroundStyle(theme.inkFaint) }
            if reports.unreadable > 0 { Text("\(reports.unreadable) run documents unavailable").foregroundStyle(theme.inkFaint) }
            if reports.runs.isEmpty, !reports.unavailable {
                Text(reports.loaded ? "no unfinished run documents" : "reading run reports…").foregroundStyle(theme.inkFaint)
            }
            ForEach(reports.runs, id: \.url) { run in
                CursorRow(pane: "queue", key: run.key) { on in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(run.title).font(Theme.display(16)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(on ? nil : 1)
                            Spacer(minLength: 4)
                            if let progress = run.progress { Text(progress).foregroundStyle(theme.inkDim) }
                        }
                        Text([run.reportedState, run.stale(at: reports.now) ? "stalled?" : nil, run.freshness(at: reports.now)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(run.stale(at: reports.now) ? theme.ember : theme.inkFaint)
                        if let current = run.current { Text(current).foregroundStyle(theme.inkDim).lineLimit(on ? nil : 1) }
                        if on {
                            Text("document report · slot association unavailable · \(app.registry.keyOf("machine.run.open")) opens in Show").foregroundStyle(theme.inkFaint)
                            Text(run.url.path).foregroundStyle(theme.inkFaint).lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                }
            }
        }
        .font(Theme.text(12))
        .padding(.top, 8)
    }
}

@MainActor
enum MachineRunCommands {
    static func install(_ app: AppModel) {
        app.registry.register(Command(id: "machine.run.open", title: "Open the reported run document in Show", scope: .reportedRun,
            verb: .main, label: "open", available: { [weak app] path in app.map { MachineRuns.of($0).run(path) != nil } ?? false },
            local: { [weak app] path, _ in
                guard let app, let path else { return }
                MachineRuns.of(app).open(path)
            }))
        app.registry.register(Command(id: "machine.runs.refresh", title: "Refresh reported run documents", scope: .machine,
            local: { [weak app] _, _ in if let app { Task { await MachineRuns.of(app).refresh() } } }))
        app.addCloser(first: true, isOpen: { [weak app] in app.map { MachineRuns.of($0).waiting } ?? false }, close: { [weak app] in
            guard let app else { return }
            MachineRuns.of(app).cancelOpening()
            app.runner.say("run opening cancelled")
        })
    }
}
