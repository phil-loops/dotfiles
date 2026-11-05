// Plans: a migration laid out as states before any branch exists. A deck with a top-level "plan" object; Show draws it as one
// interactive grid (stages across, the core's rows then each extra's lane down) and adds a sign-off page per transition and extra.
// { "plan": { "fact", "repo"?, "stages": [{ "id", "kind"?, "stop"?, "safe"? }], "rows": [{ "name", "kind", "where"?, "movedBy"?, "cells" }],
//   "branches"?: [{ "name", "stage" }], "transitions"?: [{ "from", "to", "gate"?, "manual"?, "rollback"? }],
//   "extras"?: [{ "id", "name", "mvp"?, "start", "end"?, "cliff"?, "why"?, "detail"?, "accepted"? }] } }
import AppKit

struct Plan: Decodable {
    struct Stage: Decodable {
        let id: String
        /// expand, record, backfill, verify, flip or contract: what the lint's order rules key on.
        let kind: String?
        /// What holds, or is half-done, when the migration stops here.
        let stop: String?
        let safe: Bool?
    }

    struct Row: Decodable {
        let name: String
        /// authority, writer, reader or record.
        let kind: String
        let `where`: String?
        let movedBy: String?
        let cells: [String]
    }

    struct Branch: Decodable {
        let name: String
        let stage: String
        /// The branch's one-line purpose (its git description), shown on its card under the name.
        let does: String?
    }

    struct Transition: Decodable {
        let from: String
        let to: String
        let gate: String?
        let manual: String?
        let rollback: String?
    }

    struct Extra: Decodable {
        let id: String
        let name: String
        let mvp: Bool?
        let start: String
        let end: String?
        /// The stage from which leaving it out costs more: usually the first stored event of the shape it changes.
        let cliff: String?
        let why: String?
        let detail: String?
        /// Why leaving it out past its cliff is fine; silences the cliff warning.
        let accepted: String?

        var inMVP: Bool { mvp ?? false }
    }

    let fact: String?
    let repo: String?
    let stages: [Stage]
    let rows: [Row]
    let branches: [Branch]?
    let transitions: [Transition]?
    let extras: [Extra]?

    func stageIndex(_ id: String?) -> Int? { id.flatMap { id in stages.firstIndex { $0.id == id } } }

    var firstFlip: Int? { stages.firstIndex { $0.kind == "flip" } }

    /// A row's cells with each ditto ("″" or "\"") replaced by the value to its left.
    func resolved(_ row: Row) -> [String] {
        var out: [String] = []
        for cell in row.cells {
            out.append(isDitto(cell) ? (out.last ?? "") : cell)
        }
        return out
    }

    func transition(from: Int) -> Transition? {
        guard from + 1 < stages.count else { return nil }
        return transitions?.first { $0.from == stages[from].id && $0.to == stages[from + 1].id }
    }

    /// The rows whose value changes as stage `index` deploys, with the value before and after.
    func changes(at index: Int) -> [(row: Row, before: String, after: String)] {
        guard index > 0 else { return [] }
        return rows.compactMap { row in
            let values = resolved(row)
            guard index < values.count, values[index] != values[index - 1] else { return nil }
            return (row, values[index - 1], values[index])
        }
    }

    func branches(at index: Int) -> [Branch] {
        (branches ?? []).filter { $0.stage == stages[index].id }
    }
}

func isDitto(_ cell: String) -> Bool { cell == "″" || cell == "\"" || cell == "〃" }
func isAbsent(_ cell: String) -> Bool { cell == "—" || cell == "-" }
func isGone(_ cell: String) -> Bool { cell.lowercased() == "gone" }

struct PlanIssue {
    enum Level { case error, warning }
    let level: Level
    let message: String
    var row: Int? = nil
    var stage: Int? = nil
    var transition: Int? = nil
    var extra: String? = nil
}

