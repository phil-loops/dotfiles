import SwiftUI

/// How a page's prose lights what the keys point at: the link under the page's cursor, the
/// citation open beside the page (v2's `wk-on`), the block the cursor rests on.
struct ProseLook {
    var theme: Theme
    var cursorLink: Int?
    var openAnchor: String?
    var cursorBlock: Int?
    var size: CGFloat = 15.5

    var serif: Font { Font.custom("Georgia", size: size) }
}

/// The wiki's prose (v2.css `.md.wk-prose`): Georgia body, Fraunces headings, mono code, gold
/// citations underlined dotted, patina page links. Each top-level block carries the id "blk-<i>"
/// so the page can keep the cursor's block on screen.
struct ProseView: View {
    let doc: ProseDoc
    let look: ProseLook

    var body: some View {
        VStack(alignment: .leading, spacing: look.size * 0.9) {
            ForEach(Array(doc.blocks.enumerated()), id: \.offset) { i, b in
                ProseBlockView(block: b, look: look)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { (look.cursorBlock == i ? look.theme.goldLeaf : .clear).frame(width: 2) }
                    .id("blk-\(i)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProseBlockView: View {
    let block: ProseBlock
    let look: ProseLook

    var body: some View {
        let t = look.theme
        switch block {
        case .para(let ins):
            text(ins)
        case .heading(_, let ins):
            Text(ProseText.attributed(ins, look, font: Theme.display(19))).foregroundStyle(t.ink).padding(.top, look.size * 0.6)
        case .rule:
            t.rule.frame(height: 1)
        case .code(let s):
            ScrollView(.horizontal) {
                Text(s).font(Theme.mono(12.5)).lineSpacing(3).foregroundStyle(t.diffInk).fixedSize().padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(t.diffBg)
            .overlay { Rectangle().stroke(t.rule, lineWidth: 1) }
        case .quote(let bs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bs.enumerated()), id: \.offset) { _, b in ProseBlockView(block: b, look: look) }
            }
            .foregroundStyle(t.inkDim)
            .padding(.leading, 10)
            .overlay(alignment: .leading) { t.rule.frame(width: 2) }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: look.size * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.task ? "" : ordered ? "\(start + n)." : "•").font(look.serif).foregroundStyle(t.inkFaint)
                            .frame(minWidth: 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: look.size * 0.35) {
                            if !item.head.isEmpty { text(item.head) }
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, b in ProseBlockView(block: b, look: look) }
                        }
                    }
                }
            }
        case .table(let head, let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { _, c in
                        Text(Prose.text(c).uppercased()).font(Theme.mono(11)).tracking(1.1).foregroundStyle(t.inkFaint)
                    }
                }
                Divider().overlay(t.rule)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(ProseText.attributed(c, look, font: Font.custom("Georgia", size: look.size * 0.86))).foregroundStyle(t.ink)
                        }
                    }
                    Divider().overlay(t.rule)
                }
            }
        case .suggestion(let lines):
            VStack(alignment: .leading, spacing: 0) {
                Text("Suggested change").font(Theme.mono(11)).foregroundStyle(t.inkFaint).padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading).background(t.vellumEdge)
                if lines.isEmpty { Text("(removes the lines)").foregroundStyle(t.inkFaint).padding(.horizontal, 8) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 0) {
                        Text(l.sign).foregroundStyle(t.inkFaint).frame(width: 18)
                        Text(l.text)
                    }
                    .font(Theme.mono(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(l.sign == "-" ? t.delBg : t.addBg)
                }
            }
            .overlay { Rectangle().stroke(t.rule, lineWidth: 1) }
        }
    }

    private func text(_ ins: [ProseInline]) -> some View {
        Text(ProseText.attributed(ins, look, font: look.serif)).lineSpacing(look.size * 0.45).foregroundStyle(look.theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum ProseText {
    /// Inlines as one attributed run, links styled by kind and lit when the keys point at them.
    static func attributed(_ ins: [ProseInline], _ look: ProseLook, font: Font) -> AttributedString {
        var out = AttributedString()
        append(ins, look, font: font, style: [], link: nil, into: &out)
        return out
    }

    private static func append(_ ins: [ProseInline], _ look: ProseLook, font: Font, style: ProseStyle, link: ProseLink?, into out: inout AttributedString) {
        let t = look.theme
        for i in ins {
            switch i {
            case .br:
                out.append(AttributedString("\n"))
            case .link(let l, let kids):
                append(kids, look, font: font, style: style, link: l, into: &out)
            case .text(let s, let st):
                var a = AttributedString(s)
                let all = st.union(style)
                var f = all.contains(.code) ? Theme.mono(look.size * 0.82) : font
                if all.contains(.bold) { f = f.weight(.semibold) }
                if all.contains(.italic) { f = f.italic() }
                a.font = f
                if all.contains(.bold) { a.foregroundColor = t.goldLeaf }
                if all.contains(.at) { a.foregroundColor = t.inkDim }
                if all.contains(.del) { a.strikethroughStyle = .single }
                if all.contains(.code) { a.backgroundColor = t.vellumEdge }
                if let l = link {
                    let lit = look.cursorLink == l.n
                    switch l.kind {
                    case .cite(let anchor):
                        a.foregroundColor = t.goldLeaf
                        a.underlineStyle = Text.LineStyle(pattern: lit || look.openAnchor == anchor ? .solid : .dot, color: t.goldDeep)
                        if lit || look.openAnchor == anchor { a.backgroundColor = t.goldWash }
                    case .page:
                        a.foregroundColor = t.patina
                        if lit { a.underlineStyle = Text.LineStyle(pattern: .solid, color: t.patina) }
                    case .url:
                        a.foregroundColor = t.goldLeaf
                        if lit { a.underlineStyle = Text.LineStyle(pattern: .solid, color: t.goldLeaf) }
                    }
                    if lit { a.backgroundColor = t.goldWash }
                }
                out.append(a)
            }
        }
    }
}
