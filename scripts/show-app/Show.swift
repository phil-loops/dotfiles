// Show — one native app for walkthrough decks; each deck opens as a labelled tab. Renders a JSON file of sections:
// { "title", "subtitle"?, "sections": [{ "id"?, "group", "title", "tag"?, "body" (markdown), "url"? (a live page shown instead of the body) }] }
// Sign-offs and notes save beside the deck as <deck>.signoff.json; "replyTo" names the claude-say session that Submit notifies.
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

let decksDirectory = ("~/.dotfiles/show" as NSString).expandingTildeInPath

/// One deck in one window; windows share a tab group, so each deck is a labelled tab.
final class DeckController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController())
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 380
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController()))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 780))
        apply(deck, keepingSelection: nil)
    }

    var selectedSection: Section? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, case .item(let i) = rows[table.selectedRow] else { return nil }
        return deck.sections[i]
    }

    /// Re-reads the deck and its sign-offs from disk, keeping the selected section when it still exists.
    func reload() {
        guard let fresh = try? loadDeck(path) else { return }
        store = SignOffStore(deckPath: path)
        apply(fresh, keepingSelection: selectedSection?.key)
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
        web.setContentHuggingPriority(.defaultLow, for: .vertical)

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

        let stack = NSStackView(views: [scroll, web, divider, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for view in [scroll, web, divider, bar] {
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

    @objc private func saveNote() {
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
            showSubmitFailure("\(error)")
            return
        }
        guard process.terminationStatus == 0 else {
            showSubmitFailure(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            return
        }
        submit.title = "Submitted ✓"
    }

    private func showSubmitFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't reach Claude session \(deck.replyTo ?? "")"
        alert.informativeText = "Your sign-offs are saved. \(detail)"
        alert.beginSheetModal(for: window)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
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

/// One Show process for every deck: `show <deck>` hands the file to the running app, which opens it as a tab or brings its tab forward.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var open: [String: DeckController] = [:]
    let decksMenu = NSMenu(title: "Decks")
    let launchPaths: [String]

    init(launchPaths: [String]) {
        self.launchPaths = launchPaths
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        launchPaths.forEach(openDeck)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.map(\.path).forEach(openDeck)
        NSApp.activate(ignoringOtherApps: true)
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
        if let host = NSApp.keyWindow ?? open.values.first(where: { $0 !== controller })?.window {
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
        panel.urls.map(\.path).forEach(openDeck)
    }

    @objc func reloadKey(_ sender: Any?) {
        open.values.first { $0.window.isKeyWindow }?.reload()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: decksDirectory)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") }
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
            DeckController(path: path, deck: try loadDeck(path)).snapshot(to: output)
        } catch {
            FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        }
        NSApp.terminate(nil)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
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
