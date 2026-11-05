import CanopyCore
import Foundation
import Observation

/// One window of the review page (Helix's View): it shows the diff (`doc` nil) or one file at one
/// commit, with its own cursor (its pane's), scroll (its canvas) and jumps (the jumplist's entries
/// tagged with its id). The diff shows in at most one window; `ReviewPageState.windows` keeps that.
@MainActor
@Observable
public final class ReviewWindow {
    public let id: Int
    /// The file it shows, at its commit; nil: the diff.
    public internal(set) var doc: Loc?
    public internal(set) var text: String?
    /// The name `w` / `b` put the cursor on: its line and UTF-16 range.
    public var word: (line: Int, at: Range<Int>)?
    /// Its column among the vertical splits, left to right; windows sharing one stack top to bottom.
    var column: Int
    @ObservationIgnored let canvas = CanvasHandle()

    init(id: Int, column: Int, doc: Loc? = nil) {
        self.id = id; self.column = column; self.doc = doc
    }

    /// Its pane: the diff's while it shows the diff, else its own code pane.
    public var pane: String { doc == nil ? reviewDiffPane : id == 1 ? reviewCodePane : "\(reviewCodePane).\(id)" }
    /// Its rows: one per line of the file ("s:<n>").
    var codeRows: [String] {
        guard doc != nil, let t = text else { return [] }
        return (1...max(1, t.components(separatedBy: "\n").count)).map { "s:\($0)" }
    }
}

extension ReviewPageState {
    /// The window the keyboard is in; nil while it's in a pane that isn't one (the files, the commits).
    public var focusedWindow: ReviewWindow? { windows.first { $0.pane == app?.pane?.id } }
    /// The focused window, when it shows a file.
    public var code: ReviewWindow? { focusedWindow.flatMap { $0.doc == nil ? nil : $0 } }
    /// The window showing the diff, if one does.
    var diffWindow: ReviewWindow? { windows.first { $0.doc == nil } }
    /// Where a jump lands: the focused window, else the first.
    var jumpWindow: ReviewWindow { focusedWindow ?? windows[0] }

    public func window(pane id: String?) -> ReviewWindow? { windows.first { $0.pane == id } }

    /// The windows by column, each column top to bottom.
    var columns: [[ReviewWindow]] {
        Dictionary(grouping: windows, by: \.column).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Show a file in a window (Helix's Action::Replace): its line centred, the keyboard there.
    func show(_ l: Loc, in w: ReviewWindow) {
        let same = w.doc
        w.doc = l
        w.word = nil
        guard let app else { return }
        app.focus(pane: w.pane)
        app.setCursor("s:\(l.line)")
        if let same, same.repo == l.repo, same.sha == l.sha, same.path == l.path, w.text != nil { return }
        w.text = nil
        let k = "\(l.repo)|\(l.sha)|\(l.path)"
        if let lines = cachedLines(k) { w.text = lines.joined(separator: "\n"); app.setCursor("s:\(l.line)"); return }
        Task { @MainActor [weak self, weak w] in
            let lines = await self?.linesOf(l) ?? []
            guard let w, w.doc == l else { return }
            w.text = lines.joined(separator: "\n")
            if self?.app?.pane?.id == w.pane { self?.app?.setCursor("s:\(l.line)") }
        }
    }

    /// Show the diff in a window — unless another already does: the diff lives in one window, so the
    /// keyboard goes to that one instead. Returns the window the diff is in.
    @discardableResult
    func showDiff(in w: ReviewWindow) -> ReviewWindow {
        if let d = diffWindow { app?.focus(pane: d.pane); return d }
        w.doc = nil
        w.text = nil
        w.word = nil
        app?.focus(pane: reviewDiffPane)
        return w
    }

    /// C-w v (`below` false) / C-w s: a copy of the focused window beside it or under it — the same
    /// file, line and name — and the keyboard in the copy. A copy of the diff is the file you're on,
    /// at your line on the tip, since the diff lives in one window.
    func split(below: Bool) throws {
        guard let w = focusedWindow else { throw Refusal("no window here · C-w l goes to one") }
        guard let at = herePlace() else { throw Refusal("nothing to copy here") }
        let word = w.doc == nil ? nil : w.word
        let copy = addWindow(next: w, below: below)
        show(Self.asFile(at), in: copy)
        copy.word = word
    }

    /// Picker C-v / C-s: the picked place in a new window beside or under the focused one.
    func openInSplit(_ l: Loc, below: Bool) {
        show(Self.asFile(l), in: addWindow(next: focusedWindow ?? windows[0], below: below))
    }

    private static func asFile(_ at: Loc) -> Loc {
        var l = at
        l.diffKey = nil
        l.end = nil
        l.asFile = true
        return l
    }

    private func addWindow(next w: ReviewWindow, below: Bool) -> ReviewWindow {
        let n = (windows.map(\.id).max() ?? 0) + 1
        let column: Int
        if below {
            column = w.column
        } else {
            column = w.column + 1
            for o in windows where o.column > w.column { o.column += 1 }
        }
        let copy = ReviewWindow(id: n, column: column)
        let i = windows.firstIndex { $0 === w }.map { $0 + 1 } ?? windows.count
        windows.insert(copy, at: below ? i : windows.lastIndex { $0.column <= w.column }.map { $0 + 1 } ?? windows.count)
        return copy
    }

    /// C-w q: close the focused window; the last one stays.
    func closeWindow() throws {
        guard let w = focusedWindow else { throw Refusal("no window here · C-w l goes to one") }
        guard windows.count > 1 else { throw Refusal("the last window · C-o goes back") }
        let i = windows.firstIndex { $0 === w } ?? 0
        windows.remove(at: i)
        normalizeColumns()
        let next = windows[min(i, windows.count - 1)]
        app?.focus(pane: next.pane)
    }

    /// C-w o: only the focused window.
    func onlyWindow() throws {
        guard let w = focusedWindow else { throw Refusal("no window here · C-w l goes to one") }
        guard windows.count > 1 else { throw Refusal("already the only window") }
        windows = [w]
        normalizeColumns()
        app?.focus(pane: w.pane)
    }

    private func normalizeColumns() {
        let order = Array(Set(windows.map(\.column))).sorted()
        for w in windows { w.column = order.firstIndex(of: w.column) ?? 0 }
    }

    /// The jumps C-o / C-i walk from here (Helix's per-view jumplist): those made in the focused
    /// window; entries from other pages belong to the first window.
    func jumpStream(route: Route) -> ((Place) -> Bool)? {
        guard let w = focusedWindow else { return nil }
        let first = windows[0].id
        return { p in p.route != route ? w.id == first : (p.window ?? first) == w.id }
    }
}
