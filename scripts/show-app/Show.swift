// Show — one native window with four workspaces on a rail: Forest (⌘1), Review (⌘2), Learn (⌘3), Runs (⌘4).
// A file goes to the workspace its optional "workspace" key names, otherwise to the one its "mode" implies (forest, deck, tutor, live).
// Decks: { "title", "subtitle"?, "sections": [{ "id"?, "group", "title", "tag"?, "body" (markdown), "url"? (a live page shown instead of the body) }] }
// Sign-offs and notes save beside the deck as <deck>.signoff.json; "replyTo" names the claude-say session that Submit notifies.
// Learn reads a { "mode": "tutor", … } session file and writes answers beside it as <session>.answers.json.
import AppKit
import UniformTypeIdentifiers
import WebKit

struct Deck: Decodable {
    let title: String
    let subtitle: String?
    let replyTo: String?
    let mode: String?
    let status: LiveStatus?
    let project: String?
    let repo: String?
    let sections: [Section]

    /// A live deck is watched, not judged: no sign-off bar, no sign-off file, no sign-off marks.
    var isLive: Bool { mode == "live" }
    var isForest: Bool { mode == "forest" }
}

/// A live deck's optional run status, shown as one quiet line above the page.
struct LiveStatus: Decodable {
    let state: String?
    let done: Int?
    let total: Int?
    let current: String?

    func line(changed: Date?) -> String {
        var parts: [String] = []
        if let state, !state.isEmpty {
            parts.append(state.prefix(1).uppercased() + state.dropFirst())
        }
        if let done, let total {
            parts.append("\(done) of \(total)")
        } else if let done {
            parts.append("\(done) done")
        }
        if let current, !current.isEmpty {
            parts.append("now: \(current)")
        }
        if let changed {
            parts.append("updated \(sinceText(changed))")
        }
        return parts.joined(separator: " · ")
    }
}

func sinceText(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
}

struct Section: Decodable {
    let id: String?
    let group: String
    let title: String
    let tag: String?
    let body: String?
    let url: String?
    let rank: Int?
    let parent: String?

    var key: String { id ?? title }
}

struct SignOff: Codable {
    var signed: Bool
    var note: String
    var at: String
}

final class SignOffStore {
    let url: URL
    private(set) var entries: [String: SignOff]

    init(deckPath: String) {
        url = URL(fileURLWithPath: deckPath).deletingPathExtension().appendingPathExtension("signoff.json")
        entries = (try? JSONDecoder().decode([String: SignOff].self, from: Data(contentsOf: url))) ?? [:]
    }

    func update(_ key: String, _ change: (inout SignOff) -> Void) {
        var entry = entries[key] ?? SignOff(signed: false, note: "", at: "")
        change(&entry)
        entry.at = ISO8601DateFormatter().string(from: Date())
        entries[key] = entry
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }
}

enum Row {
    case header(String)
    case item(Int)
}

final class Renderer {
    let base = NSFont.systemFont(ofSize: 14)
    let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    /// Where relative image paths resolve, and how wide an image may draw.
    var baseDirectory = decksDirectory
    var columnWidth: CGFloat = 640

    func render(_ section: Section) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(line(section.group, font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor, after: 4))
        out.append(line(section.title, font: .systemFont(ofSize: 26, weight: .bold), color: .labelColor, after: section.tag == nil ? 14 : 4))
        if let tag = section.tag {
            out.append(line(tag, font: mono, color: .systemBlue, after: 14))
        }
        out.append(markdown(section.body ?? ""))
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
        let cells = rows
            .filter { !$0.replacingOccurrences(of: #"[|\-: ]"#, with: "", options: .regularExpression).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
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
            let shrink = max(0.1, (columnWidth - chrome) / max(natural - chrome, 1))
            widths = widths.map { floor($0 * shrink) }
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
                let p = NSMutableParagraphStyle()
                p.textBlocks = [cell]
                p.lineSpacing = 2
                let font = r == 0 ? header : base
                let text = inline(c < row.count ? row[c] : "", font: font, color: .labelColor)
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

func loadDeck(_ path: String) throws -> Deck {
    try JSONDecoder().decode(Deck.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

/// The launcher writes this after a successful build, so a change means a newer Show is ready.
let buildStamp = ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("source.sha")

/// Where decks live; `SHOW_DIR` points a scratch build at fixtures instead.
let decksDirectory = ((ProcessInfo.processInfo.environment["SHOW_DIR"] ?? "~/.dotfiles/show") as NSString).expandingTildeInPath

/// Remembered selections, drafts and open documents; a snapshot run keeps its own so it never touches the real app's.
var prefs = UserDefaults.standard

/// A section-list row whose selection is a soft rounded fill, with an accent outline while the list has keyboard focus.
final class QuietRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        shape.fill()
        if isEmphasized {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
    }
}

/// One deck: its section list beside the rendered section and the sign-off bar. It owns no window; its workspace hosts `viewController`.
final class DeckController: NSObject, WKNavigationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let path: String
    var deck: Deck
    var rows: [Row] = []
    var store: SignOffStore
    let renderer = Renderer()
    let viewController = NSSplitViewController()
    let table = NSTableView()
    let text = NSTextView()
    var textScroll: NSScrollView!
    let web = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }())
    let signed = NSButton(checkboxWithTitle: "Signed off", target: nil, action: nil)
    let note = NSTextField()
    let progress = NSTextField(labelWithString: "")
    let submit = NSButton(title: "Submit", target: nil, action: nil)
    let statusLine = NSTextField(labelWithString: "")
    var actionBar: NSView!
    var actionDivider: NSView!
    var deckModified: Date?
    var onTitleChange: (() -> Void)?

    init(path: String, deck: Deck) {
        self.path = path
        self.deck = deck
        store = SignOffStore(deckPath: path)
        renderer.baseDirectory = (path as NSString).deletingLastPathComponent
        super.init()
        let sidebar = NSSplitViewItem(viewController: sidebarController())
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 360
        sidebar.preferredThicknessFraction = 0.28
        viewController.addSplitViewItem(sidebar)
        viewController.addSplitViewItem(NSSplitViewItem(viewController: detailController()))
        viewController.splitView.autosaveName = "show.deck.sections"
        deckModified = modificationDate(path)
        apply(deck, keepingSelection: prefs.string(forKey: selectionKey))
    }

    var window: NSWindow? { viewController.view.window }
    var title: String { deck.title }
    var subtitle: String {
        if deck.isLive { return deck.subtitle ?? "" }
        let done = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
        return [deck.subtitle, "\(done) of \(deck.sections.count) signed off"].compactMap { $0 }.joined(separator: " · ")
    }

    var selectionKey: String { "selected." + path }

    var selectedSection: Section? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, case .item(let i) = rows[table.selectedRow] else { return nil }
        return deck.sections[i]
    }

    /// Re-reads the deck and its sign-offs from disk, keeping the selected section, its scroll and a note being typed.
    func reload() {
        deckModified = modificationDate(path)
        saveNote()
        guard let fresh = try? loadDeck(path) else { return }
        let kept = selectedSection?.key
        let cursor = note.currentEditor()?.selectedRange
        let origin = textScroll.contentView.bounds.origin
        let listOrigin = (table.enclosingScrollView?.contentView.bounds.origin) ?? .zero
        store = SignOffStore(deckPath: path)
        apply(fresh, keepingSelection: kept)
        if let list = table.enclosingScrollView {
            list.contentView.scroll(to: list.contentView.constrainBoundsRect(NSRect(origin: listOrigin, size: list.contentView.bounds.size)).origin)
            list.reflectScrolledClipView(list.contentView)
        }
        if selectedSection?.key == kept {
            if let container = text.textContainer {
                text.layoutManager?.ensureLayout(for: container)
            }
            let clip = textScroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            textScroll.reflectScrolledClipView(clip)
            if let cursor {
                window?.makeFirstResponder(note)
                let length = (note.stringValue as NSString).length
                note.currentEditor()?.selectedRange = NSRange(location: min(cursor.location, length), length: min(cursor.length, max(0, length - cursor.location)))
            }
        }
    }

    func reloadIfChanged() {
        if modificationDate(path) != deckModified {
            reload()
        }
    }

    private func apply(_ deck: Deck, keepingSelection key: String?) {
        self.deck = deck
        rows = []
        var lastGroup: String?
        for (i, section) in deck.sections.enumerated() {
            if section.group != lastGroup {
                rows.append(.header(section.group))
                lastGroup = section.group
            }
            rows.append(.item(i))
        }
        table.reloadData()
        let kept = rows.firstIndex { if case .item(let i) = $0 { return deck.sections[i].key == key } else { return false } }
        let first = rows.firstIndex { if case .item = $0 { return true } else { return false } }
        if let row = kept ?? first {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        }
        updateProgress()
    }

