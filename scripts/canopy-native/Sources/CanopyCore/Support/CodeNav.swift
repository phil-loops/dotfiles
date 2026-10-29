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
    public init(loc: Loc, label: String, text: String? = nil) { self.loc = loc; self.label = label; self.text = text }
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

    public init() {}

    /// The surface on screen says how to open a place and where it is; the returned detach only
    /// removes that surface, so a page mounting over its old copy keeps the new one.
    public func attach(_ s: Attached) -> () -> Void {
        surfaceID += 1
        let mine = surfaceID
        surface = s
        return { [weak self] in if self?.surfaceID == mine { self?.surface = nil } }
    }

    /// Go somewhere, remembering where from.
    public func go(_ l: Loc) {
        if let from = surface?.here() { back = Array((back + [from]).suffix(100)) }
        fwd = []
        surface?.open(l)
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
        picker = (title, items)
        onPickerChange?(true)
    }

    /// Fill a row's source line once its file arrives.
    public func setText(_ i: Int, _ text: String) {
        guard var p = picker, p.items.indices.contains(i) else { return }
        p.items[i].text = text
        picker = p
    }

    public var shown: [PickItem] {
        guard let p = picker else { return [] }
        return ranked(p.items, filter) { "\($0.label) \($0.text ?? "")" }
    }

    public func move(_ d: Int) { index = max(0, min(shown.count - 1, index + d)) }

    @discardableResult
    public func choose(_ i: Int? = nil) -> Bool {
        let s = shown
        let n = i ?? index
        guard s.indices.contains(n) else { return false }
        picker = nil
        onPickerChange?(false)
        go(s[n].loc)
        return true
    }

    public func close() {
        guard picker != nil else { return }
        picker = nil
        onPickerChange?(false)
    }

    public func typed(_ f: String) {
        filter = f
        index = 0
    }
}