/// The plan's rules: one authority per stage, moving only at a flip; no row dropping out mid-way; readers and retirements
/// only from the flip on; a rollback line on every transition; an extra left out past its cliff only on purpose.
func lintPlan(_ plan: Plan) -> [PlanIssue] {
    var issues: [PlanIssue] = []
    let count = plan.stages.count
    let ids = plan.stages.map(\.id)
    for (i, id) in ids.enumerated() where ids[..<i].contains(id) {
        issues.append(PlanIssue(level: .error, message: "stage \(id) appears twice", stage: i))
    }
    let flip = plan.firstFlip
    for (r, row) in plan.rows.enumerated() {
        guard row.cells.count == count else {
            issues.append(PlanIssue(level: .error, message: "\(row.name) has \(row.cells.count) cells for \(count) stages", row: r))
            continue
        }
        let values = plan.resolved(row)
        for (i, value) in values.enumerated() {
            let stage = plan.stages[i].id
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(PlanIssue(level: .error, message: "\(row.name) says nothing at \(stage)", row: r, stage: i))
                continue
            }
            if row.kind == "authority" {
                if isAbsent(value) || isGone(value) {
                    issues.append(PlanIssue(level: .error, message: "nothing holds the truth at \(stage)", row: r, stage: i))
                } else if value.contains("+") || value.contains("/") || value.lowercased().contains(" and ") || value.lowercased() == "both" {
                    issues.append(PlanIssue(level: .error, message: "two authorities at \(stage): \(value)", row: r, stage: i))
                }
                if i > 0, value != values[i - 1], plan.stages[i].kind != "flip" {
                    issues.append(PlanIssue(level: .error, message: "the authority moves at \(stage), which isn't a flip", row: r, stage: i))
                }
                continue
            }
            if i > 0, isAbsent(value), !isAbsent(values[i - 1]), values[(i + 1)...].contains(where: { !isAbsent($0) }) {
                issues.append(PlanIssue(level: .error, message: "\(row.name) drops out at \(stage) and comes back", row: r, stage: i))
            }
            if let flip, i < flip, i > 0, isGone(value), !isGone(values[i - 1]) {
                issues.append(PlanIssue(level: .error, message: "\(row.name) is retired at \(stage), before the flip", row: r, stage: i))
            }
            if row.kind == "reader", let flip, i > 0, i < flip, value != values[i - 1] {
                issues.append(PlanIssue(level: .error, message: "reader \(row.name) moves at \(stage), before the flip", row: r, stage: i))
            }
        }
    }
    if !plan.rows.contains(where: { $0.kind == "authority" }) {
        issues.append(PlanIssue(level: .error, message: "no authority row: say what holds the truth at each stage"))
    }
    for i in 0..<max(count - 1, 0) {
        let pair = "\(ids[i]) → \(ids[i + 1])"
        guard let transition = plan.transition(from: i) else {
            issues.append(PlanIssue(level: .warning, message: "no transition page for \(pair)", transition: i))
            continue
        }
        if (transition.rollback ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(PlanIssue(level: .error, message: "\(pair) has no rollback line", transition: i))
        }
    }
    for transition in plan.transitions ?? [] {
        guard let from = plan.stageIndex(transition.from), plan.stageIndex(transition.to) == from + 1 else {
            issues.append(PlanIssue(level: .error, message: "transition \(transition.from) → \(transition.to) isn't between neighbouring stages"))
            continue
        }
    }
    for branch in plan.branches ?? [] where plan.stageIndex(branch.stage) == nil {
        issues.append(PlanIssue(level: .error, message: "branch \(branch.name) deploys at unknown stage \(branch.stage)"))
    }
    for extra in plan.extras ?? [] {
        for (label, id) in [("start", extra.start), ("end", extra.end), ("cliff", extra.cliff)] {
            if let id, plan.stageIndex(id) == nil {
                issues.append(PlanIssue(level: .error, message: "\(extra.name): unknown \(label) stage \(id)", extra: extra.id))
            }
        }
        if !extra.inMVP, let cliff = extra.cliff, extra.accepted == nil {
            issues.append(PlanIssue(level: .warning, message: "\(extra.name) is left out past its cliff at \(cliff): put it in the MVP or say why that's fine", extra: extra.id))
        }
    }
    return issues
}

/// The sign-off pages a plan adds ahead of the file's own sections: the grid, then each transition, then each extra.
func planSections(_ plan: Plan) -> [[String: Any]] {
    let issues = lintPlan(plan)
    let errors = issues.filter { $0.level == .error }.count
    let warnings = issues.count - errors
    var overview = "Each column is a moment you could stop at. ←→ moves the stage cursor, ↑↓ the row, **m** moves an extra in or out of the MVP, **v** shows the MVP only, ↵ opens the selected page, **o** opens a branch in canopy."
    if !issues.isEmpty {
        overview += "\n\n## Lint\n" + issues.map { "- \($0.level == .error ? "✗" : "⚠") \($0.message)" }.joined(separator: "\n")
    }
    var sections: [[String: Any]] = [[
        "id": "plan", "group": "Plan", "title": plan.fact ?? "The plan", "view": "plan", "body": overview,
        "tag": "\(plan.stages.count) stages · \((plan.extras ?? []).count) extras · " + (issues.isEmpty ? "lint clean" : "\(errors) errors, \(warnings) warnings"),
    ]]
    for i in 0..<max(plan.stages.count - 1, 0) {
        let from = plan.stages[i].id
        let to = plan.stages[i + 1]
        let transition = plan.transition(from: i)
        var body: [String] = []
        body.append("## Gate\n" + (transition?.gate ?? "*None stated.*"))
        if let manual = transition?.manual { body.append("## Manual step\n" + manual) }
        body.append("## Rollback\n" + (transition?.rollback ?? "*Missing: say what reverting \(to.id) does.*"))
        let changes = plan.changes(at: i + 1)
        if !changes.isEmpty {
            body.append("## What changes\n| | before | after |\n|---|---|---|\n" + changes.map { "| \($0.row.name) | \($0.before) | **\($0.after)** |" }.joined(separator: "\n"))
        }
        let deploying = plan.branches(at: i + 1)
        if !deploying.isEmpty {
            body.append("## Deploys\n" + deploying.map { "- [\($0.name)](canopy://v2/b/\(plan.repo ?? "loops")/\($0.name))" }.joined(separator: "\n"))
        }
        if let stop = to.stop {
            body.append("## Stopping at \(to.id)\n" + (to.safe == false ? "⚠ " : "✓ ") + stop)
        }
        let own = issues.filter { $0.transition == i || $0.stage == i + 1 }
        if !own.isEmpty {
            body.append("## Lint\n" + own.map { "- \($0.level == .error ? "✗" : "⚠") \($0.message)" }.joined(separator: "\n"))
        }
        sections.append(["id": "t-\(from)-\(to.id)", "group": "Transitions", "title": "\(from) → \(to.id)",
                         "tag": transition?.gate.map { String($0.prefix(60)) } ?? "no gate", "body": body.joined(separator: "\n\n")])
    }
    for extra in plan.extras ?? [] {
        var body: [String] = []
        body.append(extra.inMVP ? "**In the MVP.**" : "**Later.** Lands after the core ships.")
        if let detail = extra.detail { body.append(detail) }
        if let cliff = extra.cliff {
            body.append("## Cliff at \(cliff)\n" + (extra.why ?? "Leaving it out costs more from here."))
        } else {
            body.append("## No cliff\nIt can land any time: nothing stored changes shape.")
        }
        if let accepted = extra.accepted { body.append("## Accepted\n" + accepted) }
        let span = extra.start + " → " + (extra.end ?? plan.stages.last?.id ?? "")
        sections.append(["id": "x-\(extra.id)", "group": "Extras", "title": extra.name,
                         "tag": [extra.inMVP ? "MVP" : "later", span, extra.cliff.map { "▼ \($0)" }].compactMap { $0 }.joined(separator: " · "),
                         "body": body.joined(separator: "\n\n")])
    }
    return sections
}