    /// Selects a section by id, the way `SHOW_SNAPSHOT_SECTION` asks.
    func select(section key: String) {
        guard let row = rows.firstIndex(where: { if case .item(let i) = $0 { return deck.sections[i].key == key } else { return false } }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Re-renders the selected section at the laid-out width, sized to its full height, for a snapshot.
    func prepareSnapshot() {
        guard let section = selectedSection, section.url == nil else { return }
        renderer.columnWidth = text.bounds.width > 300 ? text.bounds.width - 96 : 640
        text.textStorage?.setAttributedString(renderer.render(section))
        if let container = text.textContainer {
            text.layoutManager?.ensureLayout(for: container)
        }
    }

    private func sidebarController() -> NSViewController {
        let column = NSTableColumn(identifier: .init("section"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        progress.font = .systemFont(ofSize: 11, weight: .medium)
        progress.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [scroll, progress])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progress.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18).isActive = true
        let vc = NSViewController()
        vc.view = ListBackdrop(stack)
        return vc
    }

    private func detailController() -> NSViewController {
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 48, height: 32)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        textScroll = scroll
        web.isHidden = true
        web.navigationDelegate = self
        let page = NSView()
        for view in [scroll, web] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: page.topAnchor),
                view.bottomAnchor.constraint(equalTo: page.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            ])
        }
        page.setContentHuggingPriority(.init(1), for: .vertical)

        signed.target = self
        signed.action = #selector(toggleSigned)
        signed.font = .systemFont(ofSize: 13, weight: .semibold)
        note.placeholderString = "Note or pushback — saved when you press Return or move on"
        note.font = .systemFont(ofSize: 13)
        note.delegate = self
        note.target = self
        note.action = #selector(saveNote)
        submit.target = self
        submit.action = #selector(submitReview)
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        submit.keyEquivalentModifierMask = [.command]
        submit.toolTip = "Tell Claude you're done (⌘↩)"
        let bar = NSStackView(views: [signed, note, submit])
        bar.orientation = .horizontal
        bar.spacing = 14
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 48, bottom: 12, right: 24)
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator
        actionBar = bar
        actionDivider = divider

        statusLine.font = .systemFont(ofSize: 12, weight: .medium)
        statusLine.textColor = .secondaryLabelColor
        statusLine.lineBreakMode = .byTruncatingTail
        let status = NSStackView(views: [statusLine])
        status.edgeInsets = NSEdgeInsets(top: 14, left: 53, bottom: 0, right: 24)
        status.isHidden = true

        let stack = NSStackView(views: [status, page, divider, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [status, page, divider, bar] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let vc = NSViewController()
        vc.view = stack
        return vc
    }

    @objc private func toggleSigned() {
        guard !deck.isLive, let section = selectedSection else { return }
        store.update(section.key) { $0.signed = signed.state == .on }
        reloadSelectedRow()
    }

    @objc func saveNote() {
        guard !deck.isLive, let section = selectedSection else { return }
        let value = note.stringValue
        guard (store.entries[section.key]?.note ?? "") != value else { return }
        store.update(section.key) { $0.note = value }
        reloadSelectedRow()
    }

    @objc private func submitReview() {
        guard !deck.isLive else { return }
        saveNote()
        let signedCount = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
        let notes = deck.sections.filter { store.entries[$0.key]?.note.isEmpty == false }.count
        guard let replyTo = deck.replyTo else {
            submit.title = "Submitted"
            return
        }
        let message = "Show: \"\(deck.title)\" submitted — \(signedCount)/\(deck.sections.count) signed off, \(notes) notes. Read \(store.url.path)"
        if let failure = claudeSay(replyTo, message) {
            showSubmitFailure(failure)
            return
        }
        submit.title = "Submitted ✓"
    }

    private func showSubmitFailure(_ detail: String) {
        showClaudeSayFailure(replyTo: deck.replyTo, saved: "Your sign-offs are saved.", detail: detail, window: window)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showPageError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showPageError(error)
    }

    private func showPageError(_ error: Error) {
        let address = selectedSection?.url ?? ""
        web.loadHTMLString("<body style='font: 14px -apple-system; padding: 40px; color: #888'><h3>Couldn't load \(address)</h3><p>\(error.localizedDescription)</p><p>Is the server running?</p></body>", baseURL: nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveNote()
    }

    func controlTextDidChange(_ obj: Notification) {
        saveNote()
    }

    private func reloadSelectedRow() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateProgress()
    }

    private func updateProgress() {
        actionBar.isHidden = deck.isLive
        actionDivider.isHidden = deck.isLive
        progress.isHidden = deck.isLive
        updateStatusLine()
        if deck.isLive {
            onTitleChange?()
            return
        }
        let total = deck.sections.count
        let done = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
        progress.stringValue = "\(done) of \(total) signed off"
        onTitleChange?()
    }

    /// Refreshes the live status line, including how long ago the file changed; ticks once a second.
    func updateStatusLine() {
        let line = deck.isLive ? deck.status?.line(changed: deckModified) : nil
        statusLine.superview?.isHidden = line == nil
        statusLine.stringValue = line ?? ""
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 28
        case .item(let i): return deck.sections[i].tag == nil ? 32 : 44
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        saveNote()
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = QuietRowView()
        rowView.selectionHighlightStyle = .none
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let group):
            let label = NSTextField(labelWithString: group)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .item(let i):
            let section = deck.sections[i]
            let entry = deck.isLive ? nil : store.entries[section.key]
            let mark = entry?.signed == true ? "✓ " : (entry?.note.isEmpty == false ? "✎ " : "")
            let title = NSTextField(labelWithString: mark + section.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [title])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            if let tag = section.tag {
                let sub = NSTextField(labelWithString: tag)
                sub.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                sub.textColor = .secondaryLabelColor
                sub.lineBreakMode = .byTruncatingTail
                stack.addArrangedSubview(sub)
            }
            let cell = NSTableCellView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            for view in stack.arrangedSubviews {
                view.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -16).isActive = true
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let section = selectedSection else { return }
        prefs.set(section.key, forKey: selectionKey)
        if let address = section.url, let url = URL(string: address) {
            textScroll.isHidden = true
            web.isHidden = false
            if web.url != url {
                web.load(URLRequest(url: url))
            }
        } else {
            web.isHidden = true
            textScroll.isHidden = false
            renderer.columnWidth = text.bounds.width > 300 ? text.bounds.width - 96 : 640
            text.textStorage?.setAttributedString(renderer.render(section))
            text.scroll(.zero)
        }
        let entry = store.entries[section.key]
        signed.state = entry?.signed == true ? .on : .off
        note.stringValue = entry?.note ?? ""
    }
}

/// Runs `claude-say <replyTo> <message>`; returns what went wrong, or nil once it's delivered.
func claudeSay(_ replyTo: String, _ message: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ("~/.dotfiles/scripts/claude-say" as NSString).expandingTildeInPath)
    process.arguments = [replyTo, message]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
    process.environment = environment
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = errors
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return "\(error)"
    }
    guard process.terminationStatus == 0 else {
        return String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    return nil
}

func showClaudeSayFailure(replyTo: String?, saved: String, detail: String, window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = "Couldn't reach Claude session \(replyTo ?? "")"
    alert.informativeText = "\(saved) \(detail)"
    presentAlert(alert, in: window)
}

func presentAlert(_ alert: NSAlert, in window: NSWindow?) {
    if let window {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}

/// The workspaces on the rail, top to bottom; the nth answers to ⌘n. Nothing crosses between them except the rail's waiting badges.
enum Workspace: String, CaseIterable {
    case forest, review, learn, runs

    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .forest: return "tree"
        case .review: return "rectangle.stack"
        case .learn: return "graduationcap"
        case .runs: return "dot.radiowaves.left.and.right"
        }
    }

    var key: String { "\((Workspace.allCases.firstIndex(of: self) ?? 0) + 1)" }

    /// The quiet tint on the selected rail tile and the window subtitle; Runs turns Signal orange only while a run is going.
    func tint(running: Bool = false) -> NSColor {
        switch self {
        case .forest: return forestTint
        case .review: return .secondaryLabelColor
        case .learn: return inkColor
        case .runs: return running ? .systemOrange : .secondaryLabelColor
        }
    }

    /// The workspace a file opens in: its `"workspace"` key when that names one, otherwise its `mode` (`kind` in older tutor files).
    static func route(_ path: String) -> (workspace: Workspace, reason: String) {
        struct Head: Decodable {
            let workspace: String?
            let mode: String?
            let kind: String?
        }
        let head = try? JSONDecoder().decode(Head.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if let named = head?.workspace, let workspace = Workspace(rawValue: named.lowercased()) {
            return (workspace, "\"workspace\": \"\(named)\"")
        }
        let mode = head?.mode ?? head?.kind
        switch mode {
        case "forest": return (.forest, "mode \"forest\"")
        case "tutor": return (.learn, head?.mode == nil ? "kind \"tutor\"" : "mode \"tutor\"")
        case "live": return (.runs, "mode \"live\"")
        case let other?: return (.review, "mode \"\(other)\"")
        case nil: return (.review, "no mode")
        }
    }
}

let forestTint = NSColor(name: "show.forest") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0xA4 / 255, green: 0xBC / 255, blue: 0xAE / 255, alpha: 1)
        : NSColor(srgbRed: 0x5A / 255, green: 0x75 / 255, blue: 0x66 / 255, alpha: 1)
}

/// A rail icon: the selected workspace sits on a tile in its tint, and a count of what's waiting there rides the corner.
final class RailButton: NSButton {
    var isSelectedWorkspace = false { didSet { needsDisplay = true } }
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
    var badge = 0 { didSet { if badge != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedWorkspace {
            let fill = tint == .secondaryLabelColor ? NSColor.labelColor.withAlphaComponent(0.1) : tint.withAlphaComponent(0.16)
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
        guard badge > 0, !isSelectedWorkspace else { return }
        let text = NSAttributedString(string: badge > 99 ? "99+" : "\(badge)", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.windowBackgroundColor,
        ])
        let size = text.size()
        let width = max(14, ceil(size.width) + 7)
        let pill = NSRect(x: bounds.maxX - width + 2, y: isFlipped ? 0 : bounds.maxY - 14, width: width, height: 14)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
}

/// The one window's content: a title band across the top, the fixed rail, and every workspace's kept-alive view stacked in one slot.
/// Switching shows one workspace's view and hides the rest; it never creates, orders or resizes a window.
final class ShellController: NSViewController {
    let workspaces: [Workspace: NSViewController]
    private(set) var active: Workspace
    let rail = NSVisualEffectView()
    let titleLabel = NSTextField(labelWithString: "")
    private var buttons: [Workspace: RailButton] = [:]
    var onPick: ((Workspace) -> Void)?
    var runsRunning = false {
        didSet { if runsRunning != oldValue { refreshRail() } }
    }

    init(workspaces: [Workspace: NSViewController], active: Workspace) {
        self.workspaces = workspaces
        self.active = active
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let root = NSView()
        let band = NSVisualEffectView()
        band.material = .titlebar
        band.blendingMode = .withinWindow
        let bandEdge = NSBox()
        bandEdge.boxType = .separator
        rail.material = .titlebar
        rail.blendingMode = .behindWindow
        let edge = NSBox()
        edge.boxType = .separator
        let stack = NSStackView(views: Workspace.allCases.map(button))
        stack.orientation = .vertical
        stack.spacing = 10
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let slot = NSView()
        for view in [band, bandEdge, rail, edge, stack, slot, titleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(rail)
        root.addSubview(edge)
        root.addSubview(slot)
        root.addSubview(band)
        root.addSubview(bandEdge)
        band.addSubview(titleLabel)
        rail.addSubview(stack)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            band.topAnchor.constraint(equalTo: root.topAnchor),
            band.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            band.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            bandEdge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bandEdge.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bandEdge.topAnchor.constraint(equalTo: band.bottomAnchor),
            bandEdge.heightAnchor.constraint(equalToConstant: 1),
            titleLabel.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: band.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: band.leadingAnchor, constant: 84),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: band.trailingAnchor, constant: -16),
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.topAnchor.constraint(equalTo: bandEdge.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 44),
            edge.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            edge.topAnchor.constraint(equalTo: bandEdge.bottomAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: rail.topAnchor, constant: 10),
            stack.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            slot.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            slot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            slot.topAnchor.constraint(equalTo: bandEdge.bottomAnchor),
            slot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for workspace in Workspace.allCases {
            guard let content = workspaces[workspace] else { continue }
            addChild(content)
            content.view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(content.view)
            NSLayoutConstraint.activate([
                content.view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                content.view.topAnchor.constraint(equalTo: slot.topAnchor),
                content.view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            ])
            content.view.isHidden = workspace != active
        }
        view = root
        refreshRail()
    }

    /// Swaps which workspace's view is visible. The views stay alive, so each keeps its scroll, selection and typed text.
    func show(_ workspace: Workspace) {
        active = workspace
        for (each, content) in workspaces {
            content.view.isHidden = each != workspace
        }
        refreshRail()
    }

    func setTitle(_ title: String, subtitle: String, running: Bool = false) {
        let out = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        if !subtitle.isEmpty {
            out.append(NSAttributedString(string: "   " + subtitle, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: active.tint(running: running)]))
        }
        titleLabel.attributedStringValue = out
    }

