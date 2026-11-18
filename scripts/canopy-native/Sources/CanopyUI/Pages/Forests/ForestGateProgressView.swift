import CanopyCore
import SwiftUI

struct ForestGateProgressView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var reader = GateProgressRead()
    let branch: Branch

    var body: some View {
        let source = GateProgressRead.Source(branch)
        Button { app.runner.dispatch("branch.open", via: .click, target: branch.id) } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Text("gates").foregroundStyle(theme.goldLeaf)
                    switch reader.status(for: source) {
                    case .loading: Text("reading progress…").foregroundStyle(theme.inkFaint)
                    case .unavailable: Text("progress unavailable").foregroundStyle(theme.inkFaint)
                    case .observed(let progress):
                        let summary = GateProgressSummary(progress, now: context.date.timeIntervalSince1970)
                        if !summary.rows.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(color(row.state))
                                        .frame(width: 5, height: row.state == .running ? 10 : 6)
                                }
                            }
                            Text("\(summary.complete)/\(summary.rows.count)").foregroundStyle(theme.inkDim).monospacedDigit()
                        }
                        Text(summary.activity).foregroundStyle(summary.rows.contains { $0.state == .red || $0.state == .stopped } ? theme.ember : theme.inkDim)
                        if let time = summary.time { Text(time).foregroundStyle(theme.inkFaint).monospacedDigit() }
                    }
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Open this branch’s gate run")
        .task(id: source) {
            await reader.watch(source) { source in
                try await app.transport.getJSON(app.transport.atRepo(source.repo, "/gates-progress?branch=\(source.branch.uriComponent)"), as: GateProgress.self)
            }
        }
    }

    private func color(_ state: GateRow.State) -> Color {
        switch state {
        case .green: theme.patina
        case .running, .waived: theme.goldLeaf
        case .red, .stopped: theme.ember
        case .queued, .skipped: theme.rule
        }
    }
}
