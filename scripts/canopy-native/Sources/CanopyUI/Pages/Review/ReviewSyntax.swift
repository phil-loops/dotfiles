import CanopyCore
import Foundation

@MainActor
final class ReviewSyntax {
    static func of(_ app: AppModel) -> ReviewSyntax { app.state { ReviewSyntax(app) } }

    private weak var app: AppModel?
    private(set) var task: Task<Void, Never>?

    init(_ app: AppModel) { self.app = app }

    func step(_ direction: Int, types: Bool) throws {
        guard let app else { return }
        let page = ReviewPageState.of(app), units = ReviewUnits.of(app), lookup = CodeLookup.of(app)
        guard app.pane?.id == reviewDiffPane, let here = page.here, !here.path.isEmpty else { throw Refusal("] f / ] t walk the diff's code") }
        guard page.diffCurrent else { throw Refusal("reading the current diff") }
        guard let source = units.source(page, path: here.path) else { throw Refusal("syntax needs an immutable source for this diff") }
        guard let origin = Self.cursorOrigin(here, page: page) else { throw Refusal("stand on code, a file header or a context gap to walk its syntax") }
        let context = page.contextKey, display = page.payloadGen
        let epoch = app.store.epoch, git = app.store.versions[Domain.git]
        guard let request = lookup.beginRequest(waiting: "reading the syntax…") else { return }
        task = Task { @MainActor in
            @MainActor func current() -> Bool {
                guard lookup.isCurrent(request) else { return false }
                guard !Task.isCancelled, page.diffCurrent, page.contextKey == context, page.payloadGen == display,
                      units.source(page, path: source.path) == source, app.store.epoch == epoch, app.store.versions[Domain.git] == git else {
                    lookup.dismiss()
                    return false
                }
                return true
            }
            guard current() else { return }
            let syntax = await units.syntax(page, path: source.path)
            guard current() else { return }
            guard let syntax else {
                lookup.dismiss()
                return app.runner.say("couldn't read the syntax · try again")
            }
            if let unavailable = syntax.unavailable {
                lookup.dismiss()
                return app.runner.say(unavailable.isEmpty ? "syntax isn't available for this file · try again" : unavailable)
            }
            let spans = syntax.touched(types ? syntax.classes : syntax.functions)
            let span = direction > 0 ? spans.first { origin.precedes($0.line) } : spans.last { origin.follows($0.line) }
            guard let span else {
                lookup.dismiss()
                let noun = types ? "type" : "function"
                return app.runner.say(spans.isEmpty ? "no \(noun) this change touches in \(shortPath(source.path))"
                    : "the \(direction > 0 ? "last" : "first") \(noun) this change touches in \(shortPath(source.path))")
            }
            @MainActor func destination() -> String? {
                page.stops.first { $0.path == source.path && $0.kind == .line && $0.row?.right?.new == span.line }?.key
            }
            if destination() == nil {
                guard let file = page.fileOf(source.path), let gap = file.gaps.first(where: { $0.first <= span.line && span.line <= ($0.last ?? .max) }) else {
                    lookup.dismiss()
                    return app.runner.say("that \(types ? "type" : "function") is outside this diff's available context")
                }
                let below = gap.at >= file.file.hunks.count
                let n = below ? span.line - gap.first + 1 : (gap.last ?? span.line) - span.line + 1
                let prepared = await page.prepareContext(source.path)
                guard current() else { return }
                lookup.dismiss()
                guard let prepared, page.reveal(prepared, at: gap.at, n: n) else {
                    return app.runner.say("couldn't read that function or type's context · try again")
                }
            } else { lookup.dismiss() }
            guard let destination = destination() else { return app.runner.say("that function or type isn't in the returned source") }
            if app.keys.mode != .select { page.mark = nil }
            page.setCursor(destination)
            app.runner.say(span.name)
        }
    }

    private enum Origin {
        case line(Int)
        case boundary(Int)

        func precedes(_ candidate: Int) -> Bool {
            switch self {
            case let .line(line): line < candidate
            case let .boundary(line): line <= candidate
            }
        }

        func follows(_ candidate: Int) -> Bool {
            switch self {
            case let .line(line), let .boundary(line): line > candidate
            }
        }
    }

    private static func cursorOrigin(_ stop: Stop, page: ReviewPageState) -> Origin? {
        guard let file = page.fileOf(stop.path) else { return nil }
        if stop.kind == .file { return .boundary(1) }
        if stop.kind == .gap, let at = stop.at, let gap = file.gaps.first(where: { $0.at == at }) { return .boundary(gap.first) }
        guard stop.kind == .line, let row = stop.row else { return nil }
        if let line = row.right?.new { return .line(line) }
        guard file.file.hunks.indices.contains(row.hunk) else { return nil }
        let hunk = file.file.hunks[row.hunk]
        guard let header = HunkHeader(hunk.header) else { return nil }
        var boundary = header.nl == 0 ? header.ns + 1 : header.ns
        for line in hunk.lines {
            if line.old == row.left?.old, line.kind == .del { return .boundary(boundary) }
            if let new = line.new { boundary = new + 1 }
        }
        return nil
    }
}
