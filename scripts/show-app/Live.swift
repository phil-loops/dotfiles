import AppKit

/// A live deck's optional run status: Show reads `state`, `done`, `total` and `current`; the per-mark counts come from section statuses.
struct LiveStatus: Decodable {
    let state: String?
    let done: Int?
    let total: Int?
    let current: String?
}

/// A model-by-field comparison: columns are models, rows are fields.
struct Compare: Decodable {
    struct Row: Decodable {
        let field: String
        let values: [String]

        private enum CodingKeys: String, CodingKey { case field, values }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            field = try container.decode(Loose.self, forKey: .field).text
            values = try container.decodeIfPresent([Loose].self, forKey: .values)?.map(\.text) ?? []
        }
    }

    let columns: [String]
    let rows: [Row]
    let diffs: [[Int]]?

    /// The columns of row `r` that differ from the row's majority, plus any `diffs` names. With no strict majority, every cell differs.
    func differing(_ r: Int) -> Set<Int> {
        let values = rows[r].values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var listed = Set((diffs ?? []).filter { $0.count == 2 && $0[0] == r }.map { $0[1] })
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        let top = counts.values.max() ?? 0
        if counts.count > 1 {
            let leaders = counts.filter { $0.value == top }.map(\.key)
            listed.formUnion(values.indices.filter { leaders.count > 1 || values[$0] != leaders[0] })
        }
        return listed
    }
}

/// A secondary data table on a live section.
struct DataTable: Decodable {
    let title: String?
    let columns: [String]
    let rows: [[String]]

    private enum CodingKeys: String, CodingKey { case title, columns, rows }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        columns = try container.decodeIfPresent([Loose].self, forKey: .columns)?.map(\.text) ?? []
        rows = try container.decodeIfPresent([[Loose]].self, forKey: .rows)?.map { $0.map(\.text) } ?? []
    }
}

/// Raw text shown last on a live section, numbered.
struct SourceText: Decodable {
    let title: String?
    let text: String
}

/// A cell value a producer may write as a string, number, bool or null; a deck mid-run must never fail to load over one.
struct Loose: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            text = ""
        } else if let string = try? value.decode(String.self) {
            text = string
        } else if let int = try? value.decode(Int.self) {
            text = String(int)
        } else if let double = try? value.decode(Double.self) {
            text = String(double)
        } else if let bool = try? value.decode(Bool.self) {
            text = String(bool)
        } else {
            text = ""
        }
    }
}

/// A string key that decodes as "" when it's missing, so live sections may leave out `group`.
@propertyWrapper
struct MissingIsEmpty: Decodable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: MissingIsEmpty.Type, forKey key: Key) throws -> MissingIsEmpty {
        try decodeIfPresent(type, forKey: key) ?? MissingIsEmpty(wrappedValue: "")
    }
}

/// Signal: needs your eyes (disagree, flagged, stale).
let signalColor = NSColor.systemOrange
let signalTint = NSColor(name: "show.signalTint") { appearance in
    NSColor.systemOrange.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.3 : 0.14)
}

// MARK: the list

/// A live deck's section list: sections without a status (an overview) on top in file order, then Disagreements, Agreed and Pending.
func liveGroups(_ deck: Deck) -> [(name: String, items: [Int])] {
    let sections = deck.sections
    func with(_ statuses: Set<String>) -> [Int] { sections.indices.filter { statuses.contains(sections[$0].status ?? "") } }
    let known: Set<String> = ["disagree", "flagged", "agreed", "pending"]
    return [
        ("Overview", sections.indices.filter { !known.contains(sections[$0].status ?? "") }),
        ("Disagreements", with(["disagree", "flagged"])),
        ("Agreed", with(["agreed"])),
        ("Pending", with(["pending"])),
    ].filter { !$0.items.isEmpty }
}

