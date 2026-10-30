// Show — one native app for walkthrough decks; each deck opens as a labelled tab. Renders a JSON file of sections:
// { "title", "subtitle"?, "sections": [{ "id"?, "group", "title", "tag"?, "body" (markdown), "url"? (a live page shown instead of the body) }] }
// Sign-offs and notes save beside the deck as <deck>.signoff.json; "replyTo" names the claude-say session that Submit notifies.
// The Tutor space (⌘2) reads a { "mode": "tutor", … } session file and writes answers beside it as <session>.answers.json.
import AppKit
import UniformTypeIdentifiers
import WebKit

struct Deck: Decodable {
    let title: String
    let subtitle: String?
    let replyTo: String?
    let sections: [Section]
}

struct Section: Decodable {
    let id: String?
    let group: String
    let title: String
    let tag: String?
    let body: String?
    let url: String?

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

    func render(_ section: Section) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(line(section.group.uppercased(), font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor, after: 4))
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

    private func block(_ code: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 12
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        p.lineSpacing = 2
        return NSAttributedString(string: code + "\n", attributes: [
            .font: mono, .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12), .paragraphStyle: p,
        ])
    }

    private func table(_ rows: [String]) -> NSAttributedString {
        let cells = rows
            .filter { !$0.replacingOccurrences(of: #"[|\-: ]"#, with: "", options: .regularExpression).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in cells.map { c < $0.count ? plain($0[c]).count : 0 }.max() ?? 0 }
        let out = NSMutableAttributedString()
        for (i, row) in cells.enumerated() {
            let text = (0..<columns).map { c in
                let cell = c < row.count ? plain(row[c]) : ""
                return cell.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }.joined(separator: "   ")
            let font = i == 0 ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold) : mono
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 3
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
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

let decksDirectory = ("~/.dotfiles/show" as NSString).expandingTildeInPath

/// One deck in one window; windows share a tab group, so each deck is a labelled tab.
final class DeckController: NSObject, WKNavigationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let path: String
    var deck: Deck
    var rows: [Row] = []
    var store: SignOffStore
    let renderer = Renderer()
    let window: NSWindow
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
    var onClose: (() -> Void)?
    var deckModified: Date?

    init(path: String, deck: Deck) {
        self.path = path
        self.deck = deck
        store = SignOffStore(deckPath: path)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "show.deck"
        window.delegate = self
        window.representedURL = URL(fileURLWithPath: path)
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(viewController: sidebarController())
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 380
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController()))
        window.contentViewController = SpaceContainer(space: .decks, content: split)
        window.setContentSize(NSSize(width: 1180, height: 780))
        deckModified = modificationDate(path)
        apply(deck, keepingSelection: UserDefaults.standard.string(forKey: selectionKey))
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
        store = SignOffStore(deckPath: path)
        apply(fresh, keepingSelection: kept)
        if selectedSection?.key == kept {
            if let container = text.textContainer {
                text.layoutManager?.ensureLayout(for: container)
            }
            let clip = textScroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            textScroll.reflectScrolledClipView(clip)
            if let cursor {
                window.makeFirstResponder(note)
                let length = (note.stringValue as NSString).length
                note.currentEditor()?.selectedRange = NSRange(location: min(cursor.location, length), length: min(cursor.length, max(0, length - cursor.location)))
            }
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
        window.title = deck.title
        window.tab.title = deck.title
        table.reloadData()
        let kept = rows.firstIndex { if case .item(let i) = $0 { return deck.sections[i].key == key } else { return false } }
        let first = rows.firstIndex { if case .item = $0 { return true } else { return false } }
        if let row = kept ?? first {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        }
        updateProgress()
    }

    func windowWillClose(_ notification: Notification) {
        saveNote()
        onClose?()
    }

    func snapshot(to path: String) {
        guard let view = window.contentView else { return }
        window.appearance = NSAppearance(named: .aqua)
        if let section = selectedSection {
            text.textStorage?.setAttributedString(renderer.render(section))
        }
        table.reloadData()
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func sidebarController() -> NSViewController {
        let column = NSTableColumn(identifier: .init("section"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
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
        vc.view = stack
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

        let stack = NSStackView(views: [page, divider, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [page, divider, bar] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let vc = NSViewController()
        vc.view = stack
        return vc
    }

    @objc private func toggleSigned() {
        guard let section = selectedSection else { return }
        store.update(section.key) { $0.signed = signed.state == .on }
        reloadSelectedRow()
    }

    @objc func saveNote() {
        guard let section = selectedSection else { return }
        let value = note.stringValue
        guard (store.entries[section.key]?.note ?? "") != value else { return }
        store.update(section.key) { $0.note = value }
        reloadSelectedRow()
    }

    @objc private func submitReview() {
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
        let total = deck.sections.count
        let done = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
        progress.stringValue = "\(done) of \(total) signed off"
        window.subtitle = [deck.subtitle, "\(done)/\(total) signed off"].compactMap { $0 }.joined(separator: " · ")
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let group):
            let label = NSTextField(labelWithString: group.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .item(let i):
            let section = deck.sections[i]
            let entry = store.entries[section.key]
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
        UserDefaults.standard.set(section.key, forKey: selectionKey)
        if let address = section.url, let url = URL(string: address) {
            textScroll.isHidden = true
            web.isHidden = false
            if web.url != url {
                web.load(URLRequest(url: url))
            }
        } else {
            web.isHidden = true
            textScroll.isHidden = false
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

func showClaudeSayFailure(replyTo: String?, saved: String, detail: String, window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = "Couldn't reach Claude session \(replyTo ?? "")"
    alert.informativeText = "\(saved) \(detail)"
    alert.beginSheetModal(for: window)
}

/// The spaces on the switcher rail, top to bottom; the nth answers to ⌘n.
enum Space: CaseIterable {
    case decks, tutor

    var name: String {
        switch self {
        case .decks: return "Decks"
        case .tutor: return "Tutor"
        }
    }

    var symbol: String {
        switch self {
        case .decks: return "rectangle.stack"
        case .tutor: return "graduationcap"
        }
    }

    var key: String { "\((Space.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

/// A rail icon; the selected space sits on a quiet rounded tile.
final class RailButton: NSButton {
    var isSelectedSpace = false

    override func draw(_ dirtyRect: NSRect) {
        if isSelectedSpace {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Wraps a space's content with the Slack-style switcher rail; ⌘1 / ⌘2 do what its buttons do.
final class SpaceContainer: NSViewController {
    let space: Space
    let content: NSViewController

    init(space: Space, content: NSViewController) {
        self.space = space
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let root = NSView()
        let rail = NSVisualEffectView()
        rail.material = .titlebar
        rail.blendingMode = .behindWindow
        let edge = NSBox()
        edge.boxType = .separator
        let buttons = NSStackView(views: Space.allCases.map(button))
        buttons.orientation = .vertical
        buttons.spacing = 10
        addChild(content)
        for view in [rail, edge, buttons, content.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(rail)
        root.addSubview(edge)
        root.addSubview(content.view)
        rail.addSubview(buttons)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.topAnchor.constraint(equalTo: root.topAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 44),
            edge.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            buttons.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            buttons.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            content.view.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            content.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: root.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func button(_ target: Space) -> NSButton {
        let image = NSImage(systemSymbolName: target.symbol, accessibilityDescription: target.name)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        let button = RailButton(image: image, target: self, action: #selector(pick))
        button.tag = Space.allCases.firstIndex(of: target) ?? 0
        button.isBordered = false
        button.refusesFirstResponder = true
        button.toolTip = "\(target.name) ⌘\(target.key)"
        let selected = target == space
        button.isSelectedSpace = selected
        button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        button.setAccessibilityValue(selected ? "selected" : nil)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 34)])
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.switchSpace(Space.allCases[sender.tag], from: view.window)
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

func loadAnswers(_ sessionPath: String) -> [String: TutorAnswer] {
    (try? JSONDecoder().decode([String: TutorAnswer].self, from: Data(contentsOf: answersURL(sessionPath)))) ?? [:]
}

func writeAnswers(_ answers: [String: TutorAnswer], _ sessionPath: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(answers).write(to: answersURL(sessionPath), options: .atomic)
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
        height?.constant = max(used, isEditable ? 64 : 0)
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

/// The Tutor space: one session as a worksheet — rungs oldest first, the current rung's fields answered in place.
final class TutorController: NSObject, NSWindowDelegate, NSTextViewDelegate {
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
    var onClose: (() -> Void)?
    let renderer = Renderer()
    let window: NSWindow
    let sidebarScroll = NSTextView.scrollableTextView()
    let scroll = NSScrollView()
    let document = FlippedView()
    let column = NSStackView()
    var fields: [AnswerField] = []
    var focusRungView: NSView?
    weak var picker: NSSegmentedControl?
    weak var hint: NSTextField?

    var sidebar: NSTextView { sidebarScroll.documentView as! NSTextView }
    var currentRungID: String? { session.flatMap { currentRung($0, answers)?.id } }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.title = "Tutor"
        window.contentMinSize = NSSize(width: 64 + 240 + Self.margin + Self.column + 48, height: 480)

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
        let detailVC = NSViewController()
        detailVC.view = scroll

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailVC))
        window.contentViewController = SpaceContainer(space: .tutor, content: split)
        window.setContentSize(NSSize(width: 1180, height: 780))
    }

    func show(path: String) {
        if path != self.path {
            self.path = path
            drafts = UserDefaults.standard.dictionary(forKey: "tutor.drafts." + path) as? [String: [String: String]] ?? [:]
            confidence = UserDefaults.standard.dictionary(forKey: "tutor.confidence." + path) as? [String: Int] ?? [:]
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

    func showEmpty() {
        path = nil
        session = nil
        rebuild()
        column.addArrangedSubview(tutorText(renderer.tutorMarkdown("No tutor sessions in `~/.dotfiles/show/tutor` yet. Claude starts one with `show --tutor <file>`."), width: Self.column))
        sidebar.textStorage?.setAttributedString(NSAttributedString(string: "Tutor", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: NSColor.labelColor]))
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
        answers = loadAnswers(path)
        let current = currentRung(fresh, answers)?.id
        let moved = !hasRendered || current != lastCurrent
        let focusedField = window.firstResponder as? AnswerField
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
            window.makeFirstResponder(field)
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
        UserDefaults.standard.set(drafts, forKey: "tutor.drafts." + path)
        UserDefaults.standard.set(confidence, forKey: "tutor.confidence." + path)
    }

    func focusFirstField() {
        if let field = fields.first(where: { $0.string.isEmpty }) ?? fields.first {
            window.makeFirstResponder(field)
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
        window.title = session.title
        window.subtitle = "Tutor · \(session.rungs.filter { answers[$0.id] != nil }.count) of \(session.rungs.count) answered"
        let current = currentRung(session, answers)
        let focusID = current?.id ?? session.rungs.last?.id
        var fresh: [NSView] = []
        var seen: Set<String> = []
        for rung in session.rungs {
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
            send.keyEquivalent = "\r"
            send.keyEquivalentModifierMask = [.command]
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
        var all = loadAnswers(path)
        all[rung.id] = TutorAnswer(parts: texts, confidence: level.map { confidenceLevels[$0].0 }, at: ISO8601DateFormatter().string(from: Date()))
        do {
            try writeAnswers(all, path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your answer"
            alert.informativeText = "\(error)"
            alert.beginSheetModal(for: window)
            return
        }
        drafts[rung.id] = nil
        confidence[rung.id] = nil
        saveDrafts()
        reload()
        if let replyTo = session.replyTo, let failure = claudeSay(replyTo, "tutor answer: \(path) rung \(rung.id)") {
            showClaudeSayFailure(replyTo: replyTo, saved: "Your answer is saved.", detail: failure, window: window)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let field = notification.object as? AnswerField, let id = currentRungID else { return }
        drafts[id, default: [:]][field.partID] = field.string
        hint?.isHidden = true
        saveDrafts()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let index = fields.firstIndex(where: { $0 === textView }), fields.count > 0 else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            window.makeFirstResponder(fields[(index + 1) % fields.count])
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window.makeFirstResponder(fields[(index + fields.count - 1) % fields.count])
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose?()
    }

    func snapshot(to output: String) {
        timer?.invalidate()
        guard let view = window.contentView else { return }
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        let worksheet = (output as NSString).deletingPathExtension + "-worksheet.png"
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            for (target, file) in [(view, output), (document as NSView, worksheet)] {
                guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
                target.cacheDisplay(in: target.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
        }
    }
}

func fileStamp(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(modified)-\(attributes[.size] as? Int ?? 0)"
}

/// `--tutor-check`: parse a session plus its answers and print what the Tutor space would show, without a window.
func tutorCheck(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        let session = try loadTutorSession(path)
        var answers: [String: TutorAnswer] = [:]
        if FileManager.default.fileExists(atPath: answersURL(path).path) {
            answers = try JSONDecoder().decode([String: TutorAnswer].self, from: Data(contentsOf: answersURL(path)))
        }
        print("session: \(session.title)")
        print("replyTo: \(session.replyTo ?? "-")")
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

/// One Show process for every deck: `show <deck>` hands the file to the running app, which opens it as a tab or brings its tab forward.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var open: [String: DeckController] = [:]
    var tutor: TutorController?
    weak var lastDeckWindow: NSWindow?
    let decksMenu = NSMenu(title: "Decks")
    let tutorSessionsMenu = NSMenu(title: "Sessions")
    let launchPaths: [String]

    init(launchPaths: [String]) {
        self.launchPaths = launchPaths
    }

    var watcher: Timer?
    let launchedBuild = modificationDate(buildStamp)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, self.open.values.contains(where: { $0.window === window }) else { return }
            self.lastDeckWindow = window
        }
        launchPaths.forEach(openPath)
        NSApp.activate(ignoringOtherApps: true)
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.stayCurrent() }
    }

    /// Reloads decks edited on disk, and relaunches into a newer build once the launcher finishes one.
    private func stayCurrent() {
        for controller in open.values where modificationDate(controller.path) != controller.deckModified {
            controller.reload()
        }
        if let built = modificationDate(buildStamp), built != launchedBuild {
            relaunch()
        }
    }

    private func relaunch() {
        watcher?.invalidate()
        let tabs = (NSApp.keyWindow?.tabbedWindows ?? NSApp.orderedWindows).compactMap { window in
            open.values.first { $0.window === window }
        }
        let ordered = tabs + open.values.filter { controller in !tabs.contains { $0 === controller } }
        ordered.forEach { $0.saveNote() }
        let key = open.values.first { $0.window.isKeyWindow }?.path
        var paths = ordered.map(\.path).filter { $0 != key } + [key].compactMap { $0 }
        if let tutor, let session = tutor.path {
            tutor.saveDrafts()
            paths.insert(session, at: tutor.window.isKeyWindow ? paths.count : 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; open -a \"$0\" \"$@\"", Bundle.main.bundlePath] + paths
        try? process.run()
        NSApp.terminate(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.map(\.path).forEach(openPath)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        open.values.forEach { $0.saveNote() }
    }

    /// Tutor sessions open in the Tutor space; everything else is a deck.
    func openPath(_ rawPath: String) {
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        if isTutorFile(path) {
            openTutor(path, from: NSApp.keyWindow)
        } else {
            openDeck(path)
        }
    }

    func openTutor(_ path: String?, from source: NSWindow?) {
        let controller: TutorController
        if let tutor {
            controller = tutor
        } else {
            controller = TutorController()
            controller.onClose = { [weak self] in self?.tutor = nil }
            controller.window.center()
            tutor = controller
        }
        match(controller.window, to: source)
        if let path {
            controller.show(path: path)
        } else if controller.path == nil {
            if let newest = newestJSON(in: tutorDirectory, where: isTutorFile).first {
                controller.show(path: newest)
            } else {
                controller.showEmpty()
            }
        }
        controller.window.makeKeyAndOrderFront(nil)
        controller.focusFirstField()
    }

    func switchSpace(_ space: Space, from source: NSWindow?) {
        switch space {
        case .tutor:
            openTutor(nil, from: source)
        case .decks:
            let remembered = lastDeckWindow.flatMap { window in open.values.contains { $0.window === window } ? window : nil }
            if let window = remembered ?? open.values.first?.window {
                match(window, to: source)
                window.makeKeyAndOrderFront(nil)
            } else if let newest = newestJSON(in: decksDirectory, where: { (try? loadDeck($0)) != nil }).first {
                openDeck(newest)
                if let window = open.values.first?.window {
                    match(window, to: source)
                }
            } else {
                NSSound.beep()
            }
        }
    }

    private func match(_ window: NSWindow, to source: NSWindow?) {
        guard let source, source !== window, source.isVisible else { return }
        window.setFrame(source.frame, display: true)
    }

    @objc func showSpace(_ sender: NSMenuItem) {
        switchSpace(Space.allCases[sender.tag], from: NSApp.keyWindow)
    }

    @objc func pickConfidence(_ sender: NSMenuItem) {
        tutor?.choose(confidence: sender.tag)
    }

    @objc func openListedTutor(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openTutor(path, from: NSApp.keyWindow)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(pickConfidence) else { return true }
        return tutor?.window.isKeyWindow == true && tutor?.currentRungID != nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func openDeck(_ rawPath: String) {
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        if let existing = open[path] {
            existing.reload()
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let deck: Deck
        do {
            deck = try loadDeck(path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't open \((path as NSString).lastPathComponent)"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        let controller = DeckController(path: path, deck: deck)
        controller.onClose = { [weak self] in self?.open[path] = nil }
        open[path] = controller
        let deckWindows = open.values.filter { $0 !== controller }.map(\.window)
        if let host = deckWindows.first(where: \.isKeyWindow) ?? deckWindows.first {
            host.addTabbedWindow(controller.window, ordered: .above)
        } else {
            controller.window.center()
        }
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.table)
    }

    @objc func openListedDeck(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openDeck(path)
    }

    @objc func openOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: decksDirectory)
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.map(\.path).forEach(openPath)
    }

    @objc func reloadKey(_ sender: Any?) {
        open.values.first { $0.window.isKeyWindow }?.reload()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === tutorSessionsMenu {
            for path in newestJSON(in: tutorDirectory, where: isTutorFile) {
                guard let session = try? loadTutorSession(path) else { continue }
                let item = NSMenuItem(title: "\(session.title)  —  \((path as NSString).lastPathComponent)", action: #selector(openListedTutor), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.state = tutor?.path == path ? .on : .off
                menu.addItem(item)
            }
            if menu.items.isEmpty {
                menu.addItem(withTitle: "No sessions in ~/.dotfiles/show/tutor", action: nil, keyEquivalent: "")
            }
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: decksDirectory)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") && !$0.hasSuffix(".answers.json") }
            .map { (decksDirectory as NSString).appendingPathComponent($0) }
        let listed = files.compactMap { path -> (String, Deck, Date)? in
            guard let deck = try? loadDeck(path) else { return nil }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            return (path, deck, modified)
        }.sorted { $0.2 > $1.2 }
        for (path, deck, _) in listed {
            let store = SignOffStore(deckPath: path)
            let done = deck.sections.filter { store.entries[$0.key]?.signed == true }.count
            let item = NSMenuItem(title: "\(deck.title)  —  \(done)/\(deck.sections.count)", action: #selector(openListedDeck), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = open[path] == nil ? .off : .on
            menu.addItem(item)
        }
        if !listed.isEmpty {
            menu.addItem(.separator())
        }
        let other = NSMenuItem(title: "Open Deck…", action: #selector(openOther), keyEquivalent: "o")
        other.target = self
        menu.addItem(other)
        let reload = NSMenuItem(title: "Reload Deck", action: #selector(reloadKey), keyEquivalent: "r")
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
        let spaceItem = NSMenuItem()
        main.addItem(spaceItem)
        let spaceMenu = NSMenu(title: "Space")
        for (i, space) in Space.allCases.enumerated() {
            let item = NSMenuItem(title: space.name, action: #selector(showSpace), keyEquivalent: space.key)
            item.tag = i
            item.target = self
            spaceMenu.addItem(item)
        }
        spaceItem.submenu = spaceMenu
        let tutorItem = NSMenuItem()
        main.addItem(tutorItem)
        let tutorMenu = NSMenu(title: "Tutor")
        tutorSessionsMenu.delegate = self
        tutorMenu.addItem(withTitle: "Sessions", action: nil, keyEquivalent: "").submenu = tutorSessionsMenu
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
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

/// Offscreen render of one deck for checks; no window is shown and no running Show is touched.
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    let path: String
    let output: String

    init(path: String, output: String) {
        self.path = path
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if isTutorFile(path) {
                let tutor = TutorController()
                tutor.show(path: path)
                tutor.snapshot(to: output)
            } else {
                DeckController(path: path, deck: try loadDeck(path)).snapshot(to: output)
            }
        } catch {
            FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        }
        NSApp.terminate(nil)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--tutor-check") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write("usage: Show --tutor-check <session.json>\n".data(using: .utf8)!)
        exit(64)
    }
    exit(tutorCheck(arguments[flag + 1]))
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
    guard let path = deckPaths.first else {
        FileHandle.standardError.write("usage: Show <deck.json> --snapshot out.png\n".data(using: .utf8)!)
        exit(64)
    }
    app.setActivationPolicy(.prohibited)
    delegate = SnapshotDelegate(path: path, output: snapshotPath)
} else {
    app.setActivationPolicy(.regular)
    delegate = AppDelegate(launchPaths: deckPaths)
}
app.delegate = delegate
app.run()