    func setBadges(_ counts: [Workspace: Int]) {
        for (workspace, button) in buttons {
            button.badge = counts[workspace] ?? 0
            button.toolTip = "\(workspace.name) ⌘\(workspace.key)" + (button.badge > 0 ? " · \(button.badge) waiting" : "")
        }
    }

    private func refreshRail() {
        for (workspace, button) in buttons {
            let selected = workspace == active
            button.isSelectedWorkspace = selected
            let tint = workspace.tint(running: workspace == .runs && runsRunning)
            button.tint = tint
            button.contentTintColor = selected ? (tint == .secondaryLabelColor ? .labelColor : tint) : .secondaryLabelColor
            button.setAccessibilityValue(selected ? "selected" : nil)
        }
    }

    private func button(_ target: Workspace) -> NSButton {
        let image = NSImage(systemSymbolName: target.symbol, accessibilityDescription: target.name)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        let button = RailButton(image: image, target: self, action: #selector(pick))
        button.tag = Workspace.allCases.firstIndex(of: target) ?? 0
        button.isBordered = false
        button.refusesFirstResponder = true
        button.toolTip = "\(target.name) ⌘\(target.key)"
        buttons[target] = button
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 34)])
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        onPick?(Workspace.allCases[sender.tag])
    }
}

struct TutorSession: Decodable {
    let mode: String?
    let kind: String?
    let title: String
    let replyTo: String?
    let stations: [Station]?
    let due: [Due]?
    let rungs: [Rung]
    let agent: Agent?
    let notes: [Note]?

    struct Agent: Decodable {
        let session: String?
    }

    struct Note: Decodable {
        let at: String
        let text: String
    }

    /// Answers go to the session's own headless tutor, except in a file still driven by a `replyTo` terminal session.
    var usesAgent: Bool { agent != nil || replyTo == nil }

    struct Station: Decodable {
        let name: String
        let state: String
    }

    struct Due: Decodable {
        let concept: String
        let why: String?
    }
}

struct Rung: Decodable {
    let id: String
    let station: String?
    let title: String
    let situation: String?
    let ask: String
    let timeline: [Event]?
    let parts: [Part]?
    let reveal: Reveal?
    let verdicts: [String: String]?
    let followup: String?

    struct Event: Decodable {
        let t: String
        let event: String
    }

    struct Part: Decodable {
        let id: String
        let at: String?
        let ask: String?
    }

    enum Reveal: Decodable {
        case whole(String)
        case byPart([String: String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .whole(text)
            } else {
                self = .byPart(try container.decode([String: String].self))
            }
        }
    }

    /// The fields to answer: one per part, or the single part `_` when the rung has none.
    var answerParts: [Part] {
        guard let parts, !parts.isEmpty else { return [Part(id: "_", at: nil, ask: nil)] }
        return parts
    }

    var isPredict: Bool { ask == "predict" }

    func reveal(for part: String) -> String? {
        if case .byPart(let byPart) = reveal { return byPart[part] }
        return nil
    }

    var wholeReveal: String? {
        if case .whole(let text) = reveal { return text }
        return nil
    }
}

struct TutorAnswer: Codable {
    var parts: [String: String]
    var confidence: String?
    var at: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parts, forKey: .parts)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(at, forKey: .at)
    }
}

let tutorDirectory = (decksDirectory as NSString).appendingPathComponent("tutor")
let confidenceLevels = [("low", "Guessing"), ("medium", "Fairly sure"), ("high", "Certain")]

let inkColor = NSColor(name: "show.ink") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x8D / 255, green: 0xB3 / 255, blue: 0xF0 / 255, alpha: 1)
        : NSColor(srgbRed: 0x2F / 255, green: 0x5F / 255, blue: 0xB0 / 255, alpha: 1)
}

let inkFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 16)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 16) } ?? base
}()

func loadTutorSession(_ path: String) throws -> TutorSession {
    let session = try JSONDecoder().decode(TutorSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard (session.mode ?? session.kind) == "tutor" else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(path) is not a tutor session (needs \"mode\": \"tutor\")"])
    }
    return session
}

func isTutorFile(_ path: String) -> Bool {
    struct Mode: Decodable {
        let mode: String?
        let kind: String?
    }
    let file = try? JSONDecoder().decode(Mode.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    return (file?.mode ?? file?.kind) == "tutor"
}

func answersURL(_ sessionPath: String) -> URL {
    URL(fileURLWithPath: sessionPath).deletingPathExtension().appendingPathExtension("answers.json")
}

struct LearnerMessage: Codable {
    let at: String
    let text: String
}

/// The answers sidecar: one entry per answered rung, plus the learner's free messages under `messages`.
struct Sidecar {
    var answers: [String: TutorAnswer] = [:]
    var messages: [LearnerMessage] = []
}

func readSidecar(_ sessionPath: String) throws -> Sidecar {
    let url = answersURL(sessionPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return Sidecar() }
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    var sidecar = Sidecar()
    for (key, value) in raw {
        let data = try JSONSerialization.data(withJSONObject: value)
        if key == "messages" {
            sidecar.messages = try JSONDecoder().decode([LearnerMessage].self, from: data)
        } else {
            sidecar.answers[key] = try JSONDecoder().decode(TutorAnswer.self, from: data)
        }
    }
    return sidecar
}

func loadSidecar(_ sessionPath: String) -> Sidecar {
    (try? readSidecar(sessionPath)) ?? Sidecar()
}

func loadAnswers(_ sessionPath: String) -> [String: TutorAnswer] {
    loadSidecar(sessionPath).answers
}

func writeSidecar(_ sidecar: Sidecar, _ sessionPath: String) throws {
    let encoder = JSONEncoder()
    var raw: [String: Any] = [:]
    for (id, answer) in sidecar.answers {
        raw[id] = try JSONSerialization.jsonObject(with: encoder.encode(answer))
    }
    if !sidecar.messages.isEmpty {
        raw["messages"] = try JSONSerialization.jsonObject(with: encoder.encode(sidecar.messages))
    }
    try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: answersURL(sessionPath), options: .atomic)
}

func isoDate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

/// The Learn workspace's own tutor: one headless `claude -p` session per tutor file, one turn at a time, later sends queued.
final class TutorAgent {
    static var all: [String: TutorAgent] = [:]
    static let allowedTools = "Read,Edit,Write,Bash(~/.dotfiles/scripts/learn:*),Bash(~/.dotfiles/scripts/sim-play:*)"

    static func agent(for sessionPath: String) -> TutorAgent {
        if let existing = all[sessionPath] { return existing }
        let agent = TutorAgent(sessionPath: sessionPath)
        all[sessionPath] = agent
        return agent
    }

    let sessionPath: String
    private var queue: [(message: String, boot: Bool)] = []
    private(set) var running: Process?
    private(set) var failure: String?
    private(set) var preview = ""
    var onChange: (() -> Void)?
    var onDelta: ((String) -> Void)?

    init(sessionPath: String) {
        self.sessionPath = sessionPath
    }

    var isBusy: Bool { running != nil || (!queue.isEmpty && failure == nil) }

    /// Queues a message for the tutor, minting its session (and a boot turn) the first time.
    func send(_ message: String) {
        if Self.sessionID(sessionPath) == nil {
            guard mintSession() else {
                failure = "Couldn't write agent.session into \(sessionPath)"
                onChange?()
                return
            }
            queue.append((bootPrompt, true))
        }
        queue.append((message, false))
        startNext()
    }

    func retry() {
        failure = nil
        startNext()
    }

    static func sessionID(_ sessionPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (raw["agent"] as? [String: Any])?["session"] as? String
    }

    private func mintSession() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var agent = raw["agent"] as? [String: Any] ?? [:]
        agent["session"] = UUID().uuidString.lowercased()
        raw["agent"] = agent
        guard let out = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: sessionPath), options: .atomic)) != nil
    }

    private var bootPrompt: String {
        let answers = (sessionPath as NSString).deletingPathExtension + ".answers.json"
        return "You are running the /tutor skill (read ~/.dotfiles/.claude/skills/tutor/SKILL.md and the show skill's Tutor section) for the Show session file \(sessionPath). The learner answers in Show: their answers arrive in \(answers). Reply ONLY by editing the session file (reveal, verdicts, followup, the next rung) and recording evidence with `learn`; never write the answers file. Keep one rung per turn."
    }

    private func startNext() {
        guard running == nil, failure == nil, let next = queue.first, let session = Self.sessionID(sessionPath) else {
            onChange?()
            return
        }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", "acceptEdits", "--allowedTools", Self.allowedTools]
        arguments += next.boot ? ["--session-id", session] : ["--resume", session]
        arguments += ["--", next.message]
        let process = Process()
        if let override = ProcessInfo.processInfo.environment["SHOW_CLAUDE"] {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "export PATH=\"$HOME/.local/bin:$PATH\"; exec claude \"$@\"", "claude"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: ("~/.dotfiles" as NSString).expandingTildeInPath)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var pending = Data()
        var stderrTail = Data()
        var resultError: String?
        let handleLine: (Data) -> Void = { [weak self] line in
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if event["type"] as? String == "result", event["is_error"] as? Bool == true {
                resultError = event["result"] as? String ?? event["subtype"] as? String
            }
            guard event["type"] as? String == "stream_event", let inner = event["event"] as? [String: Any] else { return }
            var piece: String?
            if inner["type"] as? String == "content_block_delta", let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                piece = delta["text"] as? String
            } else if inner["type"] as? String == "message_start" {
                piece = "\n\n"
            }
            guard let piece else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preview = (self.preview + piece).trimmingCharacters(in: .newlines) == "" ? "" : self.preview + piece
                self.onDelta?(piece)
                self.onChange?()
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending.removeSubrange(pending.startIndex...newline)
            }
            lock.unlock()
            lines.forEach(handleLine)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            stderrTail.append(chunk)
            if stderrTail.count > 8192 { stderrTail = stderrTail.suffix(8192) }
            lock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            pending.append(rest)
            let last = pending
            stderrTail.append(errors.fileHandleForReading.readDataToEndOfFile())
            let tail = String(data: stderrTail, encoding: .utf8) ?? ""
            lock.unlock()
            if !last.isEmpty { handleLine(last) }
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                self.preview = ""
                if status == 0, resultError == nil {
                    self.queue.removeFirst()
                } else {
                    let lines = tail.split(separator: "\n").suffix(6).joined(separator: "\n")
                    self.failure = [resultError, lines.isEmpty ? nil : lines, "exit \(status)"].compactMap { $0 }.joined(separator: "\n")
                }
                self.startNext()
            }
        }
        do {
            try process.run()
            running = process
            preview = ""
        } catch {
            failure = "\(error)"
        }
        onChange?()
    }
}