func liveRows(_ deck: Deck) -> [Row] {
    liveGroups(deck).flatMap { group in
        [Row.header(group.name == "Overview" ? group.name : "\(group.name) \(group.items.count)")] + group.items.map(Row.item)
    }
}

/// Per-mark counts for the header: ◆ disagree or flagged, ● agreed, ○ pending.
func liveCounts(_ deck: Deck) -> (look: Int, agreed: Int, pending: Int) {
    let statuses = deck.sections.compactMap(\.status)
    return (statuses.filter { $0 == "disagree" || $0 == "flagged" }.count, statuses.filter { $0 == "agreed" }.count, statuses.filter { $0 == "pending" }.count)
}

/// A live row's mark: ◆ disagree or flagged, ● agreed, ◐ the pending item running now, ○ pending; none for an overview section.
func liveMark(_ section: Section, current: String?) -> NSAttributedString {
    let (mark, color): (String, NSColor)
    switch section.status {
    case "disagree", "flagged": (mark, color) = ("◆", signalColor)
    case "agreed": (mark, color) = ("●", .secondaryLabelColor)
    case "pending" where current != nil && (section.key == current || section.title == current): (mark, color) = ("◐", .labelColor)
    case "pending": (mark, color) = ("○", .tertiaryLabelColor)
    default: return NSAttributedString()
    }
    return NSAttributedString(string: mark + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .baselineOffset: 1])
}

/// ⚑ after a flagged row's title.
func liveFlag(_ section: Section) -> NSAttributedString {
    guard section.status == "flagged" else { return NSAttributedString() }
    return NSAttributedString(string: "  ⚑", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: signalColor])
}

// MARK: the page

extension Renderer {
    /// The small line above a section's title: its status on a live section, else its group.
    func eyebrow(_ section: Section) -> String {
        switch section.status {
        case "disagree": return "Disagreement"
        case "flagged": return "Flagged ⚑"
        case "agreed": return "Agreed"
        case "pending": return "Pending"
        default: return section.group
        }
    }

