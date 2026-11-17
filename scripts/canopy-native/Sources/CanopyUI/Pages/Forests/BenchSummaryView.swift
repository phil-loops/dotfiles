import CanopyCore
import SwiftUI

struct BenchSummaryRow {
    let title: String
    let text: String
    let date: Date?
}

enum BenchSummary {
    static let limit = 2

    static func rows(_ entries: [BenchEntry], for subject: BenchSubject) -> [BenchSummaryRow] {
        let rows = entries.flatMap { entry -> [BenchSummaryRow] in
            func row(_ text: String, date: Date? = nil) -> BenchSummaryRow {
                BenchSummaryRow(title: entry.document.title, text: text, date: date)
            }
            switch entry.status {
            case .noRuns: return [row("no recorded runs")]
            case .unavailable: return [row("recorded result unavailable")]
            case .observations:
                guard let totals = entry.totals(for: subject) else { return [row("recorded counts unavailable")] }
                if totals.isEmpty { return [row("no applicable recorded counts")] }
                return totals.map { observation in
                    let date = parseISO(observation.recordedAt)
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "MMM d, yyyy HH:mm 'UTC'"
                    let time = date.map(formatter.string) ?? observation.recordedAt
                    let count = observation.total == 0 ? "no claims" : "\(observation.fixed) of \(observation.total) fixed"
                    return row("\(count) on \(observation.environment) · \(time)", date: date)
                }
            }
        }
        return rows.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return ($0.title, $0.text) < ($1.title, $1.text)
        }
    }
}

struct BenchSummaryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scene
    let subject: BenchSubject

    private var command: String {
        if case .branch = subject { return "bench.open.review" }
        return "bench.open.forest"
    }

    var body: some View {
        let library = BenchLibrary.of(app)
        VStack(alignment: .leading, spacing: 0) {
            if library.subject == subject, !library.entries.isEmpty {
                let rows = BenchSummary.rows(library.entries, for: subject)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Recorded responses · current claims").foregroundStyle(theme.inkFaint).lineLimit(1)
                        KeyButton(title: library.entries.count == 1 ? "bench" : "\(library.entries.count) benches", id: command, busy: BenchOpening.of(app).waiting)
                            .labelTarget(pane: "bench-open", key: "open", title: "bench", run: RouteTo(command))
                        if library.loading { Text("refreshing…").foregroundStyle(theme.inkFaint) }
                    }
                    ForEach(Array(rows.prefix(BenchSummary.limit).enumerated()), id: \.offset) { _, row in
                        Text((library.entries.count > 1 ? "\(row.title) · " : "") + row.text)
                            .foregroundStyle(theme.inkDim).lineLimit(2)
                    }
                    if rows.count > BenchSummary.limit {
                        Text("\(rows.count - BenchSummary.limit) more recorded results in Show").foregroundStyle(theme.inkFaint)
                    }
                }
                .font(Theme.text(11))
                .padding(.vertical, 4)
            } else if library.subject == subject, library.failed {
                Text("bench library unavailable").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
            }
        }
        .task(id: subject) { await library.load(subject) }
        .onChange(of: scene) { _, phase in
            if phase == .active { Task {
                guard BenchSubject.current(app) == subject else { return }
                await library.load(subject)
            } }
        }
    }
}