/// The rung awaiting an answer: the first one after the last answered rung, or nil while Claude owes the next rung.
func currentRung(_ session: TutorSession, _ answers: [String: TutorAnswer]) -> Rung? {
    let start = session.rungs.lastIndex { answers[$0.id] != nil }.map { $0 + 1 } ?? 0
    return start < session.rungs.count ? session.rungs[start] : nil
}

/// JSON files in a directory, newest first, leaving out sign-off and answer sidecars.
func newestJSON(in directory: String, where keep: (String) -> Bool) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") && !$0.hasSuffix(".answers.json") }
        .map { (directory as NSString).appendingPathComponent($0) }
        .filter(keep)
        .map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}

enum RailItem {
    case event(Rung.Event)
    case part(Rung.Part)

    var t: String {
        switch self {
        case .event(let event): return event.t
        case .part(let part): return part.at ?? ""
        }
    }
}

func railTime(_ t: String) -> Double? {
    t.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression).flatMap { Double(t[$0]) }
}

/// The timeline with each `at` part slotted in after the last item at or before its time.
func railItems(_ rung: Rung) -> [RailItem] {
    var items = (rung.timeline ?? []).map(RailItem.event)
    for part in rung.parts ?? [] {
        guard let at = part.at else { continue }
        let time = railTime(at)
        let earlier = items.lastIndex { item in
            if let time, let value = railTime(item.t) { return value <= time }
            return item.t == at
        }
        if let earlier {
            items.insert(.part(part), at: earlier + 1)
        } else if time != nil, items.contains(where: { railTime($0.t) != nil }) {
            items.insert(.part(part), at: 0)
        } else {
            items.append(.part(part))
        }
    }
    return items
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

/// The page color behind an empty state, redrawn in whichever appearance is current.
final class PageBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// The quiet gray a list column sits on, behind its content.
final class ListBackdrop: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        pinned(content, in: self)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Read-only tutor text sized to its content at a fixed width.
func tutorText(_ text: NSAttributedString, width: CGFloat) -> NSTextView {
    let trimmed = NSMutableAttributedString(attributedString: text)
    while trimmed.string.hasSuffix("\n") {
        trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1))
    }
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(trimmed)
    var height: CGFloat = 0
    if let layout = view.layoutManager, let container = view.textContainer {
        layout.ensureLayout(for: container)
        height = ceil(layout.usedRect(for: container).height)
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
    return view
}

/// The learner's pen: a serif, ink-blue field that grows with its text.
final class AnswerField: NSTextView {
    let partID: String
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    private var height: NSLayoutConstraint?

    init(partID: String, text: String, width: CGFloat, editable: Bool) {
        self.partID = partID
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40), textContainer: container)
        isRichText = false
        allowsUndo = true
        isEditable = editable
        isSelectable = true
        font = inkFont
        textColor = inkColor
        insertionPointColor = inkColor
        drawsBackground = false
        textContainerInset = NSSize(width: editable ? 10 : 0, height: editable ? 8 : 2)
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        string = text
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: 40)
        self.height = height
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), height])
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func didChangeText() {
        super.didChangeText()
        fitHeight()
    }

    override func drawBackground(in rect: NSRect) {
        guard isEditable else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    private func fitHeight() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height) + textContainerInset.height * 2
        height?.constant = min(max(used, isEditable ? 64 : 0), maximumHeight)
    }
}

/// A part's margin mark: a filled dot when the prediction held, a ring when it was revised.
final class VerdictMark: NSView {
    let held: Bool

    init(held: Bool) {
        self.held = held
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = held ? "held" : "revised"
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if held {
            NSColor.secondaryLabelColor.setFill()
            dot.fill()
        } else {
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }
}

/// One row of a timeline rail: the time in the gutter, a dot on the line, the content to its right.
final class RailRow: NSView {
    static let dotX: CGFloat = 60
    static let contentX: CGFloat = 80
    let hollow: Bool
    var isFirst = false
    var isLast = false

    init(t: String, hollow: Bool, content: NSView) {
        self.hollow = hollow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let time = NSTextField(labelWithString: t)
        time.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        time.lineBreakMode = .byTruncatingHead
        for view in [time, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor),
            time.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Self.dotX - 14),
            time.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentX),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dotY: CGFloat = 10
        let line = NSBezierPath()
        line.move(to: NSPoint(x: Self.dotX, y: isFirst ? dotY : 0))
        line.line(to: NSPoint(x: Self.dotX, y: isLast ? dotY : bounds.height))
        line.lineWidth = 1.5
        NSColor.tertiaryLabelColor.setStroke()
        line.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: Self.dotX - 4.5, y: dotY - 4.5, width: 9, height: 9))
        if hollow {
            NSColor.textBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            dot.stroke()
        } else {
            NSColor.secondaryLabelColor.setFill()
            dot.fill()
        }
    }
}

/// The Learn workspace's document: one session as a worksheet — rungs oldest first, the current rung's fields answered in place.
final class TutorController: NSObject, NSTextViewDelegate {
    static let column: CGFloat = 580
    static let margin: CGFloat = 64
    var path: String?
    var session: TutorSession?
    var answers: [String: TutorAnswer] = [:]
    var drafts: [String: [String: String]] = [:]
    var confidence: [String: Int] = [:]
    var shownReveals: Set<String> = []
    var lastCurrent: String?
    var hasRendered = false
    var stamp = ""
    var timer: Timer?
    let renderer = Renderer()
    let viewController = NSSplitViewController()
    var title = "Show"
    var subtitle = ""
    var onTitleChange: (() -> Void)?
    let sidebarScroll = NSTextView.scrollableTextView()
    let scroll = NSScrollView()
    let document = FlippedView()
    let column = NSStackView()
    var fields: [AnswerField] = []
    var focusRungView: NSView?
    weak var picker: NSSegmentedControl?
    weak var hint: NSTextField?
    let composer = AnswerField(partID: "__composer", text: "", width: TutorController.column, editable: true)
    var sidecar = Sidecar()
    var agentRow: NSView?
    var agent: TutorAgent?

    var sidebar: NSTextView { sidebarScroll.documentView as! NSTextView }
    var window: NSWindow? { viewController.view.window }
    var currentRungID: String? { session.flatMap { currentRung($0, answers)?.id } }