    /// A live section's data under its body: the compare table, then secondary tables, then the numbered source.
    func liveData(_ section: Section) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let compare = section.compare, !compare.columns.isEmpty {
            out.append(compareTable(compare))
        }
        for table in section.tables ?? [] where !table.columns.isEmpty || !table.rows.isEmpty {
            if let title = table.title, !title.isEmpty {
                out.append(caption(title, hint: nil))
            }
            out.append(grid((table.columns.isEmpty ? [] : [table.columns]) + table.rows))
        }
        if let source = section.source {
            out.append(caption(source.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Source", hint: nil))
            out.append(sourceBlock(source.text))
        }
        return out
    }

    private func compareTable(_ compare: Compare) -> NSAttributedString {
        let differing = compare.rows.indices.map(compare.differing)
        let shown = compare.rows.indices.filter { !onlyDifferingRows || !differing[$0].isEmpty }
        let count = differing.filter { !$0.isEmpty }.count
        let out = NSMutableAttributedString()
        let fields = compare.rows.count == 1 ? "field" : "fields"
        if onlyDifferingRows {
            out.append(caption("Compare", hint: count == 0 ? "all \(compare.rows.count) \(fields) agree · d shows every row" : "only the \(count) of \(compare.rows.count) \(fields) that differ · d shows every row"))
        } else {
            out.append(caption("Compare", hint: "\(count) of \(compare.rows.count) \(fields) differ" + (count > 0 ? " · d shows only those" : "")))
        }
        guard !shown.isEmpty else { return out }
        let cells = [["field"] + compare.columns] + shown.map { r in
            [compare.rows[r].field] + compare.columns.indices.map { c in c < compare.rows[r].values.count ? compare.rows[r].values[c] : "" }
        }
        out.append(grid(cells) { row, column in
            if row == 0 { return (.labelColor, nil) }
            if column == 0 { return (.secondaryLabelColor, nil) }
            return (.labelColor, differing[shown[row - 1]].contains(column - 1) ? signalTint : nil)
        })
        return out
    }

    private func caption(_ title: String, hint: String?) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        p.paragraphSpacing = 6
        let out = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        if let hint {
            out.append(NSAttributedString(string: "   " + hint, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Monospace text in one panel with a line-number gutter; long lines wrap under their own text, not under the numbers.
    private func sourceBlock(_ text: String) -> NSAttributedString {
        let panel = NSTextBlock()
        panel.backgroundColor = NSColor(name: "show.sourcePanel") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
        }
        panel.setValue(100, type: .percentageValueType, for: .width)
        panel.setWidth(14, type: .absoluteValueType, for: .padding)
        panel.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let lines = text.components(separatedBy: "\n")
        let digits = String(lines.count).count
        let gutter = ceil(("0" as NSString).size(withAttributes: [.font: mono]).width * CGFloat(digits)) + 14
        let p = NSMutableParagraphStyle()
        p.textBlocks = [panel]
        p.paragraphSpacing = 0
        p.lineSpacing = 1
        p.tabStops = [NSTextTab(textAlignment: .right, location: gutter - 14), NSTextTab(textAlignment: .left, location: gutter)]
        p.headIndent = gutter
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            out.append(NSAttributedString(string: "\t\(i + 1)\t", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        }
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }
}

// MARK: the header and the action bar

/// A thin progress bar: a quiet track with the done share filled.
final class ThinBar: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var fill: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 4) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard fraction > 0 else { return }
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * min(1, fraction), height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// What the header says: the progress line, then the counts and how long since the file changed.
struct LiveHeaderText {
    let progress: String
    let state: String?
    let current: String?
    let counts: (look: Int, agreed: Int, pending: Int)
    let updated: String?
    let stale: Bool
    let stopping: Bool
    let failed: Bool
    let fraction: CGFloat?

    /// `stopRequested`: `<runDir>/STOP` exists. While the run still says `running`, the header reads "Stopping after this round".
    init(deck: Deck, modified: Date?, stopRequested: Bool, now: Date = Date()) {
        let status = deck.status
        if let done = status?.done, let total = status?.total {
            progress = "\(done) of \(total)"
            fraction = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        } else if let done = status?.done {
            progress = "\(done) done"
            fraction = nil
        } else {
            progress = ""
            fraction = nil
        }
        let raw = status?.state ?? ""
        stopping = stopRequested && (raw == "running" || raw.isEmpty || raw == "preparing")
        failed = raw == "failed"
        state = stopping ? "Stopping after this round" : raw.isEmpty ? nil : raw.prefix(1).uppercased() + raw.dropFirst()
        current = status?.current.flatMap { $0.isEmpty ? nil : $0 }
        counts = liveCounts(deck)
        updated = modified.map { "updated " + sinceText($0, now: now) }
        stale = raw == "running" && modified.map { now.timeIntervalSince($0) > 30 } == true
    }

    /// The progress count, the state, and the current item; a failed run gives `current` as its reason.
    var first: [String] {
        [progress, state ?? "", current.map { failed ? "\($0)" : "now: \($0)" } ?? ""].filter { !$0.isEmpty }
    }

    var second: [String] {
        ["◆ \(counts.look)", "● \(counts.agreed)", "○ \(counts.pending)", updated ?? ""].filter { !$0.isEmpty }
    }

    var plain: String { first.joined(separator: " · ") + (failed ? "  [signal]" : "") + "\n" + second.joined(separator: " · ") + (stale ? "  [stale]" : "") }
}

/// The Live view's pinned header, "Stop after this round" bar and keys (**d**, ⌘.), owned by a deck's controller and hidden on every other deck.
final class LivePanel: NSObject {
    let header = NSStackView()
    let bar = NSStackView()
    private let progressBar = ThinBar()
    private let first = NSTextField(labelWithString: "")
    private let second = NSTextField(labelWithString: "")
    let stop = NSButton(title: "Stop after this round  ⌘.", target: nil, action: nil)
    let reason = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    weak var owner: DeckController?
    private var monitor: Any?

    override init() {
        super.init()
        first.lineBreakMode = .byTruncatingTail
        second.lineBreakMode = .byTruncatingTail
        let top = NSStackView(views: [progressBar, first])
        top.spacing = 10
        top.alignment = .centerY
        progressBar.setContentHuggingPriority(.required, for: .horizontal)
        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        progressBar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.edgeInsets = NSEdgeInsets(top: 14, left: 53, bottom: 12, right: 24)
        header.addArrangedSubview(top)
        header.addArrangedSubview(second)
        let rule = NSBox()
        rule.boxType = .separator
        header.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -53 - 24).isActive = true
        header.setCustomSpacing(12, after: second)
        header.edgeInsets.bottom = 0
        header.isHidden = true

        stop.target = self
        stop.action = #selector(confirmStop)
        stop.bezelStyle = .rounded
        stop.imagePosition = .imageLeading
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.toolTip = "Create <runDir>/STOP: the runner checkpoints and exits after the current round (⌘.)"
        reason.font = .systemFont(ofSize: 11.5)
        reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byTruncatingMiddle
        reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.setViews([stop, reason, spacer, hint], in: .leading)
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 48, bottom: 10, right: 24)
        bar.isHidden = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private var runDir: String? {
        owner?.deck.runDir.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
    }

    var stopPath: String? { runDir.map { ($0 as NSString).appendingPathComponent("STOP") } }
    var stopRequested: Bool { stopPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    /// Why the run can't be stopped from here, or nil when it can. Show never removes STOP or restarts a run.
    private var blocked: String? {
        guard let runDir else { return "No runDir in this deck" }
        switch owner?.deck.status?.state {
        case "done": return "The run is done"
        case "failed": return "The run failed"
        default: break
        }
        if stopRequested { return "Stop requested: the run exits after this round" }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: runDir, isDirectory: &directory), directory.boolValue else {
            return "runDir doesn't exist: \((runDir as NSString).abbreviatingWithTildeInPath)"
        }
        guard FileManager.default.isWritableFile(atPath: runDir) else {
            return "Can't write to \((runDir as NSString).abbreviatingWithTildeInPath)"
        }
        return nil
    }

    /// Refreshes the header and the bar from the deck and its run directory; runs on every reload and once a second.
    func update(modified: Date?) {
        guard let deck = owner?.deck, deck.isLive else {
            header.isHidden = true
            bar.isHidden = true
            return
        }
        let text = LiveHeaderText(deck: deck, modified: modified, stopRequested: stopRequested)
        header.isHidden = false
        bar.isHidden = false
        progressBar.isHidden = text.fraction == nil
        progressBar.fraction = text.fraction ?? 0
        progressBar.fill = text.failed ? signalColor : text.stopping ? .tertiaryLabelColor : .secondaryLabelColor

        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let dot = NSAttributedString(string: "  ·  ", attributes: quiet)
        var parts: [NSAttributedString] = []
        if !text.progress.isEmpty {
            parts.append(NSAttributedString(string: text.progress, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        }
        if let state = text.state {
            let loud = text.failed || text.stopping
            parts.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: loud ? .semibold : .regular),
                                                                         .foregroundColor: text.failed ? signalColor : loud ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        }
        if let current = text.current {
            let item = NSAttributedString(string: current, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: text.failed ? signalColor : NSColor.labelColor])
            parts.append(text.failed ? item : NSAttributedString(string: "now: ", attributes: quiet) + item)
        }
        first.attributedStringValue = parts.dropFirst().reduce(parts.first ?? NSAttributedString()) { $0 + dot + $1 }
        first.isHidden = parts.isEmpty

        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func count(_ mark: String, _ n: Int, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: mark + " ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .baselineOffset: 1])
                + NSAttributedString(string: "\(n)", attributes: [.font: digits, .foregroundColor: NSColor.secondaryLabelColor])
        }
        var line = count("◆", text.counts.look, signalColor) + dot + count("●", text.counts.agreed, .secondaryLabelColor) + dot + count("○", text.counts.pending, .tertiaryLabelColor)
        if let updated = text.updated {
            line = line + dot + NSAttributedString(string: updated, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: text.stale ? .medium : .regular), .foregroundColor: text.stale ? signalColor : NSColor.secondaryLabelColor])
        }
        second.attributedStringValue = line

        let why = blocked
        stop.isEnabled = why == nil
        reason.stringValue = why ?? ""
        hint.stringValue = owner?.selectedSection?.compare == nil ? "" : (owner?.renderer.onlyDifferingRows == true ? "d  every row" : "d  only rows that differ")
    }

