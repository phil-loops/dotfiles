import AppKit

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

/// How well `query` matches `text` as a subsequence, lower is better; nil when it doesn't match at all.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let needle = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !needle.isEmpty else { return 0 }
    let hay = Array(text.lowercased())
    var score = 0
    var at = 0
    var last = -1
    for character in needle {
        guard let found = hay[at...].firstIndex(of: character) else { return nil }
        let wordStart = found == 0 || !(hay[found - 1].isLetter || hay[found - 1].isNumber)
        score += (last >= 0 ? found - last - 1 : found) - (wordStart ? 3 : 0)
        last = found
        at = found + 1
    }
    return score
}

/// ⌘O or `/`: a fuzzy finder over the current workspace's shelf. Return opens the match, Esc or a click outside closes it.
final class FinderOverlay: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = NSTextField()
    let table = NSTableView()
    let panel = NSVisualEffectView()
    private var entries: [ShelfEntry] = []
    private(set) var matches: [ShelfEntry] = []
    var onPick: ((ShelfEntry) -> Void)?
    var onClose: (() -> Void)?

    init(entries: [ShelfEntry], workspace: Workspace) {
        self.entries = entries
        super.init(frame: .zero)
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        field.placeholderString = "Find in \(workspace.name)"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("match")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let divider = NSBox()
        divider.boxType = .separator
        for view in [panel, field, divider, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(panel)
        panel.addSubview(field)
        panel.addSubview(divider)
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.widthAnchor.constraint(equalToConstant: 520),
            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            scroll.heightAnchor.constraint(equalToConstant: 8 * 40),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        filter()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onClose?()
        }
    }

    func search(_ query: String) {
        field.stringValue = query
        filter()
    }

    private func filter() {
        let query = field.stringValue
        matches = entries.compactMap { entry -> (ShelfEntry, Int)? in
            let name = ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let score = [fuzzyScore(query, entry.title), fuzzyScore(query, name).map { $0 + 2 }].compactMap { $0 }.min()
            return score.map { (entry, $0) }
        }
        .sorted { ($0.1, $1.0.touched) < ($1.1, $0.0.touched) }
        .map(\.0)
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(0, table.selectedRow + step), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func pickSelected() {
        guard table.selectedRow >= 0, table.selectedRow < matches.count else {
            NSSound.beep()
            return
        }
        onPick?(matches[table.selectedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(matches.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 40 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = QuietRowView()
        rowView.selectionHighlightStyle = .none
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        if matches.isEmpty {
            label.stringValue = "No matches"
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 13)
        } else {
            let entry = matches[row]
            label.attributedStringValue = NSAttributedString(string: entry.state.mark + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: entry.state.markColor])
                + NSAttributedString(string: entry.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
                + NSAttributedString(string: "   " + entry.progress, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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

    private(set) var finder: FinderOverlay?
    /// The key sheet or the New… prompt, whichever covers the window; the finder keeps its own slot.
    private(set) var overlay: NSView?
    var focusOutline: FocusOutline?

    func showOverlay(_ cover: NSView) {
        hideOverlay()
        hideFinder()
        pinned(cover, in: view)
        overlay = cover
    }

    func hideOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Lays the finder over the whole window, searching only `entries`.
    func showFinder(entries: [ShelfEntry], onPick: @escaping (ShelfEntry) -> Void) {
        hideFinder()
        hideOverlay()
        let overlay = FinderOverlay(entries: entries, workspace: active)
        overlay.onPick = { [weak self] entry in
            self?.hideFinder()
            onPick(entry)
        }
        overlay.onClose = { [weak self] in self?.hideFinder() }
        pinned(overlay, in: view)
        finder = overlay
        view.window?.makeFirstResponder(overlay.field)
    }

    func hideFinder() {
        finder?.removeFromSuperview()
        finder = nil
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

/// One spelling per file, so the shelf, the open document and saved state agree (`/tmp` and `/private/tmp` included).
func canonicalPath(_ raw: String) -> String {
    URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
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
    let folders = [decksDirectory, tutorDirectory].flatMap { directory in
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".signoff.json") && !$0.hasSuffix(".answers.json") }
            .map { canonicalPath((directory as NSString).appendingPathComponent($0)) }
    }
    let known = Set(folders)
    return folders + registeredLiveRuns().filter { !known.contains($0) }
}

/// Live decks Show has opened from anywhere (runs live in their own run directories), from `live-runs.json`; missing files left out.
func registeredLiveRuns() -> [String] {
    guard let registry = liveRunsPath,
          let runs = try? JSONDecoder().decode([LiveRun].self, from: Data(contentsOf: URL(fileURLWithPath: registry))) else { return [] }
    var seen = Set<String>()
    return runs.map { canonicalPath($0.path) }.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
}

/// Whether `path` sits in the library folders, where ⌫ archives it, rather than only in `live-runs.json`, where ⌫ just forgets it.
func isInLibraryFolders(_ path: String) -> Bool {
    [decksDirectory, tutorDirectory].contains { canonicalPath($0) == (path as NSString).deletingLastPathComponent }
}

/// Drops `path` from `live-runs.json`. The run's own files are never touched.
func forgetLiveRun(_ path: String) throws {
    guard let registry = liveRunsPath else { return }
    let url = URL(fileURLWithPath: registry)
    let runs = (try? JSONDecoder().decode([LiveRun].self, from: Data(contentsOf: url))) ?? []
    let kept = runs.filter { canonicalPath($0.path) != path }
    guard kept.count != runs.count else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(kept).write(to: url, options: .atomic)
}

/// A cheap fingerprint of the library folders: changes when any document or sidecar is added, removed or rewritten.
func librarySignature() -> String {
    [decksDirectory, tutorDirectory].map { directory in
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().map { name in
            "\(name):\(fileStamp((directory as NSString).appendingPathComponent(name)))"
        }.joined(separator: "|")
    }.joined(separator: "#") + "#" + ([liveRunsPath].compactMap { $0 } + registeredLiveRuns()).map(fileStamp).joined(separator: "|")
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
        case "done": state = .done
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

func relativeTime(_ date: Date) -> String {
    guard date > .distantPast else { return "" }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    if seconds < 86400 * 2 { return "yesterday" }
    if seconds < 86400 * 14 { return "\(seconds / 86400)d ago" }
    let format = DateFormatter()
    format.dateFormat = "MMM d"
    return format.string(from: date)
}

extension ShelfState {
    var mark: String {
        switch self {
        case .waiting: return "◆"
        case .running: return "◉"
        case .done: return "●"
        }
    }

    var markColor: NSColor {
        switch self {
        case .waiting, .running: return .systemOrange
        case .done: return .secondaryLabelColor
        }
    }

    var groupName: String {
        switch self {
        case .waiting: return "Waiting on you"
        case .running: return "Running"
        case .done: return "Done"
        }
    }
}

enum ShelfRow {
    case header(ShelfState, Int)
    case entry(ShelfEntry)
    case fold(hidden: Int, expanded: Bool)
    case dueHeader(Int)
    case due(DueConcept)
    case dueFold(hidden: Int, expanded: Bool)
}

/// Moves a document and its sidecars into `~/.dotfiles/show/archive/`; nothing is ever deleted. Returns where the document went.
func archiveDocument(_ path: String) throws -> String {
    let archive = (decksDirectory as NSString).appendingPathComponent("archive")
    try FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    var target = stem
    if FileManager.default.fileExists(atPath: (archive as NSString).appendingPathComponent(stem + ".json")) {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        target = stem + "-" + format.string(from: Date())
    }
    let moves = [(path, ".json")] + zip(sidecarPaths(path), [".signoff.json", ".answers.json"]).map { ($0, $1) }
    for (source, suffix) in moves where FileManager.default.fileExists(atPath: source) {
        try FileManager.default.moveItem(atPath: source, toPath: (archive as NSString).appendingPathComponent(target + suffix))
    }
    return (archive as NSString).appendingPathComponent(target + ".json")
}

/// The shelf's list: ⌫ archives the selected document.
final class ShelfTable: NSTableView {
    var onArchive: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onArchive?()
        } else {
            super.keyDown(with: event)
        }
    }
}


/// One workspace: a shelf of its documents beside the one open document, with its own back history, typed text and focus,
/// kept alive while another workspace is in front.
final class WorkspaceController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let foldAfter = 5
    let workspace: Workspace
    private(set) var current: String?
    private(set) var decks: [String: DeckController] = [:]
    private(set) var back: [String] = []
    private(set) var entries: [ShelfEntry] = []
    private var rows: [ShelfRow] = []
    private var doneExpanded = false
    private var syncingSelection = false
    let tutor: TutorController?
    let split = NSSplitViewController()
    let shelf = ShelfTable()
    let statusLabel = NSTextField(labelWithString: "")
    let host = NSView()
    var onTitleChange: (() -> Void)?
    var onLibraryChange: (() -> Void)?
    private weak var savedResponder: NSResponder?
    private var savedRange: NSRange?
    private var statusClear: Timer?

    init(workspace: Workspace) {
        self.workspace = workspace
        tutor = workspace == .learn ? TutorController() : nil
        super.init(nibName: nil, bundle: nil)
        tutor?.onTitleChange = { [weak self] in self?.onTitleChange?() }
        tutor?.onStartRetest = { [weak self] concept in self?.startTutor(.retest(concept: concept)) }
        back = prefs.stringArray(forKey: "workspace.\(workspace.rawValue).back") ?? []
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("shelf"))
        shelf.addTableColumn(column)
        shelf.headerView = nil
        shelf.style = .sourceList
        shelf.backgroundColor = .clear
        shelf.rowSizeStyle = .custom
        shelf.dataSource = self
        shelf.delegate = self
        shelf.onArchive = { [weak self] in self?.archiveSelected() }
        shelf.target = self
        shelf.doubleAction = #selector(doubleClickedShelf)
        let scroll = NSScrollView()
        scroll.documentView = shelf
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [scroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18).isActive = true
        statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -12).isActive = true
        let shelfVC = NSViewController()
        shelfVC.view = ListBackdrop(stack)
        let shelfItem = NSSplitViewItem(viewController: shelfVC)
        shelfItem.minimumThickness = 180
        shelfItem.maximumThickness = 320
        shelfItem.canCollapse = true
        shelfItem.canCollapseFromWindowResize = true
        shelfItem.holdingPriority = .init(260)
        let hostVC = NSViewController()
        hostVC.view = host
        split.addSplitViewItem(shelfItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: hostVC))
        addChild(split)
        view = split.view
        if let tutor {
            addChild(tutor.viewController)
            pinned(tutor.viewController.view, in: host)
        }
        if current == nil {
            showNothing()
        }
        showHint()
    }

    /// Puts the dividers where they read best at 1180pt: a 210pt shelf, then the open document's own columns.
    func settleColumns() {
        split.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(210, ofDividerAt: 0)
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

    /// Opens `path` here, or reloads it when it's already the open document. The document it replaces goes on the back history.
    func open(_ path: String, remember: Bool = true) {
        _ = view
        prefs.set(Date(), forKey: "opened." + path)
        if workspace == .runs {
            recordLiveRun(path)
        }
        if path == current {
            reload()
            return
        }
        currentDeck?.saveNote()
        tutor?.saveDrafts()
        if remember, let current {
            back.removeAll { $0 == current || $0 == path }
            back.append(current)
            back = Array(back.suffix(50))
            prefs.set(back, forKey: "workspace.\(workspace.rawValue).back")
        }
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
            controller.settleColumns()
            controller.window?.makeFirstResponder(controller.table)
        }
        syncShelfSelection()
        onTitleChange?()
        onLibraryChange?()
    }

    /// ⌘[: back to the document open before this one, skipping any that were archived or removed.
    func goBack() {
        while let previous = back.popLast() {
            prefs.set(back, forKey: "workspace.\(workspace.rawValue).back")
            if FileManager.default.fileExists(atPath: previous) {
                open(previous, remember: false)
                return
            }
        }
        say("Nothing to go back to in \(workspace.name)")
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

    func showNothing() {
        switch workspace {
        case .learn:
            tutor?.showEmpty(entries.isEmpty
                ? "No tutor sessions in `~/.dotfiles/show/tutor` yet. Claude starts one with `show --tutor <file>`."
                : "Nothing open. Pick a session from the shelf, or press ⌘O.")
        case .runs:
            display(emptyState("No live runs yet", "A live run shows here while it's going."))
        case .forest:
            display(emptyState("No forest open", entries.isEmpty ? "Claude opens a project's branches here with `show <deck>`." : "Pick a project from the shelf, or press ⌘O."))
        case .review:
            display(emptyState("Nothing to review", entries.isEmpty ? "Claude opens a deck here with `show <deck>`." : "Pick a deck from the shelf, or press ⌘O."))
        }
    }

    private func display(_ content: NSViewController) {
        children.filter { $0 !== content && $0 !== tutor?.viewController && $0 !== split }.forEach { $0.removeFromParent() }
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

    // MARK: the shelf

    /// Takes this workspace's documents from a library scan and regroups the shelf, keeping the open document selected.
    func setEntries(_ all: [ShelfEntry]) {
        entries = all.filter { $0.workspace == workspace }
        var fresh: [ShelfRow] = []
        for state in [ShelfState.waiting, .running, .done] {
            let group = entries.filter { $0.state == state }.sorted { $0.touched > $1.touched }
            guard !group.isEmpty else { continue }
            fresh.append(.header(state, group.count))
            let folds = state == .done && group.count > Self.foldAfter
            let shown = folds && !doneExpanded ? Array(group.prefix(Self.foldAfter)) : group
            fresh += shown.map(ShelfRow.entry)
            if folds {
                fresh.append(.fold(hidden: group.count - Self.foldAfter, expanded: doneExpanded))
            }
        }
        if workspace == .learn {
            fresh.insert(contentsOf: dueShelfRows(), at: fresh.firstIndex { if case .header(let state, _) = $0 { return state != .waiting } else { return false } } ?? fresh.count)
        }
        rows = fresh
        _ = view
        let origin = shelf.enclosingScrollView?.contentView.bounds.origin
        syncingSelection = true
        shelf.reloadData()
        syncingSelection = false
        if let origin, let clip = shelf.enclosingScrollView?.contentView {
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        }
        syncShelfSelection()
        if current == nil {
            showNothing()
        }
    }

    private func syncShelfSelection() {
        let row = rows.firstIndex { if case .entry(let entry) = $0 { return entry.path == current } else { return false } }
        syncingSelection = true
        if let row {
            shelf.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            shelf.deselectAll(nil)
        }
        syncingSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        switch rows[row] {
        case .header, .dueHeader: return true
        default: return false
        }
    }

    @objc private func doubleClickedShelf() {
        guard shelf.clickedRow >= 0, shelf.clickedRow < rows.count, case .due(let concept) = rows[shelf.clickedRow] else { return }
        activateDue(concept)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header, .dueHeader: return 28
        case .entry, .due: return 44
        case .fold, .dueFold: return 26
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .header, .dueHeader: return false
        case .entry, .due: return true
        case .dueFold:
            guard NSApp.currentEvent?.type == .leftMouseDown else { return true }
            LearnDue.expanded.toggle()
            setEntries(entries)
            return false
        case .fold:
            guard NSApp.currentEvent?.type == .leftMouseDown else { return true }
            doneExpanded.toggle()
            onLibraryChange?()
            return false
        }
    }

    /// ↵ on the shelf: unfolds or folds Done or Due on a fold row, starts a re-test on a Due row (true), otherwise leaves the selected document open (false).
    func activateSelectedShelfRow() -> Bool {
        guard shelf.selectedRow >= 0, shelf.selectedRow < rows.count else { return false }
        switch rows[shelf.selectedRow] {
        case .fold:
            doneExpanded.toggle()
            onLibraryChange?()
        case .dueFold:
            LearnDue.expanded.toggle()
            setEntries(entries)
        case .due(let concept):
            activateDue(concept)
        default:
            return false
        }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = QuietRowView()
        rowView.selectionHighlightStyle = .none
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, shelf.selectedRow >= 0, shelf.selectedRow < rows.count, case .entry(let entry) = rows[shelf.selectedRow] else { return }
        if entry.path != current {
            open(entry.path)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let view = dueShelfView(rows[row]) { return view }
        switch rows[row] {
        case .header(let state, let count):
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(string: "\(state.groupName)  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                + NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])
            return label
        case .fold(let hidden, let expanded):
            let label = NSTextField(labelWithString: expanded ? "Show fewer" : "Show \(hidden) more")
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            return padded(label, leading: 30)
        case .dueHeader, .due, .dueFold:
            return nil
        case .entry(let entry):
            let mark = NSTextField(labelWithString: entry.state.mark)
            mark.font = .systemFont(ofSize: 11)
            mark.textColor = entry.state.markColor
            let title = NSTextField(labelWithString: entry.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            let detail = NSTextField(labelWithString: [entry.progress, relativeTime(entry.touched)].filter { !$0.isEmpty }.joined(separator: " · "))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let cell = NSTableCellView()
            for view in [mark, text] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                mark.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 26),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -34),
                detail.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -34),
            ])
            cell.toolTip = (entry.path as NSString).abbreviatingWithTildeInPath
            return cell
        }
    }

    private func padded(_ view: NSView, leading: CGFloat) -> NSView {
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// ⌫ on a shelf row: the document and its sidecars move to `show/archive/`.
    func archiveSelected() {
        guard shelf.selectedRow >= 0, shelf.selectedRow < rows.count, case .entry(let entry) = rows[shelf.selectedRow] else {
            NSSound.beep()
            return
        }
        archive(entry)
    }

    func archive(_ entry: ShelfEntry) {
        let wasOpen = entry.path == current
        if let deck = decks[entry.path] {
            deck.saveNote()
        }
        if wasOpen {
            tutor?.saveDrafts()
        }
        let onlyListed = !isInLibraryFolders(entry.path)
        do {
            if onlyListed {
                try forgetLiveRun(entry.path)
            } else {
                _ = try archiveDocument(entry.path)
                try? forgetLiveRun(entry.path)
            }
        } catch {
            say("Couldn't \(onlyListed ? "forget" : "archive") “\(entry.title)”: \(error.localizedDescription)")
            return
        }
        decks[entry.path] = nil
        back.removeAll { $0 == entry.path }
        prefs.set(back, forKey: "workspace.\(workspace.rawValue).back")
        if wasOpen {
            current = nil
            prefs.removeObject(forKey: "workspace.\(workspace.rawValue).open")
            if let previous = back.last(where: { FileManager.default.fileExists(atPath: $0) }) {
                back.removeAll { $0 == previous }
                open(previous, remember: false)
            } else {
                showNothing()
                onTitleChange?()
            }
        }
        say(onlyListed ? "Forgot “\(entry.title)”; its run files are untouched" : "Archived “\(entry.title)” to show/archive")
        onLibraryChange?()
        view.window?.makeFirstResponder(shelf)
    }

    // MARK: the status line

    /// A transient message at the foot of the shelf; the key hints come back after a few seconds.
    func say(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        statusClear?.invalidate()
        statusClear = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.showHint() }
    }

    private func showHint() {
        statusLabel.stringValue = "⌘O find · ⌫ archive · ? keys"
        statusLabel.textColor = .tertiaryLabelColor
    }

    // MARK: focus across workspace switches

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
            if let tutor, current != nil {
                tutor.focusFirstField()
            } else if let deck = currentDeck {
                window.makeFirstResponder(deck.table)
            } else {
                window.makeFirstResponder(shelf)
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
