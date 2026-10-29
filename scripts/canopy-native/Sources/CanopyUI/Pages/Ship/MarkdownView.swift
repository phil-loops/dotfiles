import CanopyCore
import SwiftUI

/// Markdown drawn in the app's type: `MarkdownView("**hi**")`. The parsing is `Markdown.parse`;
/// this only draws its blocks. Links open in the browser when clicked, and are always visible text
/// (the URL a bare link shows, the words a [text](url) link shows) — never hover-only.
public struct MarkdownView: View {
    @Environment(\.theme) private var theme
    let blocks: [MdBlock]
    let size: CGFloat

    public init(_ text: String, replaces: [String] = [], size: CGFloat = 12.5) {
        blocks = Markdown.parse(text, replaces: replaces)
        self.size = size
    }

    public init(blocks: [MdBlock], size: CGFloat = 12.5) {
        self.blocks = blocks
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: MdBlock) -> some View {
        switch b {
        case .paragraph(let lines):
            Text(Self.attributed(lines, theme: theme, size: size)).font(Theme.mono(size)).foregroundStyle(theme.ink).textSelection(.enabled)
        case .heading(let level, let line):
            Text(Self.attributed([line], theme: theme, size: size)).font(Theme.mono(size + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold))
                .foregroundStyle(theme.ink)
        case .code(_, let lines):
            Text(lines.joined(separator: "\n")).font(Theme.mono(size - 0.5)).foregroundStyle(theme.diffInk)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(theme.diffBg).textSelection(.enabled)
        case .suggestion(let removes, let adds):
            VStack(alignment: .leading, spacing: 0) {
                Text("Suggested change").font(Theme.mono(size - 1.5)).foregroundStyle(theme.inkFaint).padding(.bottom, 2)
                ForEach(Array(removes.enumerated()), id: \.offset) { _, l in
                    Text("- \(l.isEmpty ? " " : l)").font(Theme.mono(size - 0.5)).foregroundStyle(theme.del)
                        .frame(maxWidth: .infinity, alignment: .leading).background(theme.delBg)
                }
                ForEach(Array(adds.enumerated()), id: \.offset) { _, l in
                    Text("+ \(l.isEmpty ? " " : l)").font(Theme.mono(size - 0.5)).foregroundStyle(theme.add)
                        .frame(maxWidth: .infinity, alignment: .leading).background(theme.addBg)
                }
                if adds.isEmpty { Text("(removes the lines)").font(Theme.mono(size - 1.5)).foregroundStyle(theme.inkFaint) }
            }
            .padding(6).overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
        case .rule:
            theme.rule.frame(height: 1).padding(.vertical, 2)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                theme.rule.frame(width: 2)
                MarkdownView(blocks: inner, size: size).foregroundStyle(theme.inkDim)
            }
        case .table(let head, let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow { ForEach(Array(head.enumerated()), id: \.offset) { _, c in Text(Self.attributed([c], theme: theme, size: size)).font(Theme.mono(size, weight: .semibold)) } }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Text(Self.attributed([c], theme: theme, size: size)).font(Theme.mono(size)) } }
                }
            }
            .foregroundStyle(theme.ink)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.task.map { $0 ? "☑" : "☐" } ?? (ordered ? "\(start + i)." : "•"))
                            .font(Theme.mono(size)).foregroundStyle(theme.inkFaint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.attributed([it.text], theme: theme, size: size)).font(Theme.mono(size)).foregroundStyle(theme.ink)
                            if !it.children.isEmpty { MarkdownView(blocks: it.children, size: size) }
                        }
                    }
                }
            }
        }
    }

    /// Lines of spans as one attributed string (hard breaks between lines).
    public static func attributed(_ lines: [MdLine], theme: Theme, size: CGFloat = 12.5) -> AttributedString {
        var out = AttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(AttributedString("\n")) }
            for s in line {
                var a = AttributedString(s.text)
                var font = Theme.mono(size, weight: s.bold ? .semibold : .regular)
                if s.italic { font = font.italic() }
                a.font = font
                if s.strike { a.strikethroughStyle = .single }
                if s.code { a.backgroundColor = theme.diffBg; a.foregroundColor = theme.diffInk }
                if s.mention { a.foregroundColor = theme.goldLeaf }
                if let l = s.link, let u = URL(string: l) { a.link = u; a.foregroundColor = theme.goldLeaf; a.underlineStyle = .single }
                out.append(a)
            }
        }
        return out
    }
}
