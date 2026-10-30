import AppKit

final class Renderer {
    let base = NSFont.systemFont(ofSize: 14)
    let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    /// Where relative image paths resolve, and how wide an image may draw.
    var baseDirectory = decksDirectory
    var columnWidth: CGFloat = 640
    /// Live's **d**: a compare table shows only the rows whose models disagree.
    var onlyDifferingRows = false

    func render(_ section: Section) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(line(eyebrow(section), font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor, after: 4))
        out.append(line(section.title, font: .systemFont(ofSize: 26, weight: .bold), color: .labelColor, after: section.tag == nil ? 14 : 4))
        if let tag = section.tag {
            out.append(line(tag, font: mono, color: .systemBlue, after: 14))
        }
        out.append(markdown(section.body ?? ""))
        out.append(liveData(section))
        return out
    }

    private func line(_ text: String, font: NSFont, color: NSColor, after: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        return NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private func markdown(_ body: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lines = body.components(separatedBy: "\n")[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") {
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()
                out.append(block(code.joined(separator: "\n")))
            } else if text.hasPrefix("|") {
                var rows = [text]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next.trimmingCharacters(in: .whitespaces))
                    lines = lines.dropFirst()
                }
                out.append(table(rows))
            } else if let image = imageLine(text) {
                out.append(picture(path: image.path, alt: image.alt))
            } else if text.hasPrefix("## ") {
                out.append(paragraph(String(text.dropFirst(3)), font: .systemFont(ofSize: 17, weight: .semibold), before: 10, after: 6))
            } else if text.hasPrefix("# ") {
                out.append(paragraph(String(text.dropFirst(2)), font: .systemFont(ofSize: 20, weight: .bold), before: 12, after: 8))
            } else if text.hasPrefix("- ") {
                out.append(listItem(marker: "•", String(text.dropFirst(2)), indent: raw.prefix { $0 == " " }.count))
            } else if let match = text.range(of: #"^\d+\. "#, options: .regularExpression) {
                out.append(listItem(marker: String(text[match]).trimmingCharacters(in: .whitespaces), String(text[match.upperBound...]), indent: raw.prefix { $0 == " " }.count))
            } else if text.hasPrefix("> ") {
                out.append(quote(String(text.dropFirst(2))))
            } else if !text.isEmpty {
                out.append(paragraph(text, font: base, after: 10))
            }
        }
        return out
    }

    private func paragraph(_ text: String, font: NSFont, color: NSColor = .labelColor, head: CGFloat = 0, before: CGFloat = 0, after: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = after
        p.paragraphSpacingBefore = before
        p.lineSpacing = 3
        p.firstLineHeadIndent = head
        p.headIndent = head
        let s = inline(text, font: font, color: color)
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    private func quote(_ text: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 14
        p.paragraphSpacingBefore = 4
        p.lineSpacing = 4
        p.firstLineHeadIndent = 18
        p.headIndent = 18
        let s = inline(text, font: .systemFont(ofSize: 19, weight: .semibold), color: .labelColor)
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    private func listItem(marker: String, _ text: String, indent: Int) -> NSAttributedString {
        let left = CGFloat(8 + indent * 8)
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 5
        p.lineSpacing = 3
        p.firstLineHeadIndent = left
        p.headIndent = left + 22
        p.tabStops = [NSTextTab(textAlignment: .left, location: left + 22)]
        let s = NSMutableAttributedString(string: marker + "\t", attributes: [.font: base, .foregroundColor: NSColor.secondaryLabelColor])
        s.append(inline(text, font: base, color: .labelColor))
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// A fenced block as one panel: one text block holds every line, and lines sit flush so box-drawing joins up.
    private func block(_ code: String) -> NSAttributedString {
        let panel = NSTextBlock()
        panel.backgroundColor = NSColor(name: "show.codePanel") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
        }
        panel.setValue(100, type: .percentageValueType, for: .width)
        panel.setWidth(14, type: .absoluteValueType, for: .padding)
        panel.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let p = NSMutableParagraphStyle()
        p.textBlocks = [panel]
        p.paragraphSpacing = 0
        p.paragraphSpacingBefore = 0
        p.lineSpacing = 0
        p.lineHeightMultiple = 1.0
        let height = ceil(mono.ascender - mono.descender)
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        return NSAttributedString(string: code + "\n", attributes: [.font: mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
    }

    private func imageLine(_ text: String) -> (alt: String, path: String)? {
        guard let match = try? NSRegularExpression(pattern: #"^!\[(.*)\]\((.+)\)$"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let alt = Range(match.range(at: 1), in: text), let path = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[alt]), String(text[path]))
    }

    /// `![alt](path)` on its own line: the image at its natural size, shrunk to the column but never enlarged, captioned by its alt text.
    private func picture(path: String, alt: String) -> NSAttributedString {
        let expanded = (path as NSString).expandingTildeInPath
        let file = expanded.hasPrefix("/") ? expanded : (baseDirectory as NSString).appendingPathComponent(expanded)
        guard let image = NSImage(contentsOfFile: file) else {
            return paragraph("Missing image: \(path)", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, after: 10)
        }
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            let scale: CGFloat = (file as NSString).deletingPathExtension.hasSuffix("@2x") ? 2 : 1
            image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        let fit = min(1, columnWidth / max(image.size.width, 1))
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: floor(image.size.width * fit), height: floor(image.size.height * fit))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = alt.isEmpty ? 12 : 4
        p.paragraphSpacingBefore = 4
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        if !alt.isEmpty {
            out.append(paragraph(alt, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, after: 14))
        }
        return out
    }

    /// A pipe table as a real text table: hairline cells sized to their content, the first row as the header.
    private func table(_ rows: [String]) -> NSAttributedString {
        grid(rows
            .filter { !$0.replacingOccurrences(of: #"[|\-: ]"#, with: "", options: .regularExpression).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } })
    }

    /// Rows of cells as a real text table, the first row as the header; `style` colors a cell's text and fills its background.
    func grid(_ cells: [[String]], style: (_ row: Int, _ column: Int) -> (text: NSColor, fill: NSColor?) = { _, _ in (.labelColor, nil) }) -> NSAttributedString {
        let columns = cells.map(\.count).max() ?? 0
        let header = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        var widths = (0..<columns).map { c in
            cells.enumerated().map { r, row in
                c < row.count ? ceil(inline(row[c], font: r == 0 ? header : base, color: .labelColor).size().width) : 0
            }.max() ?? 0
        }
        let chrome = CGFloat(columns) * 21
        let natural = widths.reduce(0, +) + chrome
        if natural > columnWidth {
            let floors = (0..<columns).map { c in
                cells.enumerated().flatMap { r, row in
                    c < row.count ? row[c].split(separator: " ").map { ceil(inline(String($0), font: r == 0 ? header : base, color: .labelColor).size().width) + 6 } : []
                }.max() ?? 0
            }
            let room = columnWidth - chrome - floors.reduce(0, +)
            let stretch = widths.enumerated().map { c, width in max(0, width - floors[c]) }.reduce(0, +)
            let share = room > 0 && stretch > 0 ? room / stretch : 0
            widths = widths.enumerated().map { c, width in floor(floors[c] + max(0, width - floors[c]) * share) }
        }
        let grid = NSTextTable()
        grid.numberOfColumns = columns
        grid.layoutAlgorithm = .fixedLayoutAlgorithm
        grid.setValue(widths.reduce(0, +) + chrome, type: .absoluteValueType, for: .width)
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        grid.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let out = NSMutableAttributedString()
        for (r, row) in cells.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setValue(widths[c], type: .absoluteValueType, for: .width)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                let look = style(r, c)
                cell.backgroundColor = look.fill
                let p = NSMutableParagraphStyle()
                p.textBlocks = [cell]
                p.lineSpacing = 2
                let font = r == 0 ? header : base
                let text = inline(c < row.count ? row[c] : "", font: font, color: look.text)
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: text.length))
                out.append(text)
            }
        }
        return out
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*\*|`"#, with: "", options: .regularExpression)
    }

    private func inline(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intent.contains(.code) {
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
            }
            if let link = run.link {
                attributes[.link] = link
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

extension Renderer {
    func tutorMarkdown(_ text: String) -> NSAttributedString { markdown(text) }

    func tutorInline(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        let out = inline(text, font: font, color: color)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }
}

func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: lhs)
    out.append(rhs)
    return out
}
