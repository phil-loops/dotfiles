import AppKit

/// The open session's own column: its title, its stations and its due re-tests. ↵ or a double-click on a station asks the tutor
/// for it; on a due re-test it starts a one-rung re-test session.
final class TutorSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        case title(String)
        case header(String)
        case station(TutorSession.Station)
        case due(TutorSession.Due)
        case note(String)
    }

    let table = ShelfTable()
    let scroll = NSScrollView()
    private(set) var rows: [Row] = []
    var onStation: ((TutorSession.Station) -> Void)?
    var onDue: ((TutorSession.Due) -> Void)?

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: .init("session")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 12, right: 0)
    }

    func show(_ session: TutorSession?, empty: String = "Learn") {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? key(rows[table.selectedRow]) : nil
        var fresh: [Row] = []
        if let session {
            fresh.append(.title(session.title))
            if let stations = session.stations, !stations.isEmpty {
                fresh.append(.header("Stations"))
                fresh += stations.map(Row.station)
            }
            if let due = session.due, !due.isEmpty {
                fresh.append(.header("Due re-tests"))
                fresh += due.map(Row.due)
            }
            if session.stations?.isEmpty == false || session.due?.isEmpty == false {
                fresh.append(.note("↵ sends a row to the tutor"))
            }
        } else {
            fresh.append(.title(empty))
        }
        rows = fresh
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { key($0) == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func key(_ row: Row) -> String? {
        switch row {
        case .station(let station): return "station:" + station.name
        case .due(let due): return "due:" + due.concept
        default: return nil
        }
    }

    /// Selects the named station and acts on it, as ↵ would.
    func activate(station name: String) {
        guard let row = rows.firstIndex(where: { if case .station(let station) = $0 { return station.name == name } else { return false } }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        _ = activate(row: row)
    }

    /// ↵ with this list focused: acts on the selected station or due row (true), otherwise leaves ↵ to the key router (false).
    func activateSelected() -> Bool {
        activate(row: table.selectedRow)
    }

    @objc private func activateClicked() {
        _ = activate(row: table.clickedRow)
    }

    /// Acts on a station or due row; anything else is left to the table (so ↵ there beeps as usual).
    private func activate(row: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        switch rows[row] {
        case .station(let station):
            onStation?(station)
            return true
        case .due(let due):
            onDue?(due)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .title(let title): return max(36, ceil(NSAttributedString(string: title, attributes: [.font: Self.titleFont]).boundingRect(with: NSSize(width: max(tableView.bounds.width - 32, 120), height: 400), options: [.usesLineFragmentOrigin]).height) + 18)
        case .header: return 30
        case .station: return 26
        case .due(let due): return due.why == nil ? 26 : 42
        case .note: return 30
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        key(rows[row]) != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = QuietRowView()
        rowView.selectionHighlightStyle = .none
        return rowView
    }

    static let titleFont = NSFont.systemFont(ofSize: 17, weight: .bold)

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        func place(_ views: [NSView], leading: CGFloat) {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            views.forEach { $0.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -(leading + 10)).isActive = true }
        }
        func label(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        func marked(_ mark: String, _ markColor: NSColor, _ text: NSTextField, detail: NSTextField? = nil) {
            let markLabel = label(mark, .systemFont(ofSize: 11), markColor)
            markLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(markLabel)
            place([text] + [detail].compactMap { $0 }, leading: 34)
            NSLayoutConstraint.activate([
                markLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                markLabel.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            ])
        }
        switch rows[row] {
        case .title(let title):
            let field = NSTextField(wrappingLabelWithString: title)
            field.font = Self.titleFont
            field.textColor = .labelColor
            place([field], leading: 16)
        case .header(let text):
            place([label(text, .systemFont(ofSize: 12, weight: .semibold), .secondaryLabelColor)], leading: 16)
        case .station(let station):
            let mark = station.state == "done" ? "●" : station.state == "current" ? "◐" : "○"
            let color: NSColor = station.state == "current" ? .controlAccentColor : .secondaryLabelColor
            let name = label(station.name, .systemFont(ofSize: 13, weight: station.state == "current" ? .semibold : .regular),
                             station.state == "done" ? .secondaryLabelColor : .labelColor)
            marked(mark, color, name)
            cell.toolTip = "↵ asks the tutor for this station"
        case .due(let due):
            let detail = due.why.map { label($0, .systemFont(ofSize: 11), .secondaryLabelColor) }
            marked("◆", .systemOrange, label(LearnDue.name(due.concept), .systemFont(ofSize: 12.5, weight: .medium), .labelColor), detail: detail)
            cell.toolTip = "↵ starts a re-test of \(due.concept)"
        case .note(let text):
            place([label(text, .systemFont(ofSize: 11), .tertiaryLabelColor)], leading: 16)
        }
        return cell
    }
}