    override init() {
        super.init()

        sidebar.isEditable = false
        sidebar.drawsBackground = false
        sidebar.textContainerInset = NSSize(width: 14, height: 48)
        sidebarScroll.drawsBackground = false
        let sidebarVC = NSViewController()
        sidebarVC.view = sidebarScroll

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.margin),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 64),
            column.widthAnchor.constraint(equalToConstant: Self.column),
            document.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: 160),
        ])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        composer.delegate = self
        composer.maximumHeight = 160
        let composerSend = NSButton(title: "Send", target: self, action: #selector(sendMessage))
        composerSend.bezelStyle = .rounded
        composerSend.toolTip = "⌘↩"
        let composerHint = NSTextField(labelWithString: "Ask the tutor anything")
        composerHint.font = .systemFont(ofSize: 11)
        composerHint.textColor = .tertiaryLabelColor
        let composerRow = NSStackView(views: [composer, composerSend])
        composerRow.orientation = .horizontal
        composerRow.alignment = .bottom
        composerRow.spacing = 12
        let composerBar = NSStackView(views: [composerHint, composerRow])
        composerBar.orientation = .vertical
        composerBar.alignment = .leading
        composerBar.spacing = 6
        composerBar.edgeInsets = NSEdgeInsets(top: 12, left: Self.margin, bottom: 14, right: 24)
        let divider = NSBox()
        divider.boxType = .separator
        let detail = NSStackView(views: [scroll, divider, composerBar])
        detail.orientation = .vertical
        detail.spacing = 0
        for view in [scroll, divider, composerBar] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let detailVC = NSViewController()
        detailVC.view = detail

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.preferredThicknessFraction = 0.24
        viewController.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = Self.margin + Self.column + 48
        viewController.addSplitViewItem(detailItem)
    }

    func show(path: String) {
        if path != self.path {
            saveDrafts()
            self.path = path
            drafts = prefs.dictionary(forKey: "tutor.drafts." + path) as? [String: [String: String]] ?? [:]
            confidence = prefs.dictionary(forKey: "tutor.confidence." + path) as? [String: Int] ?? [:]
            composer.string = prefs.string(forKey: "tutor.composer." + path) ?? ""
            composer.didChangeText()
            agent?.onChange = nil
            agent = TutorAgent.agent(for: path)
            agent?.onChange = { [weak self] in self?.refreshAgentRow() }
            shownReveals = []
            hasRendered = false
        }
        reload(forceScroll: true)
        focusFirstField()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let path = self.path, fileStamp(path) != self.stamp else { return }
            self.reload()
        }
    }

    func showEmpty(_ message: String = "No tutor sessions in `~/.dotfiles/show/tutor` yet. Claude starts one with `show --tutor <file>`.") {
        saveDrafts()
        timer?.invalidate()
        path = nil
        session = nil
        rebuild()
        column.addArrangedSubview(tutorText(renderer.tutorMarkdown(message), width: Self.column))
        sidebar.textStorage?.setAttributedString(NSAttributedString(string: "Learn", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: NSColor.labelColor]))
        title = "Show"
        subtitle = ""
        onTitleChange?()
    }

    /// Re-reads the session and its answers; keeps drafts, focus and scroll unless a new rung became current.
    func reload(forceScroll: Bool = false) {
        guard let path else { return }
        let fresh: TutorSession
        do {
            fresh = try loadTutorSession(path)
        } catch {
            if session == nil {
                column.arrangedSubviews.forEach { $0.removeFromSuperview() }
                column.addArrangedSubview(tutorText(NSAttributedString(string: "Can't read \(path): \(error)", attributes: [.font: renderer.base, .foregroundColor: NSColor.secondaryLabelColor]), width: Self.column))
            }
            return
        }
        stamp = fileStamp(path)
        session = fresh
        sidecar = loadSidecar(path)
        answers = sidecar.answers
        let current = currentRung(fresh, answers)?.id
        let moved = !hasRendered || current != lastCurrent
        let focusedField = window?.firstResponder as? AnswerField
        let focused = focusedField?.partID
        let cursor = focusedField?.selectedRange()
        let origin = scroll.contentView.bounds.origin
        rebuild()
        if forceScroll || moved {
            scrollToFocusRung()
            DispatchQueue.main.async { self.scrollToFocusRung() }
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if !moved, let focused, let field = fields.first(where: { $0.partID == focused }) {
            window?.makeFirstResponder(field)
            if let cursor, NSMaxRange(cursor) <= (field.string as NSString).length {
                field.setSelectedRange(cursor)
            }
        } else if moved {
            focusFirstField()
        }
        lastCurrent = current
        hasRendered = true
    }

    /// Keeps unsent answers across a relaunch into a new build; the answers sidecar only ever holds sent ones.
    func saveDrafts() {
        guard let path else { return }
        prefs.set(drafts, forKey: "tutor.drafts." + path)
        prefs.set(confidence, forKey: "tutor.confidence." + path)
        prefs.set(composer.string, forKey: "tutor.composer." + path)
    }

    func focusFirstField() {
        if let field = fields.first(where: { $0.string.isEmpty }) ?? fields.first {
            window?.makeFirstResponder(field)
        }
    }

    func choose(confidence level: Int) {
        guard let id = currentRungID else { return }
        confidence[id] = level
        picker?.selectedSegment = level
        hint?.isHidden = true
        saveDrafts()
    }

    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        document.subviews.filter { $0 !== column }.forEach { $0.removeFromSuperview() }
        fields = []
        focusRungView = nil
        guard let session else { return }
        renderSidebar(session)
        title = session.title
        subtitle = "\(session.rungs.filter { answers[$0.id] != nil }.count) of \(session.rungs.count) answered"
        onTitleChange?()
        let current = currentRung(session, answers)
        let focusID = current?.id ?? session.rungs.last?.id
        var fresh: [NSView] = []
        var seen: Set<String> = []
        for item in thread(session) {
            guard case .rung(let rung) = item else {
                let view = threadRow(item)
                column.addArrangedSubview(view)
                column.setCustomSpacing(28, after: view)
                continue
            }
            var marks: [(mark: NSView, block: NSView)] = []
            let view = rungView(rung, isCurrent: rung.id == current?.id, fresh: &fresh, seen: &seen, marks: &marks)
            column.addArrangedSubview(view)
            for (mark, block) in marks {
                document.addSubview(mark)
                NSLayoutConstraint.activate([
                    mark.trailingAnchor.constraint(equalTo: column.leadingAnchor, constant: -16),
                    mark.centerYAnchor.constraint(equalTo: block.topAnchor, constant: 10),
                ])
            }
            column.setCustomSpacing(56, after: view)
            if rung.id == focusID {
                focusRungView = view
            } else {
                view.alphaValue = 0.6
                marks.forEach { $0.mark.alphaValue = 0.6 }
            }
        }
        if session.rungs.isEmpty {
            column.addArrangedSubview(quiet("No rungs yet. Waiting for Claude."))
        }
        agentRow = nil
        refreshAgentRow()
        document.layoutSubtreeIfNeeded()
        if hasRendered, !fresh.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fresh.forEach { $0.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                fresh.forEach { $0.animator().alphaValue = 1 }
            }
        }
        shownReveals = seen
    }

    enum ThreadItem {
        case rung(Rung)
        case message(LearnerMessage)
        case note(TutorSession.Note)
    }

    /// Rungs, the learner's messages and the tutor's notes as one conversation by time; a rung counts from when the previous rung was answered.
    private func thread(_ session: TutorSession) -> [ThreadItem] {
        var keyed: [(Date, Int, ThreadItem)] = []
        for (i, rung) in session.rungs.enumerated() {
            let posted: Date
            if i == 0 {
                posted = .distantPast
            } else if let previous = answers[session.rungs[i - 1].id] {
                posted = isoDate(previous.at) ?? .distantPast
            } else {
                posted = .distantFuture
            }
            keyed.append((posted, keyed.count, .rung(rung)))
        }
        for message in sidecar.messages {
            keyed.append((isoDate(message.at) ?? .distantFuture, keyed.count, .message(message)))
        }
        for note in session.notes ?? [] {
            keyed.append((isoDate(note.at) ?? .distantFuture, keyed.count, .note(note)))
        }
        return keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private func threadRow(_ item: ThreadItem) -> NSView {
        switch item {
        case .message(let message):
            let p = NSMutableParagraphStyle()
            p.alignment = .right
            p.lineSpacing = 3
            return tutorText(NSAttributedString(string: message.text, attributes: [.font: inkFont, .foregroundColor: inkColor, .paragraphStyle: p]), width: Self.column)
        case .note(let note):
            return tutorText(renderer.tutorMarkdown(note.text), width: Self.column)
        case .rung:
            return NSView()
        }
    }

    /// The tutor's live row under the thread: a typing line with the streamed preview, or the last failure with Retry.
    func refreshAgentRow() {
        let atBottom = scroll.contentView.bounds.maxY >= document.bounds.height - 40
        if let agentRow {
            column.removeArrangedSubview(agentRow)
            agentRow.removeFromSuperview()
            self.agentRow = nil
        }
        guard let agent else { return }
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        if let failure = agent.failure {
            let label = quiet("The tutor stopped with an error:")
            let detail = tutorText(NSAttributedString(string: failure, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]), width: Self.column)
            let retry = NSButton(title: "Retry", target: self, action: #selector(retryAgent))
            retry.bezelStyle = .rounded
            [label, detail, retry].forEach(row.addArrangedSubview)
        } else if agent.isBusy {
            row.addArrangedSubview(quiet("Tutor is typing…"))
            let text = agent.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                row.addArrangedSubview(tutorText(NSAttributedString(string: text, attributes: [.font: renderer.base, .foregroundColor: NSColor.tertiaryLabelColor]), width: Self.column))
            }
        } else {
            return
        }
        column.addArrangedSubview(row)
        agentRow = row
        document.layoutSubtreeIfNeeded()
        if atBottom {
            scrollToBottom()
        }
    }

    private func scrollToBottom() {
        document.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func retryAgent() {
        agent?.retry()
    }

    /// Hands a line to whoever tutors this file: its own headless session, or the `replyTo` terminal session in older files.
    private func deliver(_ message: String) {
        guard let path, let session else { return }
        if session.usesAgent {
            agent?.send(message)
            scrollToBottom()
        } else if let replyTo = session.replyTo, let failure = claudeSay(replyTo, message) {
            showClaudeSayFailure(replyTo: replyTo, saved: "It's saved in \((answersURL(path).path as NSString).lastPathComponent).", detail: failure, window: window)
        }
    }

    /// ⌘↩: send the composer when it has focus, otherwise the current rung.
    func sendFocused() {
        if window?.firstResponder === composer {
            sendMessage()
        } else if currentRungID != nil {
            sendAnswer()
        } else if !composer.string.isEmpty {
            sendMessage()
        } else {
            NSSound.beep()
        }
    }

    @objc private func sendMessage() {
        guard let path else { return }
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        var all = loadSidecar(path)
        all.messages.append(LearnerMessage(at: ISO8601DateFormatter().string(from: Date()), text: text))
        do {
            try writeSidecar(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your message"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        composer.string = ""
        composer.didChangeText()
        saveDrafts()
        reload()
        deliver("learner says: \(text)")
    }

    private func rungView(_ rung: Rung, isCurrent: Bool, fresh: inout [NSView], seen: inout Set<String>, marks: inout [(mark: NSView, block: NSView)]) -> NSView {
        let width = Self.column
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        func add(_ view: NSView, after gap: CGFloat) {
            stack.addArrangedSubview(view)
            stack.setCustomSpacing(gap, after: view)
        }
        func reveal(_ text: String, key: String) -> NSView {
            let view = tutorText(renderer.tutorMarkdown(text), width: width)
            seen.insert(key)
            if !shownReveals.contains(key) { fresh.append(view) }
            return view
        }
        let answer = answers[rung.id]
        add(tutorText(renderer.tutorInline(rung.title, font: .systemFont(ofSize: 21, weight: .bold)), width: width), after: 4)
        let tag = [rung.station, rung.ask].compactMap { $0 }.joined(separator: " · ")
        add(tutorText(NSAttributedString(string: tag.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6]), width: width), after: 18)
        if let situation = rung.situation, !situation.isEmpty {
            add(tutorText(renderer.tutorMarkdown(situation), width: width), after: 12)
        }

        func partBlock(_ part: Rung.Part, width: CGFloat) -> NSView {
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 8
            if let ask = part.ask {
                block.addArrangedSubview(tutorText(renderer.tutorInline(ask, font: .systemFont(ofSize: 14.5, weight: .semibold)), width: width))
            }
            let written = answer?.parts[part.id] ?? drafts[rung.id]?[part.id] ?? ""
            let field = AnswerField(partID: part.id, text: !isCurrent && written.isEmpty ? "—" : written, width: width, editable: isCurrent)
            if isCurrent {
                field.delegate = self
                fields.append(field)
            }
            block.addArrangedSubview(field)
            if let text = rung.reveal(for: part.id) {
                let view = reveal(text, key: "\(rung.id)/\(part.id)")
                block.setCustomSpacing(12, after: field)
                block.addArrangedSubview(view)
                view.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            if let verdict = rung.verdicts?[part.id] {
                marks.append((VerdictMark(held: verdict == "held"), block))
            }
            return block
        }

        let rail = railItems(rung)
        if !rail.isEmpty {
            let railStack = NSStackView()
            railStack.orientation = .vertical
            railStack.alignment = .leading
            railStack.spacing = 0
            let inner = width - RailRow.contentX
            for (i, item) in rail.enumerated() {
                let row: RailRow
                switch item {
                case .event(let event):
                    row = RailRow(t: event.t, hollow: false, content: tutorText(renderer.tutorInline(event.event, font: renderer.base), width: inner))
                case .part(let part):
                    row = RailRow(t: part.at ?? "", hollow: true, content: partBlock(part, width: inner))
                }
                row.isFirst = i == 0
                row.isLast = i == rail.count - 1
                railStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            add(railStack, after: 16)
        }
        for part in rung.answerParts where part.at == nil {
            add(partBlock(part, width: width), after: 22)
        }
        if let text = rung.wholeReveal {
            add(reveal(text, key: "\(rung.id)/*"), after: 16)
        }
        if let followup = rung.followup, !followup.isEmpty {
            add(tutorText(renderer.tutorMarkdown(followup), width: width), after: 16)
        }
        if isCurrent {
            let question = quiet(rung.isPredict ? "How sure are you?  ⌃1 · ⌃2 · ⌃3" : "How sure are you? (optional)  ⌃1 · ⌃2 · ⌃3")
            add(question, after: 8)
            let control = NSSegmentedControl(labels: confidenceLevels.map(\.1), trackingMode: .selectOne, target: self, action: #selector(pickedConfidence))
            control.selectedSegment = confidence[rung.id] ?? -1
            control.refusesFirstResponder = true
            picker = control
            add(control, after: 18)
            let send = NSButton(title: rung.isPredict ? "Send prediction" : "Send answer", target: self, action: #selector(sendAnswer))
            send.bezelStyle = .rounded
            send.toolTip = "⌘↩"
            add(send, after: 8)
            let note = quiet("")
            note.isHidden = true
            hint = note
            add(note, after: 0)
        } else if let answer {
            if let level = confidenceLevels.first(where: { $0.0 == answer.confidence }) {
                add(quiet("Confidence: \(level.1)"), after: 8)
            }
            if rung.reveal == nil {
                add(quiet("Sent. Waiting for Claude's reveal."), after: 0)
            }
        }
        return stack
    }

    private func quiet(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func renderSidebar(_ session: TutorSession) {
        let out = NSMutableAttributedString()
        func line(_ text: String, _ font: NSFont, _ color: NSColor, before: CGFloat = 0, after: CGFloat = 4) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.headIndent = 16
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        let caption = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        line(session.title, .systemFont(ofSize: 17, weight: .bold), .labelColor, after: 14)
        if let stations = session.stations, !stations.isEmpty {
            line("STATIONS", caption, .secondaryLabelColor, before: 6, after: 6)
            for station in stations {
                let marker = station.state == "done" ? "✓" : station.state == "current" ? "●" : "○"
                let color: NSColor = station.state == "current" ? .controlAccentColor : station.state == "done" ? .secondaryLabelColor : .labelColor
                line("\(marker)  \(station.name)", .systemFont(ofSize: 13, weight: station.state == "current" ? .semibold : .regular), color)
            }
        }
        if let due = session.due, !due.isEmpty {
            line("DUE RE-TESTS", caption, .secondaryLabelColor, before: 16, after: 6)
            for item in due {
                line(item.concept, .systemFont(ofSize: 12.5, weight: .medium), .labelColor, after: item.why == nil ? 8 : 1)
                if let why = item.why {
                    line(why, .systemFont(ofSize: 11.5), .secondaryLabelColor, after: 8)
                }
            }
        }
        sidebar.textStorage?.setAttributedString(out)
    }

    private func scrollToFocusRung() {
        guard let view = focusRungView else { return }
        document.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: document)
        let room = document.bounds.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(frame.minY - 40, room))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func showHint(_ text: String) {
        NSSound.beep()
        hint?.stringValue = text
        hint?.isHidden = false
    }

    @objc private func pickedConfidence(_ sender: NSSegmentedControl) {
        choose(confidence: sender.selectedSegment)
    }

    @objc private func sendAnswer() {
        guard let path, let session, let rung = currentRung(session, answers) else {
            NSSound.beep()
            return
        }
        var texts: [String: String] = [:]
        for part in rung.answerParts {
            texts[part.id] = (drafts[rung.id]?[part.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if texts.values.contains(where: \.isEmpty) {
            showHint(rung.answerParts.count > 1 ? "Answer every part first." : "Write your answer first.")
            return
        }
        let level = confidence[rung.id]
        if rung.isPredict, level == nil {
            showHint("Pick how sure you are first: ⌃1 Guessing · ⌃2 Fairly sure · ⌃3 Certain.")
            return
        }
        var all = loadSidecar(path)
        all.answers[rung.id] = TutorAnswer(parts: texts, confidence: level.map { confidenceLevels[$0].0 }, at: ISO8601DateFormatter().string(from: Date()))
        do {
            try writeSidecar(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your answer"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        drafts[rung.id] = nil
        confidence[rung.id] = nil
        saveDrafts()
        reload()
        deliver("tutor answer: \(path) rung \(rung.id)")
    }

    func textDidChange(_ notification: Notification) {
        if notification.object as? AnswerField === composer {
            saveDrafts()
            return
        }
        guard let field = notification.object as? AnswerField, let id = currentRungID else { return }
        drafts[id, default: [:]][field.partID] = field.string
        hint?.isHidden = true
        saveDrafts()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === composer, commandSelector == #selector(NSResponder.insertBacktab(_:)), let last = fields.last {
            window?.makeFirstResponder(last)
            return true
        }
        guard let index = fields.firstIndex(where: { $0 === textView }), fields.count > 0 else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            window?.makeFirstResponder(fields[(index + 1) % fields.count])
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.makeFirstResponder(fields[(index + fields.count - 1) % fields.count])
            return true
        default:
            return false
        }
    }

    /// Writes the whole worksheet column, which runs taller than the window, to `file`.
    func snapshotWorksheet(to file: String) {
        timer?.invalidate()
        scroll.contentView.scroll(to: .zero)
        document.layoutSubtreeIfNeeded()
        writePNG(document, to: file)
    }
}

func fileStamp(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(modified)-\(attributes[.size] as? Int ?? 0)"
}

/// `--tutor-ask`: what the composer does, without a window: record a learner message, run the tutor turn, stream its text to stdout.
func tutorAsk(_ raw: String, _ text: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        _ = try loadTutorSession(path)
        var sidecar = try readSidecar(path)
        sidecar.messages.append(LearnerMessage(at: ISO8601DateFormatter().string(from: Date()), text: text))
        try writeSidecar(sidecar, path)
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
    let agent = TutorAgent.agent(for: path)
    var started = false
    agent.onDelta = { piece in
        FileHandle.standardOutput.write(piece.data(using: .utf8)!)
    }
    agent.onChange = {
        if agent.isBusy { started = true }
        if started, !agent.isBusy || agent.failure != nil {
            if let failure = agent.failure {
                FileHandle.standardError.write("\ntutor failed:\n\(failure)\n".data(using: .utf8)!)
                exit(1)
            }
            print("\n[done; agent.session \(TutorAgent.sessionID(path) ?? "-")]")
            exit(0)
        }
    }
    agent.send("learner says: \(text)")
    RunLoop.main.run()
    return 0
}

/// `--tutor-check`: parse a session plus its answers and print what the Tutor space would show, without a window.
func tutorCheck(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        let session = try loadTutorSession(path)
        let sidecar = try readSidecar(path)
        let answers = sidecar.answers
        print("session: \(session.title)")
        print("replyTo: \(session.replyTo ?? "-")")
        print("agent: \(session.agent?.session ?? "-") (\(session.usesAgent ? "answers go to the headless tutor" : "answers go to replyTo via claude-say"))")
        print("thread: \(sidecar.messages.count) learner messages, \((session.notes ?? []).count) tutor notes")
        print("answers: \(answersURL(path).path)")
        print("answered: \(session.rungs.filter { answers[$0.id] != nil }.map(\.id).joined(separator: ", "))")
        if let rung = currentRung(session, answers) {
            print("current: \(rung.id) (\(rung.ask); parts \(rung.answerParts.map(\.id).joined(separator: ", ")); confidence \(rung.isPredict ? "required" : "optional"))")
        } else {
            print("current: none (waiting for Claude)")
        }
        for station in session.stations ?? [] {
            let marker = station.state == "done" ? "✓" : station.state == "current" ? "●" : "○"
            print("station: \(marker) \(station.state) \(station.name)")
        }
        for item in session.due ?? [] {
            print("due: \(item.concept)")
        }
        for rung in session.rungs {
            let rail = railItems(rung).map { item -> String in
                switch item {
                case .event(let event): return event.t
                case .part(let part): return "[\(part.id)@\(part.at ?? "")]"
                }
            }
            let reveal: String
            switch rung.reveal {
            case .none: reveal = "none"
            case .whole: reveal = "whole"
            case .byPart(let byPart): reveal = "parts " + byPart.keys.sorted().joined(separator: ",")
            }
            print("rung \(rung.id): rail \(rail.isEmpty ? "-" : rail.joined(separator: " → ")); below \(rung.answerParts.filter { $0.at == nil }.map(\.id).joined(separator: ",")); reveal \(reveal); verdicts \((rung.verdicts ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        }
        return 0
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
}

/// What a document on the shelf wants from you.
enum ShelfState: Int {
    case waiting, running, done
}

/// One document as the library sees it: where it lives, which workspace owns it, and whether it waits on you.
struct ShelfEntry {
    let path: String
    let workspace: Workspace
    let title: String
    let state: ShelfState
    let progress: String
    let touched: Date
}

func sidecarPaths(_ path: String) -> [String] {
    let stem = (path as NSString).deletingPathExtension
    return [stem + ".signoff.json", stem + ".answers.json"]
}

/// The newest of the file, its sidecars, and when Show last opened it.
func touchedDate(_ path: String) -> Date {
    let opened = prefs.object(forKey: "opened." + path) as? Date
    return ([path] + sidecarPaths(path)).compactMap(modificationDate).reduce(opened ?? .distantPast) { max($0, $1) }
}

/// Every document Show can open, from `~/.dotfiles/show` and its `tutor/` folder, sidecars left out.
func libraryPaths() -> [String] {
    [decksDirectory, tutorDirectory].flatMap { directory in
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") && !$0.hasSuffix(".answers.json") }
            .map { (directory as NSString).appendingPathComponent($0) }
    }
}

/// A cheap fingerprint of the library folders: changes when any document or sidecar is added, removed or rewritten.
func librarySignature() -> String {
    [decksDirectory, tutorDirectory].map { directory in
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().map { name in
            "\(name):\(fileStamp((directory as NSString).appendingPathComponent(name)))"
        }.joined(separator: "|")
    }.joined(separator: "#")
}

func shelfEntry(_ path: String) -> ShelfEntry? {
    let workspace = Workspace.route(path).workspace
    let touched = touchedDate(path)
    switch workspace {
    case .learn:
        guard let session = try? loadTutorSession(path) else { return nil }
        let answers = loadAnswers(path)
        let answered = session.rungs.filter { answers[$0.id] != nil }.count
        let waiting = currentRung(session, answers) != nil
        let progress = "\(answered) of \(session.rungs.count) answered" + (waiting ? "" : " · Claude's turn")
        return ShelfEntry(path: path, workspace: workspace, title: session.title, state: waiting ? .waiting : .done, progress: progress, touched: touched)
    case .runs:
        struct Live: Decodable {
            struct Status: Decodable {
                let done: Int?
                let total: Int?
                let state: String?
            }
            let title: String
            let status: Status?
        }
        guard let live = try? JSONDecoder().decode(Live.self, from: Data(contentsOf: URL(fileURLWithPath: path))) else { return nil }
        let state: ShelfState
        switch live.status?.state {
        case "running": state = .running
        case "done", "failed": state = .done
        default: state = .waiting
        }
        let counts = live.status.flatMap { status in status.done.flatMap { done in status.total.map { "\(done) of \($0)" } } }
        let progress = [counts, live.status?.state].compactMap { $0 }.joined(separator: " · ")
        return ShelfEntry(path: path, workspace: workspace, title: live.title, state: state, progress: progress, touched: touched)
    case .forest, .review:
        guard let deck = try? loadDeck(path) else { return nil }
        let store = SignOffStore(deckPath: path)
        let done = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
        return ShelfEntry(path: path, workspace: workspace, title: deck.title, state: done < deck.sections.count ? .waiting : .done,
                          progress: "\(done) of \(deck.sections.count) signed", touched: touched)
    }
}

func scanLibrary() -> [ShelfEntry] {
    libraryPaths().compactMap(shelfEntry).sorted { $0.touched > $1.touched }
}

func pinned(_ view: NSView, in host: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
        view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
}

/// A centered, quiet message for a workspace with nothing open.
func emptyState(_ headline: String, _ detail: String) -> NSView {
    let title = NSTextField(labelWithString: headline)
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = .secondaryLabelColor
    let body = NSTextField(wrappingLabelWithString: detail)
    body.font = .systemFont(ofSize: 13)
    body.textColor = .tertiaryLabelColor
    body.alignment = .center
    body.preferredMaxLayoutWidth = 360
    let stack = NSStackView(views: [title, body])
    stack.orientation = .vertical
    stack.spacing = 8
    let view = PageBackdrop()
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
    ])
    return view
}

/// One workspace: its own open document, typed text and focus, kept alive while another workspace is in front.
final class WorkspaceController: NSViewController {
    let workspace: Workspace
    private(set) var current: String?
    private(set) var decks: [String: DeckController] = [:]
    let tutor: TutorController?
    let host = NSView()
    var onTitleChange: (() -> Void)?
    private weak var savedResponder: NSResponder?
    private var savedRange: NSRange?

    init(workspace: Workspace) {
        self.workspace = workspace
        tutor = workspace == .learn ? TutorController() : nil
        super.init(nibName: nil, bundle: nil)
        tutor?.onTitleChange = { [weak self] in self?.onTitleChange?() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = host
        if let tutor {
            addChild(tutor.viewController)
            pinned(tutor.viewController.view, in: host)
        }
        if current == nil {
            showNothing()
        }
    }

    var currentDeck: DeckController? { current.flatMap { decks[$0] } }

    var documentTitle: String {
        if let tutor { return tutor.title }
        return currentDeck?.title ?? "Show"
    }

    var subtitle: String {
        if let tutor { return tutor.subtitle }
        return currentDeck?.subtitle ?? ""
    }

    /// Opens `path` here, or reloads it when it's already the open document.
    func open(_ path: String) {
        _ = view
        prefs.set(Date(), forKey: "opened." + path)
        if path == current {
            reload()
            return
        }
        currentDeck?.saveNote()
        current = path
        prefs.set(path, forKey: "workspace.\(workspace.rawValue).open")
        switch workspace {
        case .learn:
            tutor?.show(path: path)
        case .forest, .review, .runs:
            let controller: DeckController
            if let existing = decks[path] {
                controller = existing
                controller.reloadIfChanged()
            } else {
                guard let deck = loadOrComplain(path) else {
                    current = nil
                    showNothing()
                    return
                }
                controller = DeckController(path: path, deck: deck)
                controller.onTitleChange = { [weak self, weak controller] in
                    guard let self, let controller, self.currentDeck === controller else { return }
                    self.onTitleChange?()
                }
                decks[path] = controller
            }
            display(controller.viewController)
            controller.window?.makeFirstResponder(controller.table)
        }
        onTitleChange?()
    }

    private func loadOrComplain(_ path: String) -> Deck? {
        do {
            return try loadDeck(path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't open \((path as NSString).lastPathComponent)"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: view.window)
            return nil
        }
    }

    /// Closes the open document, leaving the workspace's empty state.
    func close() {
        current = nil
        prefs.removeObject(forKey: "workspace.\(workspace.rawValue).open")
        showNothing()
        onTitleChange?()
    }

    func showNothing() {
        switch workspace {
        case .learn:
            tutor?.showEmpty(libraryPaths().contains(where: isTutorFile)
                ? "Nothing open. Pick a session from the Tutor menu, or Claude opens one with `show --tutor <file>`."
                : "No tutor sessions in `~/.dotfiles/show/tutor` yet. Claude starts one with `show --tutor <file>`.")
        case .runs:
            display(emptyState("No live runs yet", "A live run shows here while it's going."))
        case .forest:
            display(emptyState("No forest open", "Claude opens a project's branches here with `show <deck>`."))
        case .review:
            display(emptyState("Nothing to review", "Claude opens a deck here with `show <deck>`."))
        }
    }

    private func display(_ content: NSViewController) {
        children.filter { $0 !== content && $0 !== tutor?.viewController }.forEach { $0.removeFromParent() }
        if content.parent !== self { addChild(content) }
        display(content.view)
    }

    private func display(_ content: NSView) {
        guard workspace != .learn else { return }
        host.subviews.filter { $0 !== content }.forEach { $0.removeFromSuperview() }
        if content.superview !== host {
            pinned(content, in: host)
        }
    }

    func reload() {
        if let tutor {
            tutor.reload()
        } else {
            currentDeck?.reload()
        }
    }

    /// The file watcher's tick: decks reload when their file changed (Learn's tutor watches its own file), and live status lines age.
    func reloadChanged() {
        decks.values.forEach { $0.reloadIfChanged() }
        decks.values.filter(\.deck.isLive).forEach { $0.updateStatusLine() }
    }

    /// Whether the open document is a live run that's going, which turns the Runs tint orange.
    var isRunning: Bool {
        guard let deck = currentDeck?.deck else { return false }
        return deck.isLive && deck.status?.state == "running"
    }

    func saveState() {
        decks.values.forEach { $0.saveNote() }
        tutor?.saveDrafts()
    }

    /// Remembers which field had focus (and where its cursor was) before another workspace comes forward.
    func rememberFocus(in window: NSWindow) {
        saveState()
        savedResponder = nil
        savedRange = nil
        var responder = window.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            savedRange = editor.selectedRange()
            responder = field
        } else if let textView = responder as? NSTextView {
            savedRange = textView.selectedRange()
        }
        if let responderView = responder as? NSView, responderView.isDescendant(of: view) {
            savedResponder = responderView
        }
    }

    func restoreFocus(in window: NSWindow) {
        guard let responder = savedResponder as? NSView, responder.window === window, !responder.isHiddenOrHasHiddenAncestor else {
            if let tutor {
                tutor.focusFirstField()
            } else if let deck = currentDeck {
                window.makeFirstResponder(deck.table)
            }
            return
        }
        window.makeFirstResponder(responder)
        if let range = savedRange {
            if let field = responder as? NSTextField, let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: min(range.location, (editor.string as NSString).length), length: 0)
            } else if let textView = responder as? NSTextView, NSMaxRange(range) <= (textView.string as NSString).length {
                textView.setSelectedRange(range)
            }
        }
    }
}

/// Writes a view as drawn into a PNG, in the light appearance.
func writePNG(_ view: NSView, to file: String) {
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}

/// The whole window as drawn, with each visible list painted over its slot: an ancestor's capture leaves table rows out.
func writeComposite(_ root: NSView, to file: String) {
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        func tables(in view: NSView) -> [NSTableView] {
            view.subviews.flatMap { sub -> [NSTableView] in
                if let table = sub as? NSTableView { return [table] }
                return tables(in: sub)
            }
        }
        guard let canvas = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor.windowBackgroundColor.setFill()
        root.bounds.fill()
        rep.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        for table in tables(in: root) where !table.isHiddenOrHasHiddenAncestor {
            let visible = table.visibleRect
            let pixels = CGFloat(canvas.pixelsWide) / max(root.bounds.width, 1)
            guard visible.width > 0, visible.height > 0,
                  let part = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(visible.width * pixels), pixelsHigh: Int(visible.height * pixels),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            part.size = visible.size
            table.cacheDisplay(in: visible, to: part)
            let slot = table.convert(visible, to: root)
            part.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}

/// One Show process and one window: `show <file>` hands the file to the running app, which switches to its workspace and opens it there.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {
    var window: NSWindow!
    var shell: ShellController!
    var workspaces: [Workspace: WorkspaceController] = [:]
    let decksMenu = NSMenu(title: "Decks")
    let tutorSessionsMenu = NSMenu(title: "Sessions")
    let launchPaths: [String]
    let snapshotPath: String?
    var watcher: Timer?
    var signature = ""
    let launchedBuild = modificationDate(buildStamp)

    init(launchPaths: [String], snapshotPath: String? = nil) {
        self.launchPaths = launchPaths
        self.snapshotPath = snapshotPath
    }

    var active: Workspace { shell.active }
    var tutor: TutorController? { workspaces[.learn]?.tutor }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let start = prefs.string(forKey: "workspace.active").flatMap(Workspace.init(rawValue:)) ?? .review
        for workspace in Workspace.allCases {
            let controller = WorkspaceController(workspace: workspace)
            controller.onTitleChange = { [weak self] in
                guard let self, self.shell != nil, self.active == workspace else { return }
                self.updateTitle()
            }
            workspaces[workspace] = controller
        }
        shell = ShellController(workspaces: workspaces, active: start)
        shell.onPick = { [weak self] in self?.switchTo($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.contentViewController = shell
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.contentMinSize = NSSize(width: 45 + 200 + TutorController.margin + TutorController.column + 48, height: 480)
        if snapshotPath == nil {
            window.center()
            window.setFrameAutosaveName("show.window")
        }
        restore()
        updateTitle()
        launchPaths.forEach(openPath)
        if let snapshotPath {
            snapshot(to: snapshotPath)
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        workspaces[active]?.restoreFocus(in: window)
        NSApp.activate(ignoringOtherApps: true)
        refreshBadges()
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.stayCurrent() }
    }

    /// Reopens each workspace's last document, so a relaunch into a new build comes back where it was.
    private func restore() {
        for (workspace, controller) in workspaces {
            if let path = prefs.string(forKey: "workspace.\(workspace.rawValue).open"), FileManager.default.fileExists(atPath: path),
               Workspace.route(path).workspace == workspace {
                controller.open(path)
            } else {
                _ = controller.view
            }
        }
    }

    /// Reloads documents edited on disk, refreshes the rail's waiting badges, and relaunches into a newer build once the launcher finishes one.
    private func stayCurrent() {
        workspaces.values.forEach { $0.reloadChanged() }
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        refreshBadges()
        if let built = modificationDate(buildStamp), built != launchedBuild {
            relaunch()
        }
    }

    func refreshBadges(force: Bool = false) {
        let fresh = librarySignature()
        guard force || fresh != signature else { return }
        signature = fresh
        let entries = scanLibrary()
        var counts: [Workspace: Int] = [:]
        for entry in entries where entry.state == .waiting {
            counts[entry.workspace, default: 0] += 1
        }
        shell.setBadges(counts)
    }

    private func relaunch() {
        watcher?.invalidate()
        saveAll()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; open -a \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func saveAll() {
        workspaces.values.forEach { $0.saveState() }
        prefs.set(active.rawValue, forKey: "workspace.active")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.map(\.path).forEach(openPath)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if snapshotPath == nil {
            saveAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Switches to the file's workspace and opens it there.
    func openPath(_ rawPath: String) {
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        let workspace = Workspace.route(path).workspace
        switchTo(workspace)
        workspaces[workspace]?.open(path)
        refreshBadges(force: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings a workspace forward in the same window: its view swaps in, nothing else moves.
    func switchTo(_ workspace: Workspace) {
        guard workspace != active else { return }
        workspaces[active]?.rememberFocus(in: window)
        shell.show(workspace)
        prefs.set(workspace.rawValue, forKey: "workspace.active")
        updateTitle()
        workspaces[workspace]?.restoreFocus(in: window)
    }

    func updateTitle() {
        guard let controller = workspaces[active] else { return }
        let detail = controller.current == nil ? "" : controller.subtitle
        shell.runsRunning = workspaces[.runs]?.isRunning ?? false
        shell.setTitle(controller.documentTitle, subtitle: [active.name, detail].filter { !$0.isEmpty }.joined(separator: " · "), running: controller.isRunning)
        window.title = controller.documentTitle
    }

    @objc func showWorkspace(_ sender: NSMenuItem) {
        switchTo(Workspace.allCases[sender.tag])
    }

    @objc func pickConfidence(_ sender: NSMenuItem) {
        tutor?.choose(confidence: sender.tag)
    }

    @objc func openListed(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openPath(path)
    }

    @objc func sendTutor(_ sender: Any?) {
        tutor?.sendFocused()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(sendTutor) {
            return active == .learn
        }
        if menuItem.action == #selector(pickConfidence) {
            return active == .learn && tutor?.currentRungID != nil
        }
        return true
    }

    @objc func openOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: decksDirectory)
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.map(\.path).forEach(openPath)
    }

    @objc func reloadCurrent(_ sender: Any?) {
        workspaces[active]?.reload()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let wanted: Set<Workspace> = menu === tutorSessionsMenu ? [.learn] : [.forest, .review]
        let entries = scanLibrary().filter { wanted.contains($0.workspace) }
        for entry in entries {
            let item = NSMenuItem(title: "\(entry.title)  —  \(entry.progress)", action: #selector(openListed), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            item.state = workspaces[entry.workspace]?.current == entry.path ? .on : .off
            menu.addItem(item)
        }
        if menu === tutorSessionsMenu {
            if menu.items.isEmpty {
                menu.addItem(withTitle: "No sessions in ~/.dotfiles/show/tutor", action: nil, keyEquivalent: "")
            }
            return
        }
        if !entries.isEmpty {
            menu.addItem(.separator())
        }
        let other = NSMenuItem(title: "Open Deck…", action: #selector(openOther), keyEquivalent: "o")
        other.target = self
        menu.addItem(other)
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadCurrent), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Show", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let decksItem = NSMenuItem()
        main.addItem(decksItem)
        decksMenu.delegate = self
        decksMenu.addItem(withTitle: "Open Deck…", action: #selector(openOther), keyEquivalent: "o").target = self
        decksItem.submenu = decksMenu
        let workspaceItem = NSMenuItem()
        main.addItem(workspaceItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        for (i, workspace) in Workspace.allCases.enumerated() {
            let item = NSMenuItem(title: workspace.name, action: #selector(showWorkspace), keyEquivalent: workspace.key)
            item.tag = i
            item.target = self
            workspaceMenu.addItem(item)
        }
        workspaceItem.submenu = workspaceMenu
        let tutorItem = NSMenuItem()
        main.addItem(tutorItem)
        let tutorMenu = NSMenu(title: "Tutor")
        tutorSessionsMenu.delegate = self
        tutorMenu.addItem(withTitle: "Sessions", action: nil, keyEquivalent: "").submenu = tutorSessionsMenu
        tutorMenu.addItem(.separator())
        let sendItem = NSMenuItem(title: "Send", action: #selector(sendTutor), keyEquivalent: "\r")
        sendItem.keyEquivalentModifierMask = [.command]
        sendItem.target = self
        tutorMenu.addItem(sendItem)
        tutorMenu.addItem(.separator())
        for (i, level) in confidenceLevels.enumerated() {
            let item = NSMenuItem(title: level.1, action: #selector(pickConfidence), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.control]
            item.tag = i
            item.target = self
            tutorMenu.addItem(item)
        }
        tutorItem.submenu = tutorMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    /// Renders the window offscreen: the whole window (`out`), the rail (`-rail`), and the open document's parts, which run taller than the window.
    func snapshot(to output: String) {
        if let named = ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_WORKSPACE"], let workspace = Workspace(rawValue: named) {
            switchTo(workspace)
        }
        window.appearance = NSAppearance(named: .aqua)
        refreshBadges(force: true)
        let controller = workspaces[active]
        if let key = ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_SECTION"] {
            controller?.currentDeck?.select(section: key)
        }
        window.layoutIfNeeded()
        shell.view.layoutSubtreeIfNeeded()
        controller?.currentDeck?.prepareSnapshot()
        controller?.currentDeck?.table.reloadData()
        shell.view.layoutSubtreeIfNeeded()
        controller?.currentDeck?.table.layoutSubtreeIfNeeded()
        let stem = (output as NSString).deletingPathExtension
        writeComposite(shell.view, to: output)
        writePNG(shell.rail, to: stem + "-rail.png")
        if let deck = controller?.currentDeck {
            writePNG(deck.table, to: stem + "-sidebar.png")
            deck.text.sizeToFit()
            writePNG(deck.text, to: stem + "-detail.png")
        }
        if active == .learn, let tutor {
            tutor.snapshotWorksheet(to: stem + "-worksheet.png")
        }
        print("workspace: \(active.rawValue) · title: \(controller?.documentTitle ?? "-") · subtitle: \(controller?.subtitle ?? "-")")
    }
}

/// `--check-routing`: print which workspace a file opens in, and why.
func checkRouting(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write("Show: no such file: \(path)\n".data(using: .utf8)!)
        return 66
    }
    let route = Workspace.route(path)
    print("workspace: \(route.workspace.rawValue) (⌘\(route.workspace.key), by \(route.reason))")
    if let entry = shelfEntry(path) {
        print("shelf: \(entry.state) · \(entry.title) · \(entry.progress)")
    } else {
        print("shelf: unreadable as a \(route.workspace.name) document")
    }
    return 0
}

var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--tutor-ask") {
    guard flag + 2 < arguments.count else {
        FileHandle.standardError.write("usage: Show --tutor-ask <session.json> <message>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(tutorAsk(arguments[flag + 1], arguments[flag + 2]))
}
if let flag = arguments.firstIndex(of: "--tutor-check") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write("usage: Show --tutor-check <session.json>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(tutorCheck(arguments[flag + 1]))
}
if let flag = arguments.firstIndex(of: "--check-routing") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write("usage: Show --check-routing <file.json>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(checkRouting(arguments[flag + 1]))
}
var snapshotPath: String?
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    snapshotPath = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
let deckPaths = arguments.filter { !$0.hasPrefix("-") }.map { ($0 as NSString).expandingTildeInPath }

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if let snapshotPath {
    guard !deckPaths.isEmpty else {
        FileHandle.standardError.write("usage: Show <file.json>… --snapshot out.png\n".data(using: .utf8)!)
        exit(64)
    }
    let suite = "com.philbrockman.show.snapshot"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    prefs = UserDefaults(suiteName: suite) ?? .standard
    app.setActivationPolicy(.prohibited)
    delegate = AppDelegate(launchPaths: deckPaths, snapshotPath: snapshotPath)
} else {
    app.setActivationPolicy(.regular)
    delegate = AppDelegate(launchPaths: deckPaths)
}
app.delegate = delegate
app.run()
