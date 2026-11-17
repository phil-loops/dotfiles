import Foundation

enum DashboardClient: Hashable {
    case app(String)
    case unattributed
    case all

    init(_ name: String?) {
        if let name, !name.isEmpty, name != "?" { self = .app(name) }
        else { self = .unattributed }
    }

    var title: String {
        switch self {
        case let .app(name): name
        case .unattributed: "unattributed"
        case .all: "all clients"
        }
    }

    fileprivate var identity: String {
        switch self {
        case let .app(name): "app:\(name.utf8.count):\(name)"
        case .unattributed: "unattributed"
        case .all: "all"
        }
    }
}

struct DashboardTiming: Equatable {
    let samples: Int?
    let p95: Double?
    let budget: Double?

    init(_ stats: Stats?, budget: Double?) {
        samples = stats.flatMap { $0.n >= 0 ? $0.n : nil }
        p95 = (samples ?? 0) > 0 ? stats?.p95.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
        self.budget = budget.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var ratio: Double? { DashText.ratio(p95, budget) }

    var support: String {
        guard let samples else { return "samples unavailable" }
        if samples == 0 { return "no samples" }
        return "n=\(samples)"
    }
}

struct DashboardCommand: Identifiable {
    let client: DashboardClient
    let name: String
    let source: TelemetryRow

    init?(_ row: TelemetryRow) {
        guard let name = row.id, !name.isEmpty else { return nil }
        client = DashboardClient(row.app)
        self.name = name
        source = row
    }

    var id: String { "cmd:\(client.identity):\(name)" }
    var feedback: DashboardTiming { DashboardTiming(source.feedback, budget: source.budgetMs?.feedbackMs) }
    var settled: DashboardTiming { DashboardTiming(source.settled, budget: source.budgetMs?.settledMs) }
}

struct DashboardReport {
    let commands: [DashboardCommand]
    let withheld: Int

    init(_ rows: [TelemetryRow]) {
        let named = rows.compactMap(DashboardCommand.init)
        let counts = Dictionary(grouping: named, by: \.id).mapValues(\.count)
        commands = named.filter { counts[$0.id] == 1 }
        withheld = rows.count - commands.count
    }

    var clients: [DashboardClient] {
        let others = Set(commands.map(\.client)).subtracting([.app("native"), .unattributed, .all])
            .sorted { $0.title < $1.title }
        return [.app("native")] + others + (commands.contains { $0.client == .unattributed } ? [.unattributed] : []) + [.all]
    }

    func rows(for client: DashboardClient) -> [DashboardCommand] {
        commands.filter { client == .all || $0.client == client }
    }
}
