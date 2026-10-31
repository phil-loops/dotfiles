import SwiftUI

// A projection sim in a tutor turn (TutorSim.tsx): frozen at the reveal while the learner
// predicts, then — once their answer carries the played result — the reveal's steps, the end
// state, and every event the system skipped, counted twice or left pinned. The engine is
// deterministic, so the card replays it from the scenario and the safeguards rather than storing state.

private struct SimStateView: View {
    @Environment(\.theme) private var theme
    let s: SimState
    var marked: [String: String] = [:]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                label("events")
                Flow(s.events.map { e in
                    let counted = e.applied.values.reduce(0, +)
                    let mark = marked[e.id]
                    let color = mark != nil ? theme.del : e.committed ? theme.ink : theme.inkDim
                    return (Text(e.id).foregroundColor(color) + Text(" t\(e.stamp)").foregroundColor(theme.inkFaint)
                        + Text("\(e.committed ? "" : " ·uncommitted") ×\(counted)\(mark.map { " \($0)" } ?? "")").foregroundColor(color))
                })
            }
            GridRow {
                label("bookmarks")
                Flow(s.bookmarks.map { b in
                    Text("\(b.name) → \(b.cursor.id.isEmpty ? "start" : "\(b.cursor.id) t\(b.cursor.stamp)")")
                        .strikethrough(!b.live).foregroundColor(b.live ? theme.inkDim : theme.inkDim.opacity(0.6))
                })
            }
            GridRow {
                label("workers")
                Flow(s.workers.map { Text("\($0.id) \($0.status)").foregroundColor(theme.inkDim) })
            }
            GridRow {
                label("clock")
                Text("t\(s.clock)").foregroundStyle(theme.inkDim)
            }
        }
        .font(Theme.text(11.5))
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(Theme.text(10)).tracking(0.8).foregroundStyle(theme.inkFaint)
    }

    /// Items laid out left to right, wrapping (flex-wrap).
    private struct Flow: View {
        let items: [Text]
        init(_ items: [Text]) { self.items = items }
        var body: some View {
            items.enumerated().reduce(Text("")) { acc, x in x.offset == 0 ? x.element : acc + Text("   ") + x.element }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OffLine: View {
    @Environment(\.theme) private var theme
    let off: [String]
    var body: some View {
        Text(off.isEmpty ? "every safeguard on" : "safeguard off: \(off.map { Kernel(rawValue: $0)?.title ?? $0 }.joined(separator: " · "))")
            .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
    }
}

/// The setup, frozen before the reveal — what the learner predicts from.
struct SimFrozen: View {
    @Environment(\.theme) private var theme
    let scenario: String
    let off: [String]

    var body: some View {
        if let sim = SimScenarios.sim(scenario, off: off) {
            let frozen = sim.toReveal()
            VStack(alignment: .leading, spacing: 6) {
                Text("SIM · FROZEN BEFORE THE REVEAL").font(Theme.text(10)).tracking(0.8).foregroundStyle(theme.inkFaint)
                Text(sim.scenario.title).font(Theme.display(15)).foregroundStyle(theme.ink)
                OffLine(off: off)
                Text(sim.scenario.situation).font(Theme.text(13)).foregroundStyle(theme.inkDim).fixedSize(horizontal: false, vertical: true)
                SimStateView(s: frozen)
                Text(sim.scenario.question).font(Theme.text(13)).foregroundStyle(theme.goldLeaf).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.vellumNight)
            .overlay(Rectangle().stroke(theme.rule))
            .padding(.vertical, 6)
        } else {
            Text("no sim scenario \(scenario)").font(Theme.text(12)).foregroundStyle(theme.del).padding(.vertical, 6)
        }
    }
}

/// The sim played out after the learner's answer: what happened, and where the system diverged.
struct SimPlayed: View {
    @Environment(\.theme) private var theme
    let scenario: String
    let off: [String]

    struct Played {
        var title: String
        var result: SimResult
        var end: SimState
        var steps: [String]
        var marked: [String: String]
    }

    static func play(_ scenario: String, _ off: [String]) -> Played? {
        guard let sim = SimScenarios.sim(scenario, off: off) else { return nil }
        let from = sim.toReveal().log.count
        let result = sim.runToEnd()
        let end = sim.state()
        return Played(title: sim.scenario.title, result: result, end: end, steps: Array(end.log[from...]),
                      marked: Dictionary(result.divergence.map { ($0.event, $0.kind) }, uniquingKeysWith: { _, b in b }))
    }

    var body: some View {
        if let r = Self.play(scenario, off) {
            let green = r.result.outcome == "green"
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("SIM · PLAYED").font(Theme.text(10)).tracking(0.8).foregroundStyle(theme.inkFaint)
                    Text(green ? "✓ every event counted once" : "✗ \(r.result.divergence.map { "\($0.event) \($0.kind)" }.joined(separator: " · "))")
                        .font(Theme.text(12)).foregroundStyle(green ? theme.add : theme.del)
                    Spacer()
                    Text("counted \(r.result.actual) of \(r.result.truth)\(r.result.busy > 0 ? " · \(r.result.busy) pages waited on the lock" : "")")
                        .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                }
                Text(r.title).font(Theme.text(13)).foregroundStyle(theme.ink)
                OffLine(off: off)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { i, line in
                        Text("\(i + 1). \(line)").font(Theme.mono(11.5)).foregroundStyle(theme.inkDim)
                    }
                }
                SimStateView(s: r.end, marked: r.marked)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(green ? theme.add : theme.del))
            .padding(.vertical, 6)
        }
    }
}
