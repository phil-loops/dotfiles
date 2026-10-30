import AppKit
import WebKit

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

/// One deck: its section list beside the rendered section and the sign-off bar. It owns no window; its workspace hosts `viewController`.
final class DeckController: NSObject, WKNavigationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
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
    let composer = ThreadComposer()
    var composerScroll: NSScrollView!
    var composerHeight: NSLayoutConstraint!
    /// The section whose draft the composer holds.
    var composerKey: String?
    let send = NSButton(title: "Send", target: nil, action: nil)
    let progress = NSTextField(labelWithString: "")
    let submit = NSButton(title: "Submit", target: nil, action: nil)
    let live = LivePanel()
    var actionBar: NSView!
    var actionDivider: NSView!
    var deckModified: Date?
    var onTitleChange: (() -> Void)?
    var thread: [String: [ThreadMessage]] = [:]
    var threadStamp = ""
    let delivery: ThreadDelivery
    let freshness = BranchFreshness()
    /// "branch moved since this page was written", above a forest page whose branch tip changed.
    let movedLine = NSTextField(labelWithString: "")

    init(path: String, deck: Deck) {
        self.path = path
        self.deck = deck
        store = SignOffStore(deckPath: path)
        delivery = ThreadDelivery.delivery(for: path)
        renderer.baseDirectory = (path as NSString).deletingLastPathComponent
        super.init()
        live.owner = self
        _ = Self.forestKeys
        delivery.onChange = { [weak self] in self?.refreshThread(stickToBottom: true) }
        freshness.onChange = { [weak self] in self?.freshnessChanged() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.freshness.refresh(self.deck)
        }
        let sidebar = NSSplitViewItem(viewController: sidebarController())
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 360
        sidebar.preferredThicknessFraction = 0.28
        viewController.addSplitViewItem(sidebar)
        viewController.addSplitViewItem(NSSplitViewItem(viewController: detailController()))
        deckModified = modificationDate(path)
        thread = loadThread(path)
        threadStamp = fileStamp(threadURL(path).path)
        apply(deck, keepingSelection: prefs.string(forKey: selectionKey))
        freshness.refresh(deck)
    }

    var window: NSWindow? { viewController.view.window }
    var title: String { deck.title }
    /// In a forest deck, each branch section's merge number and nesting depth.
    private var branchPlaces: [Int: (number: Int, depth: Int)] = [:]
    private var settled = false

    /// Gives the section list its 250pt column the first time the deck is shown; after that the divider stays where it's dragged.
    func settleColumns() {
        guard !settled, viewController.view.window != nil else { return }
        settled = true
        viewController.view.layoutSubtreeIfNeeded()
        viewController.splitView.setPosition(250, ofDividerAt: 0)
    }
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
        let origin = textScroll.contentView.bounds.origin
        let listOrigin = (table.enclosingScrollView?.contentView.bounds.origin) ?? .zero
        store = SignOffStore(deckPath: path)
        thread = loadThread(path)
        threadStamp = fileStamp(threadURL(path).path)
        apply(fresh, keepingSelection: kept)
        freshness.refresh(fresh)
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
        }
    }

    func reloadIfChanged() {
        if modificationDate(path) != deckModified {
            reload()
        } else if fileStamp(threadURL(path).path) != threadStamp {
            thread = loadThread(path)
            threadStamp = fileStamp(threadURL(path).path)
            refreshThread(stickToBottom: true)
        }
    }

    private func apply(_ deck: Deck, keepingSelection key: String?) {
        self.deck = deck
        rows = []
        branchPlaces = [:]
        if deck.isForest {
            let order = ForestOrder(deck)
            if !order.overview.isEmpty {
                rows.append(.header("Overview"))
                rows += order.overview.map(Row.item)
            }
            if !order.branches.isEmpty {
                rows.append(.header("Merge order"))
                for branch in order.branches {
                    rows.append(.item(branch.index))
                    branchPlaces[branch.index] = (branch.number, branch.depth)
                }
            }
        } else if deck.isLive {
            rows = liveRows(deck)
        } else {
            var lastGroup: String?
            for (i, section) in deck.sections.enumerated() {
                if section.group != lastGroup {
                    rows.append(.header(section.group))
                    lastGroup = section.group
                }
                rows.append(.item(i))
            }
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
        freshness.refreshNow(deck)
        freshnessChanged()
        if ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_REGENERATE"] != nil {
            print("regenerate: " + regenerateSelected())
            delivery.settle(within: 10)
        }
        if let message = ProcessInfo.processInfo.environment["SHOW_SNAPSHOT_SEND"] {
            composer.string = message
            sendMessage()
            delivery.settle(within: 10)
        }
        guard let section = selectedSection, section.url == nil else { return }
        renderer.columnWidth = text.bounds.width > 300 ? text.bounds.width - 96 - 2 * (text.textContainer?.lineFragmentPadding ?? 5) : 640
        text.textStorage?.setAttributedString(page(section))
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
        text.delegate = self
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
        composer.isRichText = false
        composer.allowsUndo = true
        composer.font = inkFont
        composer.textColor = inkColor
        composer.insertionPointColor = inkColor
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 6, height: 6)
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.isVerticallyResizable = true
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.delegate = self
        let composerScroll = NSScrollView()
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.drawsBackground = true
        composerScroll.backgroundColor = .quaternaryLabelColor
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 6
        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 34)
        composerHeight.isActive = true
        self.composerScroll = composerScroll
        send.target = self
        send.action = #selector(sendMessage)
        send.bezelStyle = .rounded
        send.toolTip = "Send to Claude (⌘↩ in the reply field)"
        submit.target = self
        submit.action = #selector(commandReturn)
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        submit.keyEquivalentModifierMask = [.command]
        submit.toolTip = "Tell Claude you're done (⌘↩ outside the reply field)"
        let bar = NSStackView(views: [signed, composerScroll, send, submit])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 14
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 48, bottom: 14, right: 24)
        composerScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.heightAnchor.constraint(equalTo: composerScroll.heightAnchor, constant: 26).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        actionBar = bar
        actionDivider = divider

        movedLine.font = .systemFont(ofSize: 12, weight: .medium)
        movedLine.textColor = .systemOrange
        movedLine.lineBreakMode = .byTruncatingTail
        let moved = NSStackView(views: [movedLine])
        moved.edgeInsets = NSEdgeInsets(top: 14, left: 53, bottom: 0, right: 24)
        moved.isHidden = true

        let stack = NSStackView(views: [live.header, moved, page, divider, bar, live.bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [live.header, moved, page, divider, bar, live.bar] {
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

    /// Keeps the reply being typed as the section's draft, so a reload, a section switch or a relaunch never loses it.
    @objc func saveNote() {
        guard !deck.isLive, let key = composerKey else { return }
        prefs.set(composer.string, forKey: draftKey(key))
    }

    private func draftKey(_ section: String) -> String { "thread.draft.\(path).\(section)" }

    /// ⌘↩ sends the reply when the reply field holds one, otherwise submits the deck as before.
    @objc private func commandReturn() {
        if NSApp.currentEvent?.type == .keyDown, window?.firstResponder === composer,
           !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendMessage()
        } else {
            submitReview()
        }
    }

    /// Appends the reply to the section's thread, mirrors it into the sign-off `note`, and hands it to Claude.
    @objc func sendMessage() {
        guard !deck.isLive, let section = selectedSection else { return }
        let value = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            try appendThreadMessage(ThreadMessage(at: ISO8601DateFormatter().string(from: Date()), from: "phil", text: value), section: section.key, deckPath: path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save your reply"
            alert.informativeText = "\(error)"
            presentAlert(alert, in: window)
            return
        }
        store.update(section.key) { $0.note = value }
        composer.string = ""
        composer.didChangeText()
        fitComposer()
        saveNote()
        thread = loadThread(path)
        threadStamp = fileStamp(threadURL(path).path)
        reloadSelectedRow()
        delivery.send(delivery.threadLine(section: section.key), key: section.key, replyTo: deck.replyTo)
        refreshThread(stickToBottom: true)
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

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === composer else { return }
        fitComposer()
        saveNote()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard textView === text, (link as? URL)?.absoluteString == "show-thread:retry", let key = selectedSection?.key else { return false }
        delivery.retry(key)
        return true
    }

    /// Grows the reply field with its text, up to about six lines.
    private func fitComposer() {
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height) + composer.textContainerInset.height * 2
        composerHeight.constant = min(max(used, 34), 150)
    }

    /// The section's page: its body, then (outside live decks) its conversation.
    private func page(_ section: Section) -> NSAttributedString {
        let body = renderer.render(section)
        guard !deck.isLive else { return body }
        let status = delivery.status[section.key]
        return body + threadText(thread[section.key] ?? [], status: status, renderer: renderer, width: renderer.columnWidth)
    }

    /// Re-renders the open page after its thread or delivery changed, holding the scroll, or following the conversation down when asked.
    func refreshThread(stickToBottom: Bool) {
        if fileStamp(threadURL(path).path) != threadStamp {
            thread = loadThread(path)
            threadStamp = fileStamp(threadURL(path).path)
        }
        guard let section = selectedSection, section.url == nil, !deck.isLive else { return }
        let clip = textScroll.contentView
        let origin = clip.bounds.origin
        let wasAtBottom = clip.bounds.maxY >= text.bounds.height - 60
        text.textStorage?.setAttributedString(page(section))
        if let container = text.textContainer {
            text.layoutManager?.ensureLayout(for: container)
        }
        if stickToBottom || wasAtBottom {
            text.scrollToEndOfDocument(nil)
        } else {
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            textScroll.reflectScrolledClipView(clip)
        }
    }


    private func reloadSelectedRow() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateProgress()
    }

    private func updateProgress() {
        actionBar.isHidden = deck.isLive
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

    /// Refreshes the live header, including how long ago the file changed; ticks once a second.
    func updateStatusLine() {
        live.update(modified: deckModified)
        let moved = deck.isForest ? selectedSection.flatMap(freshness.moved) : nil
        movedLine.superview?.isHidden = moved == nil
        movedLine.stringValue = moved.map { "◆  branch moved since this page was written · \($0.written.prefix(7)) → \($0.now.prefix(7)) · ⌘⇧R regenerates it" } ?? ""
    }

    private func freshnessChanged() {
        if rows.count > 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: 0))
        }
        updateStatusLine()
    }

    /// ⌘⇧R: asks whoever answers for the deck to rewrite the selected branch's page; returns what to say at the foot of the shelf.
    func regenerateSelected() -> String {
        guard let section = selectedSection, section.rank != nil else {
            return "⌘⇧R regenerates a branch page; pick a branch first"
        }
        delivery.send("regenerate page \(section.key) — \(path)", key: "regen:" + section.key, replyTo: deck.replyTo)
        return "Asked Claude to regenerate \(section.key)"
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
            let title = NSTextField(labelWithString: "")
            let place = branchPlaces[i]
            let number = place.map { NSAttributedString(string: "\($0.number)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]) } ?? NSAttributedString()
            title.attributedStringValue = number + sectionMark(section, selected: row == table.selectedRow)
                + NSAttributedString(string: section.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
                + (deck.isLive ? liveFlag(section) : NSAttributedString())
                + (freshness.moved(section) == nil ? NSAttributedString() : NSAttributedString(string: "  moved", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemOrange]))
            title.maximumNumberOfLines = 1
            title.cell?.truncatesLastVisibleLine = true
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
            let indent = 8 + CGFloat(min(place?.depth ?? 0, 6)) * 12
            let cell = NSTableCellView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            for view in stack.arrangedSubviews {
                view.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -8 - indent).isActive = true
            }
            return cell
        }
    }

    /// The list's mark for a section: ◆ a branch that moved since its page was written, ● signed, ◆ has a note, ◐ the open section, ○ not yet. Live decks carry none.
    private func sectionMark(_ section: Section, selected: Bool) -> NSAttributedString {
        guard !deck.isLive else { return liveMark(section, current: deck.status?.current) }
        let entry = store.entries[section.key]
        let (mark, color): (String, NSColor)
        if freshness.moved(section) != nil {
            (mark, color) = ("◆", .systemOrange)
        } else if entry?.signed == true {
            (mark, color) = ("●", .secondaryLabelColor)
        } else if entry?.note.isEmpty == false {
            (mark, color) = ("◆", .systemOrange)
        } else if selected {
            (mark, color) = ("◐", .labelColor)
        } else {
            (mark, color) = ("○", .tertiaryLabelColor)
        }
        return NSAttributedString(string: mark + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .baselineOffset: 1])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if rows.count > 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: 0))
        }
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
            renderer.columnWidth = text.bounds.width > 300 ? text.bounds.width - 96 - 2 * (text.textContainer?.lineFragmentPadding ?? 5) : 640
            text.textStorage?.setAttributedString(page(section))
            text.scroll(.zero)
        }
        let entry = store.entries[section.key]
        signed.state = entry?.signed == true ? .on : .off
        if composerKey != section.key {
            saveNote()
            composerKey = section.key
            composer.string = prefs.string(forKey: draftKey(section.key)) ?? ""
            composer.didChangeText()
            fitComposer()
        }
        live.update(modified: deckModified)
    }
}

/// Runs `claude-say <replyTo> <message>`; returns what went wrong, or nil once it's delivered.
func claudeSay(_ replyTo: String, _ message: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudeSayPath)
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