    /// ⌘.: asks first (↵ stops, Esc cancels), because a stop can't be undone: the runner checkpoints, unloads its models and exits.
    @objc func confirmStop() {
        guard blocked == nil, let window = header.window, window.attachedSheet == nil else {
            update(modified: owner?.deckModified)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop after this round?"
        alert.informativeText = "Show creates \(((stopPath ?? "") as NSString).abbreviatingWithTildeInPath). The runner checkpoints, unloads its models and exits once the current round finishes. This can't be undone from Show."
        alert.addButton(withTitle: "Stop after this round")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.writeStop()
        }
    }

    /// Creates `<runDir>/STOP`, the only thing Show ever writes in a run directory.
    private func writeStop() {
        guard blocked == nil, let stopPath else {
            update(modified: owner?.deckModified)
            return
        }
        let stamp = "stop requested from Show at \(ISO8601DateFormatter().string(from: Date()))\n"
        let made = FileManager.default.createFile(atPath: stopPath, contents: stamp.data(using: .utf8))
        update(modified: owner?.deckModified)
        if !made {
            reason.stringValue = "Couldn't create \((stopPath as NSString).abbreviatingWithTildeInPath)"
        }
    }

    /// **d** toggles "only rows that differ"; ⌘. pauses or resumes. Only while this live deck is on screen and nothing is being typed.
    func handle(_ event: NSEvent) -> Bool {
        guard let owner, owner.deck.isLive, let window = header.window, event.window == nil || event.window === window,
              !header.isHiddenOrHasHiddenAncestor else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.charactersIgnoringModifiers, modifiers) {
        case ("d", []):
            owner.toggleOnlyDifferingRows()
            return true
        case (".", [.command]):
            if stop.isEnabled { confirmStop() }
            return true
        default:
            return false
        }
    }

    /// `SHOW_SNAPSHOT_KEYS=d,cmd-.,confirm`: types those keys into the window through `handle`, for a snapshot to show their effect;
    /// `confirm` and `cancel` answer the stop sheet as ↵ and Esc would; a sheet still open at the end is cancelled.
    func typeSnapshotKeys(_ keys: String) {
        for key in keys.split(separator: ",").map(String.init) {
            if key == "confirm" || key == "cancel", let window = header.window, let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: key == "confirm" ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                print("sheet \(key) · STOP: \(stopRequested ? "exists" : "absent") · button: \(stop.isEnabled ? "enabled" : "disabled: " + reason.stringValue)")
                continue
            }
            let command = key.hasPrefix("cmd-")
            let character = command ? String(key.dropFirst(4)) : key
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0,
                                               windowNumber: header.window?.windowNumber ?? 0, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0) else { continue }
            let handled = handle(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            print("key \(key): \(handled ? "handled" : "ignored") · only rows that differ: \(owner?.renderer.onlyDifferingRows == true) · STOP: \(stopRequested ? "exists" : "absent") · sheet: \(header.window?.attachedSheet == nil ? "none" : "asking")")
        }
        if let window = header.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            print("sheet left open: cancelled")
        }
    }
}

