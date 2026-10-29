import CanopyCore
import SwiftUI

/// The label layer while it's up (NAV.md §4.3): the targets as they were when it opened, their
/// labels, and the label typed so far.
public struct LabelSession: Equatable {
    public struct Item: Equatable {
        public var label: String
        public var pane: String
        public var key: String
        public var rect: CGRect
        public var title: String
    }
    public var items: [Item]
    public var typed = ""
    /// the targets themselves, by item index (their `run`s aren't Equatable)
    var targets: [LabelTarget]

    public static func == (a: Self, b: Self) -> Bool { a.items == b.items && a.typed == b.typed }

    /// The label of the target with this key (in `pane`), for tests and --dump.
    public func label(_ pane: String, _ key: String) -> String? { items.first { $0.pane == pane && $0.key == key }?.label }
}

extension AppModel {
    /// `g w` / `f`: label every visible target in every visible pane, and wait for one.
    func showLabels() throws {
        let ts = provider?.targets(self) ?? visibleTargets()
        let order = panes.sorted { ($0.column, $0.row) < ($1.column, $1.row) }.map(\.id)
        let labels = Labels.assign(ts.map(\.spot), paneOrder: order)
        var items: [LabelSession.Item] = []
        var kept: [LabelTarget] = []
        for (t, l) in zip(ts, labels) {
            guard let l else { continue }
            items.append(.init(label: l, pane: t.pane, key: t.key, rect: t.rect, title: t.title))
            kept.append(t)
        }
        guard !items.isEmpty else { throw Refusal("nothing on screen to label") }
        labeling = LabelSession(items: items, targets: kept)
        keys.openLayer(.labels)
    }

    /// A key in the label layer: a label picks, a label's start waits, anything else cancels.
    func labelKey(_ k: String) -> Bool {
        guard var s = labeling else { return false }
        s.typed += k
        if let i = s.items.firstIndex(where: { $0.label == s.typed }) {
            let t = s.targets[i]
            keys.closeLayer()
            pickTarget(t)
            return true
        }
        if s.items.contains(where: { $0.label.hasPrefix(s.typed) }) {
            labeling = s
            return true
        }
        keys.closeLayer()
        return true
    }

    /// Do what `ret` on that target does — a jump. In select mode it only moves the cursor, so the
    /// range extends to it.
    public func pickTarget(_ t: LabelTarget) {
        let extending = keys.mode == .select
        jump {
            if let p = panes.first(where: { $0.id == t.pane }), p.rows.contains(t.key) {
                focus(pane: p.id)
                setCursor(t.key)
                if extending { return }
                if let run = t.run {
                    runner.dispatch(run.id, via: .key, target: run.target, arg: run.arg)
                } else if provider?.primary(for: t.key, self) != nil {
                    runner.dispatch("pane.open", via: .key, target: t.key)
                }
            } else if let run = t.run {
                runner.dispatch(run.id, via: .key, target: run.target, arg: run.arg)
            }
        }
    }

    /// One jump: remember where we are once, then move — whatever records inside is the same jump.
    public func jump(_ body: () -> Void) {
        recordJump()
        jumpDepth += 1
        defer { jumpDepth -= 1 }
        body()
    }

    /// Remember where we are as a jump's origin (unless a jump is already under way).
    public func recordJump() {
        guard jumpDepth == 0 else { return }
        jumps.record(here())
    }
}

/// The one label renderer: small pills at each target's leading edge, beside rather than over it;
/// pills that no longer match what's typed fade.
struct LabelsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let s = app.labeling {
            GeometryReader { g in
                let origin = g.frame(in: .global).origin
                ZStack(alignment: .topLeading) {
                    ForEach(Array(s.items.enumerated()), id: \.offset) { _, it in
                        let live = it.label.hasPrefix(s.typed)
                        HStack(spacing: 0) {
                            Text(String(it.label.prefix(s.typed.count))).foregroundStyle(theme.inkFaint)
                            Text(String(it.label.dropFirst(s.typed.count))).foregroundStyle(theme.vellumNight)
                        }
                        .font(Theme.mono(10.5, weight: .semibold))
                        .padding(.horizontal, 3)
                        .background(live ? theme.goldLeaf : theme.inkFaint.opacity(0.4))
                        .fixedSize()
                        .opacity(live ? 1 : 0.25)
                        .offset(x: max(0, it.rect.minX - origin.x - 4), y: it.rect.minY - origin.y + 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .allowsHitTesting(false)
        }
    }
}
