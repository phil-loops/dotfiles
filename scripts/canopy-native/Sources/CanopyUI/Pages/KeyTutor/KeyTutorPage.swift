import CanopyCore
import SwiftUI

/// The keytutor's page: the lesson on the left (its steps, the one you're on with your keys in it,
/// a hint after a couple of misses, the recap), the practice app on the right — a whole canopy,
/// drawn by its own RootView, every key going to it.
struct KeyTutorPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let t = KeyTutor.of(app)
        if t.host != nil {
            Text("you're practicing inside the keytutor already — esc leaves it")
                .foregroundStyle(theme.inkFaint).padding(16)
        } else {
            HStack(alignment: .top, spacing: 0) {
                lessonPane(t)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(theme.rule).frame(width: 1)
                practice(t)
            }
        }
    }

    @ViewBuilder private func practice(_ t: KeyTutor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("practice — nothing here reaches git, the server or GitHub")
                .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint).padding(.horizontal, 16).padding(.vertical, 4)
            if let sb = t.sandbox {
                RootView()
                    .environment(sb)
                    .overlay(Rectangle().stroke(theme.goldDeep.opacity(0.6), lineWidth: 1))
            } else {
                Text("setting up the practice canopy…").foregroundStyle(theme.inkFaint).padding(16)
                    .onAppear { t.ensureSandbox() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lessonPane(_ t: KeyTutor) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("keytutor").font(Theme.display(22)).foregroundStyle(theme.goldLeaf)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(KeyTutor.lessons.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 6) {
                            Text(t.done.contains(l.id) ? "✓" : i == t.lessonIndex ? "▸" : " ").frame(width: 12)
                            Text(l.title)
                        }
                        .font(Theme.mono(11.5))
                        .foregroundStyle(i == t.lessonIndex ? theme.ink : t.done.contains(l.id) ? theme.inkDim : theme.inkFaint)
                    }
                }
                Rectangle().fill(theme.rule).frame(height: 1)
                if t.recapping || t.finished {
                    Text(t.finished ? "done" : "\(t.lesson.title) — recap").font(Theme.display(17)).foregroundStyle(theme.goldLeaf)
                    pieces(t.render(t.lesson.recap))
                    if !t.finished {
                        HStack(spacing: 0) {
                            Text(t.keyOf(.main)).foregroundStyle(theme.goldLeaf)
                            Text(" or ").foregroundStyle(theme.inkFaint)
                            Text(t.keyOf(.next)).foregroundStyle(theme.goldLeaf)
                            Text(" goes on").foregroundStyle(theme.inkFaint)
                        }
                        .font(Theme.mono(11))
                    }
                } else if let s = t.step {
                    Text("\(t.lesson.title) · \(t.stepIndex + 1)/\(t.lesson.steps.count)").font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
                    pieces(t.render(s.text))
                    if let h = t.hint {
                        Text(h).font(Theme.mono(11.5)).foregroundStyle(theme.goldLeaf)
                    }
                    if !t.ready { Text("setting the scene…").font(Theme.mono(11)).foregroundStyle(theme.inkFaint) }
                }
                if let said = t.said { Text(said).font(Theme.mono(11)).foregroundStyle(theme.patina).lineLimit(2) }
                Rectangle().fill(theme.rule).frame(height: 1)
                pieces(t.render("{leader} k s skips a step · {leader} k n / p next / previous lesson · {leader} k l lessons · esc with nothing to cancel leaves"))
                    .font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Text with keys drawn as keycaps, wrapping as prose.
    private func pieces(_ ps: [KeyTutorPiece]) -> Text {
        ps.reduce(Text("")) { acc, p in
            acc + (p.key ? Text(" \(p.text) ").foregroundColor(theme.goldLeaf).bold() : Text(p.text).foregroundColor(theme.ink))
        }
        .font(Theme.mono(13))
    }
}
