import Foundation
import Observation

/// A place in code: a file at a commit, a line, and the span to light (nav.ts Loc).
public struct Loc: Equatable, Hashable, Sendable {
    public var repo: String
    public var sha: String
    public var path: String
    public var line: Int
    public var end: Int?
    /// a review-page diff stop, when the place is a line of the diff itself
    public var diffKey: String?
    public init(repo: String, sha: String, path: String, line: Int, end: Int? = nil, diffKey: String? = nil) {
        self.repo = repo; self.sha = sha; self.path = path; self.line = line; self.end = end; self.diffKey = diffKey
    }
}

public struct PickItem: Equatable, Sendable {
    public var loc: Loc
    public var label: String
    /// the source line beside the label, read when the picker opens
    public var text: String?
    /// a non-code item: picking it runs this command with `arg` instead of going to `loc`
    public var command: String?
    public var arg: String?
    public init(loc: Loc, label: String, text: String? = nil) { self.loc = loc; self.label = label; self.text = text }

    /// An item that isn't a code place (a branch, a jumplist entry): picking it runs `command(arg)`.
    public init(label: String, text: String? = nil, command: String, arg: String?) {
        self.loc = Loc(repo: "", sha: "", path: "", line: 0)
        self.label = label; self.text = text; self.command = command; self.arg = arg
    }
}

/// The picker's filter, as Helix's (pick.ts): every typed character in order, best first. Lower
/// is better; nil when it doesn't match.
public func pickScore(_ text: String, _ want: String) -> Int? {
    let w = Array(want.filter { !$0.isWhitespace })
    if w.isEmpty { return 0 }
    let t = Array(text)
    if let run = text.range(of: String(w)) { return text.distance(from: text.startIndex, to: run.lowerBound) }
    var at = 0
    var first = -1
    for c in w {
        guard let i = t[at...].firstIndex(of: c) else { return nil }
        if first < 0 { first = i }
        at = i + 1
    }
    return 1000 + (at - first) * 10 + first
}

/// The items matching `want`, best first; ties keep their order.
public func ranked<T>(_ items: [T], _ want: String, _ textOf: (T) -> String) -> [T] {
    let f = want.lowercased()
    if f.trimmingCharacters(in: .whitespaces).isEmpty { return items }
    return items.enumerated()
        .compactMap { i, it in pickScore(textOf(it).lowercased(), f).map { (it, i, $0) } }
        .sorted { ($0.2, $0.1) < ($1.2, $1.1) }
        .map(\.0)
}

/// Code navigation the Helix way (nav.ts), shared by every surface that shows code: a jumplist
/// (C-o back, C-i forward) and a picker for answers with several places. A surface attaches how it
/// opens a place and where it is now; the picker and the jumplist only ever go through that.
@MainActor
@Observable
public final class CodeNav {
    public struct Attached {
        public var open: (Loc) -> Void
        public var here: () -> Loc?
        public init(open: @escaping (Loc) -> Void, here: @escaping () -> Loc?) { self.open = open; self.here = here }
    }

    public private(set) var back: [Loc] = []
    public private(set) var fwd: [Loc] = []
    public private(set) var picker: (title: String, items: [PickItem])?
    public private(set) var filter = ""
    public private(set) var index = 0
    /// The picker opened / closed: the shell raises and drops the `picker` key layer with it.
    @ObservationIgnored public var onPickerChange: ((Bool) -> Void)?
    @ObservationIgnored private var surface: Attached?
    @ObservationIgnored private var surfaceID = 0
    /// The app-wide jumplist (the shell sets it): `go` records there instead of in `back`/`fwd`.
    @ObservationIgnored public var record: (() -> Void)?
    /// Runs a non-code item's command (the shell sets it to the runner, via the picker).
    @ObservationIgnored public var run: ((_ command: String, _ arg: String?) -> Void)?
    @ObservationIgnored private var pending: Loc?
    @ObservationIgnored private var rank: (([PickItem], String) -> [PickItem])?
    /// The last picker closed, with its query: `space '` reopens it.
    @ObservationIgnored public private(set) var last: (title: String, items: [PickItem], filter: String, rank: (([PickItem], String) -> [PickItem])?)?

    public init() {}

    /// The surface on screen says how to open a place and where it is; the returned detach only
    /// removes that surface, so a page mounting over its old copy keeps the new one.
    public func attach(_ s: Attached) -> () -> Void {
        surfaceID += 1
        let mine = surfaceID
        surface = s
        if let l = pending {
            pending = nil
            s.open(l)
        }
        return { [weak self] in if self?.surfaceID == mine { self?.surface = nil } }
    }

    /// Go somewhere, remembering where from.
    public func go(_ l: Loc) {
        if let record {
            record()
        } else {
            if let from = surface?.here() { back = Array((back + [from]).suffix(100)) }
            fwd = []
        }
        surface?.open(l)
    }

    /// Where the attached code surface is now (nil when none is attached).
    public var here: Loc? { surface?.here() }

    /// Open a place without recording a jump (the jumplist restoring one). With no surface
    /// attached yet — the page is still mounting — it opens when one attaches.
    public func open(_ l: Loc) {
        if let s = surface { s.open(l) } else { pending = l }
    }

    @discardableResult public func goBack() -> Bool { step(back: true) }
    @discardableResult public func goForward() -> Bool { step(back: false) }

    private func step(back isBack: Bool) -> Bool {
        let list = isBack ? back : fwd
        guard let to = list.last, let s = surface else { return false }
        if isBack { back.removeLast() } else { fwd.removeLast() }
        if let now = s.here() { if isBack { fwd.append(now) } else { back.append(now) } }
        s.open(to)
        return true
    }

    public func pick(_ title: String, _ items: [PickItem]) {
        filter = ""
        index = 0
        rank = nil
        picker = (title, items)
        onPickerChange?(true)
    }

    /// A picker with its own ranking (`space b`: fuzzy × frecency) — `rank(items, filter)` replaces
    /// the default fuzzy order.
    public func pick(_ title: String, _ items: [PickItem], rank: @escaping ([PickItem], String) -> [PickItem]) {
        pick(title, items)
        self.rank = rank
    }

    /// `space '`: the last picker again, with its query. False when there was none.
    @discardableResult
    public func reopen() -> Bool {
        guard let l = last else { return false }
        pick(l.title, l.items)
        rank = l.rank
        filter = l.filter
        return true
    }

    private func remember() {
        if let p = picker { last = (p.title, p.items, filter, rank) }
    }

    /// Fill a row's source line once its file arrives.
    public func setText(_ i: Int, _ text: String) {
        guard var p = picker, p.items.indices.contains(i) else { return }
        p.items[i].text = text
        picker = p
    }

    public var shown: [PickItem] {
        guard let p = picker else { return [] }
        if let rank { return rank(p.items, filter) }
        return ranked(p.items, filter) { "\($0.label) \($0.text ?? "")" }
    }

    public func move(_ d: Int) { index = max(0, min(shown.count - 1, index + d)) }

    @discardableResult
    public func choose(_ i: Int? = nil) -> Bool {
        let s = shown
        let n = i ?? index
        guard s.indices.contains(n) else { return false }
        remember()
        picker = nil
        onPickerChange?(false)
        if let c = s[n].command {
            run?(c, s[n].arg)
        } else {
            go(s[n].loc)
        }
        return true
    }

    public func close() {
        guard picker != nil else { return }
        remember()
        picker = nil
        onPickerChange?(false)
    }

    public func typed(_ f: String) {
        filter = f
        index = 0
    }
}