/// A plan file's JSON with its synthesized sections put in front of its own; any other file comes back as it was.
func expandPlan(_ data: Data) -> Data {
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let raw = object["plan"],
          let planData = try? JSONSerialization.data(withJSONObject: raw),
          let plan = try? JSONDecoder().decode(Plan.self, from: planData) else { return data }
    object["sections"] = planSections(plan) + ((object["sections"] as? [[String: Any]]) ?? [])
    return (try? JSONSerialization.data(withJSONObject: object)) ?? data
}

/// Moves an extra in or out of the MVP in the plan file itself; the file watcher reloads the deck.
func setExtraMVP(path: String, extra id: String, to value: Bool) throws {
    let url = URL(fileURLWithPath: path)
    guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
          var plan = object["plan"] as? [String: Any], var extras = plan["extras"] as? [[String: Any]],
          let index = extras.firstIndex(where: { $0["id"] as? String == id }) else { return }
    extras[index]["mvp"] = value
    plan["extras"] = extras
    object["plan"] = plan
    let out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.write(to: url, options: .atomic)
}

/// `--check-plan`: the plan's stages, what changes at each, and its lint, without a window. Exit 1 when the lint has errors.
func checkPlan(_ raw: String) -> Int32 {
    let path = (raw as NSString).expandingTildeInPath
    struct Head: Decodable { let plan: Plan }
    do {
        let plan = try JSONDecoder().decode(Head.self, from: Data(contentsOf: URL(fileURLWithPath: path))).plan
        print("fact: \(plan.fact ?? "-")")
        for (i, stage) in plan.stages.enumerated() {
            let authority = plan.rows.first { $0.kind == "authority" }.map { plan.resolved($0)[safe: i] ?? "?" } ?? "?"
            print("stage \(i): \(stage.id) [\(stage.kind ?? "-")] authority \(authority)\(stage.safe == false ? " · not safe to stop" : "")")
            for change in plan.changes(at: i) {
                print("  \(change.row.name): \(change.before) → \(change.after)")
            }
            for branch in plan.branches(at: i) {
                print("  deploys \(branch.name)")
            }
        }
        for extra in plan.extras ?? [] {
            print("extra \(extra.id): \(extra.inMVP ? "MVP" : "later") \(extra.start)→\(extra.end ?? "end")\(extra.cliff.map { " cliff \($0)" } ?? "")")
        }
        let issues = lintPlan(plan)
        for issue in issues {
            print("\(issue.level == .error ? "error" : "warning"): \(issue.message)")
        }
        print(issues.isEmpty ? "lint: clean" : "lint: \(issues.filter { $0.level == .error }.count) errors, \(issues.filter { $0.level == .warning }.count) warnings")
        return issues.contains { $0.level == .error } ? 1 : 0
    } catch {
        FileHandle.standardError.write("Show: \(path): \(error)\n".data(using: .utf8)!)
        return 65
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - The grid

/// The scroll view around the grid: a canvas that pans both ways and zooms (pinch, or = − 0 on the grid). It re-fits the
/// grid to the visible width whenever it re-tiles, zooms or scrolls, so the docked inspector stays in view.
final class PlanScroll: NSScrollView {
    let grid = PlanView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentView = grid
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        allowsMagnification = true
        minMagnification = 0.5
        maxMagnification = 2
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.grid.fit(width: self.contentView.bounds.width)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func tile() {
        super.tile()
        grid.fit(width: contentView.bounds.width)
    }
}

final class PlanView: NSView {
    enum Pick: Equatable {
        case stage(Int), transition(Int), row(Int), extra(String), branch(String)
    }

    var plan: Plan?
    var issues: [PlanIssue] = []
    var path = ""
    /// Opens a synthesized page (`t-…`, `x-…`) in the deck's section list.
    var onOpenSection: ((String) -> Void)?
    var onSay: ((String) -> Void)?
    /// `f` (or ⎋ while on) asks for the canvas: the page takes the whole window.
    var onCanvasToggle: (() -> Void)?
    var canvas = false { didSet { needsDisplay = true } }
    private(set) var cursor = 0
    private(set) var pick: Pick?
    private var hover: Pick?
    private var mvpOnly = false
    private var dragging: (extra: String, startY: CGFloat)?
    private var hits: [(rect: NSRect, pick: Pick)] = []
    private var mvpLineY: CGFloat = 0

    private let margin: CGFloat = 20
    private let minColumn: CGFloat = 92
    private let rowHeight: CGFloat = 26
    private let laneHeight: CGFloat = 24
    private let chipHeight: CGFloat = 18
    /// A branch name longer than this column wraps onto a second line of its chip instead of widening the stage.
    private let maxChipColumn: CGFloat = 230
    private let chipFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let chipFill = NSColor(name: "show.planChip") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.06)
    }
    private let inspectorWidth: CGFloat = 340
    private var width: CGFloat = 900
    /// Sized to the longest row or extra name, so no label truncates.
    private var labelWidth: CGFloat = 150
    /// Each stage's column, sized to its widest cell, chip or name, then widened evenly to fill the page.
    private var columns: [CGFloat] = []
    /// The inspector sits in a gutter right of the grid when the page is wide enough, else under it.
    private var docked = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(plan: Plan?, path: String) {
        let first = self.plan == nil || self.path != path
        self.plan = plan
        self.path = path
        issues = plan.map(lintPlan) ?? []
        if first {
            cursor = prefs.object(forKey: "plan.cursor." + path) as? Int ?? max((plan?.stages.count ?? 1) - 1, 0)
            mvpOnly = prefs.bool(forKey: "plan.mvp-only." + path)
        }
        cursor = min(cursor, max((plan?.stages.count ?? 1) - 1, 0))
        fit(width: width)
    }

    // MARK: geometry

    private var stageCount: Int { max(plan?.stages.count ?? 1, 1) }
    private func column(_ stage: Int) -> CGFloat { columns[safe: stage] ?? minColumn }
    private func x(_ stage: Int) -> CGFloat { margin + labelWidth + columns.prefix(max(stage, 0)).reduce(0, +) }
    /// The grid's right edge; lines and lanes stop here, and the docked inspector starts past it.
    private var gridRight: CGFloat { x(stageCount) }
    private func stage(atX px: CGFloat) -> Int {
        (0..<stageCount).first { px < x($0) + column($0) } ?? stageCount - 1
    }

    private func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The width each column needs for its content, before any widening.
    private func naturalColumns() -> [CGFloat] {
        guard let plan else { return [minColumn] }
        return plan.stages.indices.map { i in
            var need = textWidth(plan.stages[i].id, font(12, .bold)) + 32
            for row in plan.rows {
                need = max(need, textWidth(row.cells[safe: i] ?? "", font(11.5, .semibold)) + 22)
            }
            for branch in plan.branches(at: i) {
                need = max(need, branch.does == nil ? min(textWidth(branch.name, chipFont) + 26, maxChipColumn) : maxChipColumn)
            }
            return max(minColumn, need)
        }
    }

    private func naturalLabelWidth() -> CGFloat {
        let rows: [CGFloat] = (plan?.rows ?? []).map { textWidth($0.name, font(12, .semibold)) + 30 }
        let extras: [CGFloat] = (plan?.extras ?? []).map { textWidth("⚠ " + $0.name, font(12, .medium)) + 20 }
        let widest: CGFloat = (rows + extras).max() ?? 150
        return min(max(widest, 150), 360)
    }

    private var visibleExtras: [Plan.Extra] {
        let all = plan?.extras ?? []
        let ordered = all.filter(\.inMVP) + all.filter { !$0.inMVP }
        return mvpOnly ? ordered.filter(\.inMVP) : ordered
    }

    /// A branch card: its name, then what it does, wrapped to the column.
    private func card(_ branch: Plan.Branch, future: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString(string: chipLabel(branch.name), attributes: [
            .font: chipFont, .paragraphStyle: style,
            .foregroundColor: branch.does == nil && !future ? NSColor.labelColor : .secondaryLabelColor])
        if let does = branch.does, !does.isEmpty {
            let body = NSMutableParagraphStyle()
            body.lineBreakMode = .byWordWrapping
            body.paragraphSpacingBefore = 3
            body.lineSpacing = 1
            out.append(NSAttributedString(string: "\n" + does, attributes: [
                .font: font(11.5), .paragraphStyle: body, .foregroundColor: future ? NSColor.secondaryLabelColor : .labelColor]))
        }
        return out
    }

    private func chipHeight(_ branch: Plan.Branch, stage: Int) -> CGFloat {
        let wrapped = card(branch, future: false).boundingRect(with: NSSize(width: column(stage) - 28, height: 1000), options: [.usesLineFragmentOrigin])
        return max(chipHeight, ceil(wrapped.height) + (branch.does == nil ? 6 : 14))
    }

    /// Whether a row's `movedBy` names this branch.
    private func moves(_ row: Plan.Row, _ branch: String) -> Bool {
        (row.movedBy ?? "").components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }.contains(branch)
    }

    /// The branch under the pointer or selected, whose cells the grid outlines.
    private var linkedBranch: String? {
        if case .branch(let name) = hover ?? pick { return name }
        return nil
    }

    /// The row under the pointer or selected, whose branches light up.
    private var linkedRow: Plan.Row? {
        if case .row(let r) = hover ?? pick { return plan?.rows[safe: r] }
        return nil
    }

    /// The branch name with a break allowed after each hyphen, so a long one wraps instead of truncating.
    private func chipLabel(_ name: String) -> String { name.replacingOccurrences(of: "-", with: "-\u{200B}") }

    /// Branch chips stack in their stage's column, every one shown; the tallest stack sets the chip band's height.
    private var chipBand: CGFloat {
        guard let plan else { return 0 }
        return plan.stages.indices.map { i in plan.branches(at: i).reduce(0) { $0 + chipHeight($1, stage: i) + 4 } }.max() ?? 0
    }

    func fit(width available: CGFloat) {
        labelWidth = naturalLabelWidth()
        let natural = naturalColumns()
        let needed = margin * 2 + labelWidth + natural.reduce(0, +)
        docked = available >= needed + inspectorWidth + margin
        let room = available - (docked ? inspectorWidth + margin : 0)
        let spare = max(0, room - needed) / CGFloat(natural.count)
        columns = natural.map { $0 + min(spare, 120) }
        width = max(available, needed)
        let height = max(layoutHeight(), enclosingScrollView?.contentView.bounds.height ?? 0)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    private func layoutHeight() -> CGFloat {
        let rows = CGFloat(plan?.rows.count ?? 0)
        let lanes = CGFloat(visibleExtras.count)
        return 120 + rows * rowHeight + 40 + chipBand + 50 + lanes * laneHeight + 40 + (docked ? 0 : 240)
    }

    // MARK: drawing

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left, strike: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let height = font.boundingRectForFont.height
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func issue(row: Int, stage: Int) -> PlanIssue? {
        issues.first { $0.row == row && ($0.stage == stage || $0.stage == nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        hits = []
        guard let plan else {
            draw("No plan in this file", in: NSRect(x: margin, y: 40, width: 400, height: 20), font: font(14), color: .secondaryLabelColor)
            return
        }
        let accent = NSColor.controlAccentColor
        var y: CGFloat = 22

        draw(plan.fact ?? "Plan", in: NSRect(x: margin, y: y, width: gridRight - margin - 220, height: 22), font: font(15, .semibold), color: .labelColor)
        let errorCount = issues.filter { $0.level == .error }.count
        let lintLine = issues.isEmpty ? "✓ lint clean" : "✗ \(errorCount)  ⚠ \(issues.count - errorCount)"
        draw(lintLine + (mvpOnly ? "   · MVP only" : ""), in: NSRect(x: gridRight - 220, y: y, width: 220, height: 22), font: font(12, .medium),
             color: errorCount > 0 ? .systemRed : issues.isEmpty ? .secondaryLabelColor : .systemOrange, align: .right)
        y += 40

        let gridTop = y
        let cursorRect = NSRect(x: x(cursor), y: gridTop - 6, width: column(cursor), height: CGFloat(plan.rows.count) * rowHeight + 70)
        accent.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: cursorRect, xRadius: 6, yRadius: 6).fill()

        for (i, stage) in plan.stages.enumerated() {
            let rect = NSRect(x: x(i), y: y, width: column(i), height: 20)
            let selected = pick == .stage(i)
            draw(stage.id, in: rect.insetBy(dx: 6, dy: 0), font: font(12, i == cursor ? .bold : .semibold),
                 color: selected ? accent : i == cursor ? .labelColor : .secondaryLabelColor, align: .center)
            if stage.safe == false {
                draw("⚠", in: NSRect(x: rect.maxX - 16, y: y, width: 14, height: 20), font: font(10), color: .systemOrange)
            }
            hits.append((rect, .stage(i)))
        }
        y += 22
        for i in 0..<max(plan.stages.count - 1, 0) {
            let center = NSPoint(x: x(i + 1), y: y + 7)
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: center.x, y: center.y - 6))
            diamond.line(to: NSPoint(x: center.x + 6, y: center.y))
            diamond.line(to: NSPoint(x: center.x, y: center.y + 6))
            diamond.line(to: NSPoint(x: center.x - 6, y: center.y))
            diamond.close()
            let flagged = issues.contains { $0.transition == i && $0.level == .error }
            let chosen = pick == .transition(i) || hover == .transition(i)
            (flagged ? NSColor.systemRed : chosen ? accent : NSColor.tertiaryLabelColor).setFill()
            diamond.fill()
            hits.append((NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20), .transition(i)))
        }
        y += 18
        NSColor.separatorColor.setFill()
        NSRect(x: margin, y: y, width: gridRight - margin, height: 1).fill()
        y += 6

        draw("CORE", in: NSRect(x: margin, y: y, width: labelWidth, height: 14), font: font(9.5, .bold), color: .tertiaryLabelColor)
        y += 16
        for (r, row) in plan.rows.enumerated() {
            let values = plan.resolved(row)
            let rowRect = NSRect(x: margin, y: y, width: gridRight - margin, height: rowHeight)
            if pick == .row(r) || hover == .row(r) {
                NSColor.labelColor.withAlphaComponent(pick == .row(r) ? 0.07 : 0.035).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
            }
            let authority = row.kind == "authority"
            let kindMark = authority ? "◆" : row.kind == "reader" ? "◁" : row.kind == "writer" ? "▷" : "·"
            draw(kindMark, in: NSRect(x: margin + 4, y: y, width: 14, height: rowHeight), font: font(10), color: authority ? accent : .tertiaryLabelColor)
            draw(row.name, in: NSRect(x: margin + 20, y: y, width: labelWidth - 26, height: rowHeight), font: font(12, authority ? .semibold : .regular), color: .labelColor)
            hits.append((NSRect(x: margin, y: y, width: labelWidth, height: rowHeight), .row(r)))
            for i in 0..<plan.stages.count {
                let raw = row.cells[safe: i] ?? ""
                let value = values[safe: i] ?? ""
                let cell = NSRect(x: x(i) + 4, y: y + 2, width: column(i) - 8, height: rowHeight - 4)
                let changed = i > 0 && value != values[safe: i - 1]
                let future = i > cursor
                let alpha: CGFloat = future ? 0.4 : 1
                if authority, !isAbsent(value) {
                    accent.withAlphaComponent((i == cursor ? 0.28 : 0.13) * alpha).setFill()
                    NSBezierPath(roundedRect: cell, xRadius: 4, yRadius: 4).fill()
                }
                if changed, !future {
                    accent.setFill()
                    NSRect(x: cell.minX, y: cell.minY + 3, width: 2, height: cell.height - 6).fill()
                }
                if let branch = linkedBranch, moves(row, branch), plan.branches(at: i).contains(where: { $0.name == branch }) {
                    accent.setStroke()
                    let outline = NSBezierPath(roundedRect: cell, xRadius: 4, yRadius: 4)
                    outline.lineWidth = 2
                    outline.stroke()
                }
                if let flagged = issue(row: r, stage: i), flagged.stage == i {
                    (flagged.level == .error ? NSColor.systemRed : .systemOrange).setStroke()
                    let outline = NSBezierPath(roundedRect: cell, xRadius: 4, yRadius: 4)
                    outline.lineWidth = 1.5
                    outline.stroke()
                }
                let color: NSColor
                if isDitto(raw) || isAbsent(raw) {
                    color = .tertiaryLabelColor
                } else if isGone(raw) {
                    color = .secondaryLabelColor
                } else {
                    color = .labelColor
                }
                draw(isDitto(raw) ? "″" : raw, in: cell.insetBy(dx: 6, dy: 0), font: font(11.5, changed || authority ? .semibold : .regular),
                     color: color.withAlphaComponent(alpha), align: .center, strike: isGone(raw))
                hits.append((cell, .row(r)))
            }
            y += rowHeight
        }

        y += 10
        draw("BRANCHES", in: NSRect(x: margin, y: y, width: labelWidth, height: 14), font: font(9.5, .bold), color: .tertiaryLabelColor)
        let chipsTop = y
        for i in 0..<plan.stages.count {
            var chipY = chipsTop
            for branch in plan.branches(at: i) {
                let chip = NSRect(x: x(i) + 4, y: chipY, width: column(i) - 8, height: chipHeight(branch, stage: i))
                let chosen = pick == .branch(branch.name) || hover == .branch(branch.name)
                let lit = linkedRow.map { moves($0, branch.name) } ?? false
                let shape = NSBezierPath(roundedRect: chip, xRadius: branch.does == nil ? chipHeight / 2 : 7, yRadius: branch.does == nil ? chipHeight / 2 : 7)
                (chosen ? accent.withAlphaComponent(0.22) : lit ? accent.withAlphaComponent(0.12) : PlanView.chipFill).setFill()
                shape.fill()
                if lit || chosen {
                    accent.withAlphaComponent(0.8).setStroke()
                    shape.lineWidth = 1.5
                    shape.stroke()
                }
                card(branch, future: i > cursor).draw(with: chip.insetBy(dx: 10, dy: branch.does == nil ? 3 : 7),
                                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                hits.append((chip, .branch(branch.name)))
                chipY += chip.height + 4
            }
        }
        y = chipsTop + max(chipBand, 18) + 18

        NSColor.separatorColor.setFill()
        NSRect(x: margin, y: y, width: gridRight - margin, height: 1).fill()
        y += 8
        draw("EXTRAS", in: NSRect(x: margin, y: y, width: labelWidth, height: 14), font: font(9.5, .bold), color: .tertiaryLabelColor)
        draw("▼ cliff: leaving it out costs more from this stage on", in: NSRect(x: x(0), y: y, width: gridRight - x(0), height: 14),
             font: font(10), color: .tertiaryLabelColor)
        y += 20
        let extras = visibleExtras
        var drewLine = false
        for extra in extras {
            if !extra.inMVP, !drewLine {
                drawMVPLine(at: y + 2)
                y += 16
                drewLine = true
            }
            drawLane(extra, plan: plan, y: y)
            y += laneHeight
        }
        if !drewLine {
            drawMVPLine(at: y + 2)
            y += 16
        }

        y += 18
        drawInspector(plan: plan, top: y)
    }

    private func drawMVPLine(at y: CGFloat) {
        mvpLineY = y + 5
        let accent = NSColor.controlAccentColor
        let line = NSBezierPath()
        line.move(to: NSPoint(x: margin, y: mvpLineY))
        line.line(to: NSPoint(x: gridRight, y: mvpLineY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        accent.withAlphaComponent(0.6).setStroke()
        line.stroke()
        let label = "MVP ▲   later ▼"
        let rect = NSRect(x: margin + labelWidth - 104, y: y - 2, width: 100, height: 14)
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        draw(label, in: rect, font: font(9.5, .bold), color: accent, align: .right)
    }

    private func drawLane(_ extra: Plan.Extra, plan: Plan, y: CGFloat) {
        let accent = NSColor.controlAccentColor
        let laneRect = NSRect(x: margin, y: y, width: gridRight - margin, height: laneHeight)
        let chosen = pick == .extra(extra.id)
        if chosen || hover == .extra(extra.id) || dragging?.extra == extra.id {
            NSColor.labelColor.withAlphaComponent(chosen ? 0.07 : 0.035).setFill()
            NSBezierPath(roundedRect: laneRect, xRadius: 4, yRadius: 4).fill()
        }
        let warned = issues.first { $0.extra == extra.id }
        let name = (warned == nil ? "" : "⚠ ") + extra.name
        draw(name, in: NSRect(x: margin + 8, y: y, width: labelWidth - 14, height: laneHeight), font: font(12, extra.inMVP ? .medium : .regular),
             color: warned?.level == .error ? .systemRed : warned != nil ? .systemOrange : extra.inMVP ? .labelColor : .secondaryLabelColor)
        hits.append((laneRect, .extra(extra.id)))
        guard let start = plan.stageIndex(extra.start) else { return }
        let end = plan.stageIndex(extra.end) ?? plan.stages.count - 1
        let bar = NSRect(x: x(start) + 6, y: y + 8, width: max(x(end) + column(end) - x(start) - 12, 10), height: 8)
        (extra.inMVP ? accent : NSColor.tertiaryLabelColor).withAlphaComponent(extra.inMVP ? 0.85 : 0.5).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        if let cliff = plan.stageIndex(extra.cliff) {
            let cx = x(cliff) + 10
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: cx - 6, y: y + 2))
            triangle.line(to: NSPoint(x: cx + 6, y: y + 2))
            triangle.line(to: NSPoint(x: cx, y: y + 11))
            triangle.close()
            (extra.inMVP || extra.accepted != nil ? NSColor.secondaryLabelColor : .systemOrange).setFill()
            triangle.fill()
        }
    }

    /// Under the grid on a narrow page; on a wide one, a card in the gutter right of it that follows the scroll.
    private func drawInspector(plan: Plan, top: CGFloat) {
        let text = inspectorText(plan: plan, subject: hover ?? pick ?? .stage(cursor))
        let hint = "←→ stage · ↑↓ row · t transition · m MVP in/out (or drag across the line) · v MVP only · ↵ open page · o canopy · "
            + (canvas ? "f or ⎋ leaves canvas" : "f canvas") + " · = − zoom · 0 fit / actual size"
        var box = NSRect(x: margin, y: top, width: width - margin * 2, height: 210)
        if docked {
            let left = gridRight + margin
            let inner = inspectorWidth - 32
            let needed = text.boundingRect(with: NSSize(width: inner, height: 10_000), options: [.usesLineFragmentOrigin]).height
            let hintHeight = ceil((hint as NSString).boundingRect(with: NSSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin],
                                                                  attributes: [.font: font(10.5)]).height)
            let visible = visibleRect
            let height = min(ceil(needed) + hintHeight + 40, max(visible.height - 32, 160))
            box = NSRect(x: left, y: max(visible.minY + 16, 62), width: inspectorWidth, height: height)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            let body = NSRect(x: box.minX + 16, y: box.minY + 14, width: inner, height: box.height - hintHeight - 34)
            text.draw(with: body, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            (hint as NSString).draw(with: NSRect(x: body.minX, y: box.maxY - hintHeight - 12, width: inner, height: hintHeight),
                                    options: [.usesLineFragmentOrigin], attributes: [.font: font(10.5), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(with: box.insetBy(dx: 16, dy: 12), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        draw(hint, in: NSRect(x: margin, y: box.maxY + 8, width: box.width, height: 16), font: font(10.5), color: .tertiaryLabelColor)
    }

    private func inspectorText(plan: Plan, subject: Pick) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        func field(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            add(label + "  ", font(11, .semibold), .secondaryLabelColor)
            add(value + "\n", font(12))
        }
        switch subject {
        case .stage(let i):
            let stage = plan.stages[i]
            add("Stopping at \(stage.id)", font(14, .semibold))
            add(stage.kind.map { "  · \($0)" } ?? "", font(12), .secondaryLabelColor)
            add("\n", font(6))
            if let stop = stage.stop {
                add((stage.safe == false ? "⚠ " : "✓ ") + stop + "\n", font(12), stage.safe == false ? .systemOrange : .labelColor)
            }
            let changes = plan.changes(at: i)
            if !changes.isEmpty {
                field("changes", changes.map { "\($0.row.name): \($0.before) → \($0.after)" }.joined(separator: " · "))
            }
            field("deploys", plan.branches(at: i).map(\.name).joined(separator: "\n"))
            field("lint", issues.filter { $0.stage == i }.map(\.message).joined(separator: " · "))
        case .transition(let i):
            let transition = plan.transition(from: i)
            add("\(plan.stages[i].id) → \(plan.stages[i + 1].id)\n", font(14, .semibold))
            field("gate", transition?.gate ?? "none stated")
            field("manual", transition?.manual)
            field("rollback", transition?.rollback ?? "missing")
            add("↵ opens its sign-off page", font(11), .tertiaryLabelColor)
        case .row(let r):
            let row = plan.rows[r]
            add(row.name, font(14, .semibold))
            add("  · \(row.kind)\n", font(12), .secondaryLabelColor)
            field("where", row.where)
            field("moved by", row.movedBy)
            field("stages", zip(plan.stages, plan.resolved(row)).map { "\($0.id): \($1)" }.joined(separator: " · "))
            field("lint", issues.filter { $0.row == r }.map(\.message).joined(separator: " · "))
        case .extra(let id):
            guard let extra = plan.extras?.first(where: { $0.id == id }) else { break }
            add(extra.name, font(14, .semibold))
            add(extra.inMVP ? "  · MVP\n" : "  · later\n", font(12), extra.inMVP ? .controlAccentColor : .secondaryLabelColor)
            field("span", extra.start + " → " + (extra.end ?? plan.stages.last?.id ?? ""))
            field("cliff", extra.cliff.map { "\($0): " + (extra.why ?? "") } ?? "none, can land any time")
            field("accepted", extra.accepted)
            field("detail", extra.detail)
            field("lint", issues.filter { $0.extra == id }.map(\.message).joined(separator: " · "))
        case .branch(let name):
            add(name + "\n", .monospacedSystemFont(ofSize: 13, weight: .semibold))
            field("deploys at", plan.branches?.first { $0.name == name }?.stage)
            add("o or double-click opens it in canopy", font(11), .tertiaryLabelColor)
        }
        return out
    }

    // MARK: input

    private func hit(_ point: NSPoint) -> Pick? { hits.last { $0.rect.contains(point) }?.pick }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let found = hit(convert(event.locationInWindow, from: nil))
        if found != hover {
            hover = found
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let found = hit(point) else { return }
        choose(found, settingCursorAt: point)
        if case .extra(let id) = found {
            dragging = (id, point.y)
        }
        if event.clickCount == 2 {
            activate()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging != nil else { return }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = nil; needsDisplay = true }
        guard let (id, startY) = dragging, let extra = plan?.extras?.first(where: { $0.id == id }) else { return }
        let endY = convert(event.locationInWindow, from: nil).y
        let crossedUp = !extra.inMVP && startY > mvpLineY && endY < mvpLineY
        let crossedDown = extra.inMVP && startY < mvpLineY && endY > mvpLineY
        if crossedUp || crossedDown {
            setMVP(extra, to: crossedUp)
        }
    }

    private func choose(_ found: Pick, settingCursorAt point: NSPoint? = nil) {
        pick = found
        switch found {
        case .stage(let i): cursor = i
        case .transition(let i): cursor = i + 1
        case .branch(let name):
            if let stage = plan?.stageIndex(plan?.branches?.first { $0.name == name }?.stage) { cursor = stage }
        case .row, .extra:
            if let point, point.x > x(0) {
                cursor = stage(atX: point.x)
            }
        }
        prefs.set(cursor, forKey: "plan.cursor." + path)
        needsDisplay = true
        scrollToVisible(NSRect(x: x(cursor) - 20, y: visibleRect.minY, width: column(cursor) + 40, height: 1))
    }

    /// ↵ or a double-click: a transition or extra opens its sign-off page, a branch opens in canopy.
    private func activate() {
        guard let plan, let pick else { return }
        switch pick {
        case .transition(let i): onOpenSection?("t-\(plan.stages[i].id)-\(plan.stages[i + 1].id)")
        case .stage(let i) where i > 0: onOpenSection?("t-\(plan.stages[i - 1].id)-\(plan.stages[i].id)")
        case .extra(let id): onOpenSection?("x-\(id)")
        case .branch(let name): openBranch(name)
        default: break
        }
    }

    private func openBranch(_ name: String) {
        guard let url = URL(string: "canopy://v2/b/\(plan?.repo ?? "loops")/\(name)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func setMVP(_ extra: Plan.Extra, to value: Bool) {
        do {
            try setExtraMVP(path: path, extra: extra.id, to: value)
            onSay?("\(extra.name) \(value ? "moved into the MVP" : "moved out of the MVP")")
        } catch {
            onSay?("Couldn't write the plan: \(error.localizedDescription)")
        }
    }

    /// The ↑↓ order: the core's rows, then the visible extras.
    private var vertical: [Pick] {
        (0..<(plan?.rows.count ?? 0)).map(Pick.row) + visibleExtras.map { Pick.extra($0.id) }
    }

    override func keyDown(with event: NSEvent) {
        guard let plan else { return super.keyDown(with: event) }
        let key = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, key) {
        case (123, _), (_, "h"):
            if case .transition(let i) = pick, i > 0 { choose(.transition(i - 1)) } else { choose(.stage(max(cursor - 1, 0))) }
        case (124, _), (_, "l"):
            if case .transition(let i) = pick, i + 2 < plan.stages.count { choose(.transition(i + 1)) } else { choose(.stage(min(cursor + 1, plan.stages.count - 1))) }
        case (125, _), (126, _), (_, "j"), (_, "k"):
            let step = event.keyCode == 125 || key == "j" ? 1 : -1
            let order = vertical
            guard !order.isEmpty else { return }
            let at = pick.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
            pick = order[min(max(at + step, 0), order.count - 1)]
            needsDisplay = true
            scrollToPick()
        case (36, _), (76, _):
            activate()
        case (_, "m"):
            guard case .extra(let id) = pick, let extra = plan.extras?.first(where: { $0.id == id }) else {
                onSay?("m moves the selected extra in or out of the MVP")
                return
            }
            setMVP(extra, to: !extra.inMVP)
        case (_, "v"):
            mvpOnly.toggle()
            prefs.set(mvpOnly, forKey: "plan.mvp-only." + path)
            if case .extra(let id) = pick, mvpOnly, plan.extras?.first(where: { $0.id == id })?.inMVP == false { pick = nil }
            fit(width: width)
        case (_, "o"):
            guard case .branch(let name) = pick else {
                onSay?("o opens the selected branch in canopy")
                return
            }
            openBranch(name)
        case (_, "t"):
            choose(.transition(max(min(cursor - 1, plan.stages.count - 2), 0)))
        case (_, "f"):
            onCanvasToggle?()
        case (53, _) where canvas:
            onCanvasToggle?()
        case (_, "="), (_, "+"), (_, "-"), (_, "0"):
            guard let scroll = enclosingScrollView else { return }
            let fitted = scroll.contentSize.width / (margin * 2 + labelWidth + naturalColumns().reduce(0, +))
            let target = key == "0" ? (scroll.magnification < 0.99 ? 1 : min(fitted, 1)) : scroll.magnification * (key == "-" ? 1 / 1.15 : 1.15)
            scroll.animator().magnification = min(max(target, scroll.minMagnification), scroll.maxMagnification)
        default:
            super.keyDown(with: event)
        }
    }

    private func scrollToPick() {
        guard let pick, let rect = hits.first(where: { $0.pick == pick })?.rect else { return }
        scrollToVisible(rect.insetBy(dx: 0, dy: -40))
    }
}