extension DeckController {
    /// **d**: flips "only rows that differ" and re-renders the open section where it was scrolled.
    func toggleOnlyDifferingRows() {
        renderer.onlyDifferingRows.toggle()
        guard let section = selectedSection, section.url == nil else { return }
        let clip = textScroll.contentView
        let origin = clip.bounds.origin
        text.textStorage?.setAttributedString(renderer.render(section))
        if let container = text.textContainer {
            text.layoutManager?.ensureLayout(for: container)
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        textScroll.reflectScrolledClipView(clip)
        live.update(modified: deckModified)
    }
}

func sinceText(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
}

// MARK: the menu bar's run list

/// `~/Library/Application Support/Show/live-runs.json` (`SHOW_LIVE_RUNS` swaps it): every live deck Show has opened, for the menu bar.
var liveRunsPath: String? {
    if let path = ProcessInfo.processInfo.environment["SHOW_LIVE_RUNS"] { return (path as NSString).expandingTildeInPath }
    if (NSApp.delegate as? AppDelegate)?.snapshotPath != nil { return nil }
    return ("~/Library/Application Support/Show/live-runs.json" as NSString).expandingTildeInPath
}

struct LiveRun: Codable {
    let path: String
    let title: String
    let openedAt: String
}

/// Records that Show opened the live deck at `path`, newest first, dropping runs whose file is gone.
func recordLiveRun(_ path: String) {
    guard let registry = liveRunsPath, let deck = try? loadDeck(path), deck.isLive else { return }
    let url = URL(fileURLWithPath: registry)
    let known = (try? JSONDecoder().decode([LiveRun].self, from: Data(contentsOf: url))) ?? []
    let runs = [LiveRun(path: path, title: deck.title, openedAt: ISO8601DateFormatter().string(from: Date()))]
        + known.filter { $0.path != path && FileManager.default.fileExists(atPath: $0.path) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? encoder.encode(runs).write(to: url, options: .atomic)
}

// MARK: --check-live

/// `--check-live`: print the Live view's header, list groups and each compare table (◆ marks a differing cell), without a window.
func checkLive(_ raw: String) -> Int32 {
    let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    do {
        let deck = try loadDeck(path)
        guard deck.isLive else {
            FileHandle.standardError.write("Show: \(path) is not a live deck (mode \"live\")\n".data(using: .utf8)!)
            return 65
        }
        let stop = deck.runDir.map { (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent("STOP") }
        let paused = stop.map { FileManager.default.fileExists(atPath: $0) } ?? false
        print("header:\n" + LiveHeaderText(deck: deck, modified: modificationDate(path), stopRequested: paused).plain.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        print("runDir: \(deck.runDir ?? "-") · STOP \(paused ? "exists" : "absent")")
        for group in liveGroups(deck) {
            print("\(group.name) \(group.items.count)")
            for i in group.items {
                let section = deck.sections[i]
                let mark = liveMark(section, current: deck.status?.current).string.trimmingCharacters(in: .whitespaces)
                print("  \(mark.isEmpty ? " " : mark) \(section.title)\(section.status == "flagged" ? "  ⚑" : "")")
            }
        }
        for section in deck.sections {
            guard let compare = section.compare else { continue }
            let differing = compare.rows.indices.filter { !compare.differing($0).isEmpty }
            print("compare \(section.key): \(compare.columns.joined(separator: " | ")) · \(differing.count) of \(compare.rows.count) rows differ")
            for (r, row) in compare.rows.enumerated() {
                let cells = row.values.enumerated().map { c, value in (compare.differing(r).contains(c) ? "◆" : "") + value }
                print("  \(differing.contains(r) ? "≠" : " ") \(row.field): \(cells.joined(separator: " | "))")
            }
            print("  d → \(differing.map { compare.rows[$0].field }.joined(separator: ", "))")
        }
        return 0
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
}
