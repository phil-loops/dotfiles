import CanopyCore
import Foundation
import Observation
import SwiftUI

// Code navigation the Helix way (review/types.ts), for any pane that shows code — the review diff,
// its side pane, the Tutor's pinned code. `space k` shows the type, `g d` / `g y` / `g I` / `g r` go
// to the definition, the type's definition, the implementations, the references; `space S` lists
// the file's symbols. One place goes straight there through `app.nav.go` (recorded on the app-wide
// jumplist; the attached surface opens it), several open the picker. Answers come from the server's
// `/lsp/*` (srv/lsp.py's one tsgo — never a process of ours); a "loading" answer is asked again
// every 500ms for up to 90s, and a newer ask (or `dismiss`) silences an older one.
//
// The published API (area D, Tutor, uses it for its code pane):
//
//   let pos = CodeLookup.position(path:, line:, text:, side: .new)   // the line's first name worth a type
//   let at  = CodeLookup.Where.commit(repo:, sha:)                   // or .branch(repo:, name:, base:)
//   CodeLookup.of(app).hover(pos, at)             // space k → `pop` (TypesPopView draws it)
//   CodeLookup.of(app).goto(.definition, pos, at) // g d / g y / g I / g r → app.nav.go or the picker
//   CodeLookup.of(app).symbols(path:, side:, at)  // space S → the picker
//   CodeLookup.of(app).dismiss()                  // esc, or the cursor moved

@MainActor
@Observable
public final class CodeLookup {
    /// A position in code to ask about: the file, 1-based line, 0-based UTF-16 character, which side
    /// of a diff it's on, and where `.member` starts when the name has one (a namespace's member is
    /// what g d wants).
    public struct Position: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var character: Int
        public var side: String
        public var member: Int?
        public init(path: String, line: Int, character: Int, side: String = "new", member: Int? = nil) {
            self.path = path; self.line = line; self.character = character; self.side = side; self.member = member
        }
    }

    /// Where the code is read: a pinned commit, or a branch's tip (the old half of a diff at its base).
    public enum Where: Equatable, Sendable {
        case commit(repo: String, sha: String)
        case branch(repo: String, name: String, base: String?)

        public var repo: String {
            switch self { case .commit(let r, _), .branch(let r, _, _): r }
        }
    }

    /// What the popover shows: a line saying what tsgo is doing (or why not), or the type.
    public enum Pop: Equatable, Sendable {
        case wait(String)
        case note(String)
        case hover(String)
        public var text: String { switch self { case .wait(let t), .note(let t), .hover(let t): t } }
    }

    public private(set) var pop: Pop?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var seq = 0
    /// How long a "loading" answer is asked again for, and how often (tests shorten them).
    @ObservationIgnored var patience: TimeInterval = 90
    @ObservationIgnored var retry: TimeInterval = 0.5

    init(_ app: AppModel) { self.app = app }

    public static func of(_ app: AppModel) -> CodeLookup { app.state { CodeLookup(app) } }

    // ── positions ──

    /// Names K skips on a line, looking for the first worth a type.
    nonisolated static let skip: Set<String> = Set("import export from const let var function return type interface async await new if else for while of in as default class extends implements".split(separator: " ").map(String.init))

    nonisolated private static func isWord(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
    }

    /// The identifier around a UTF-16 offset (v1's lspKeys.wordAt), as [start, end).
    nonisolated public static func wordAt(_ text: String, _ at: Int) -> (start: Int, end: Int)? {
        let u = Array(text.utf16)
        func w(_ i: Int) -> Bool { i >= 0 && i < u.count && isWord(u[i]) }
        var i = at
        if !w(i) {
            if !w(i - 1) { return nil }
            i -= 1
        }
        var s = i, e = i + 1
        while w(s - 1) { s -= 1 }
        while w(e) { e += 1 }
        return (s, e)
    }

    nonisolated static func memberAt(_ u: [UInt16], _ end: Int) -> Int? {
        end + 1 < u.count && u[end] == 0x2E && isWord(u[end + 1]) ? end + 1 : nil
    }

    /// The first name on a line worth asking about (keywords skipped) — what K points at from the
    /// keyboard. nil when the line has none.
    /// Every name on a line worth asking about, as UTF-16 ranges, in order (what `w` / `b` step through).
    nonisolated public static func names(_ text: String) -> [Range<Int>] {
        let u = Array(text.utf16)
        var out: [Range<Int>] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            let start = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
            if !start { i += 1; continue }
            var j = i + 1
            while j < u.count, isWord(u[j]) { j += 1 }
            if !skip.contains(String(utf16CodeUnits: Array(u[i..<j]), count: j - i)) { out.append(i..<j) }
            i = j
        }
        return out
    }

    nonisolated public static func position(path: String, line: Int, text: String, side: String = "new") -> Position? {
        let u = Array(text.utf16)
        var i = 0
        while i < u.count {
            let c = u[i]
            let start = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
            if !start { i += 1; continue }
            var j = i + 1
            while j < u.count, isWord(u[j]) { j += 1 }
            let word = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
            if !skip.contains(word) { return Position(path: path, line: line, character: i, side: side, member: memberAt(u, j)) }
            i = j
        }
        return nil
    }

    /// The name at a UTF-16 offset of a line (the pointer's), or nil when it's not on a name.
    nonisolated public static func position(path: String, line: Int, text: String, at: Int, side: String = "new") -> Position? {
        guard let w = wordAt(text, at) else { return nil }
        return Position(path: path, line: line, character: w.start, side: side, member: memberAt(Array(text.utf16), w.end))
    }

    // ── asking ──

    private struct Body: Encodable {
        var path: String
        var line: Int?
        var character: Int?
        var side: String
        var sha: String?
        var branch: String?
        var base: String?
    }

    private func body(_ p: Position?, path: String, side: String, _ w: Where) -> Body {
        var b = Body(path: path, line: p?.line, character: p?.character, side: side)
        switch w {
        case .commit(_, let sha): b.sha = sha
        case .branch(_, let name, let base):
            b.branch = name
            if side == "old", let base, !base.isEmpty { b.base = base }
        }
        return b
    }

    /// Ask until the answer settles: nil when a newer ask took over.
    private func asking<T: Decodable & Settles>(_ route: String, _ w: Where, _ body: Body, _ t: T.Type) async -> T? {
        seq += 1
        let mine = seq
        let t0 = Date()
        guard let app else { return nil }
        let path = app.transport.atRepo(w.repo, route)
        while true {
            let r = await app.transport.ask(path, body, as: T.self)
            if mine != seq { return nil }
            guard let r, !r.ok, r.state == "loading", Date().timeIntervalSince(t0) < patience else { return r }
            pop = .wait("types are loading — \(r.message?.isEmpty == false ? r.message! : "starting tsgo")")
            try? await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
            if mine != seq { return nil }
        }
    }

    /// the server's sentences are markdown-ish ("_Refused: …_")
    static func plainNote(_ m: String?) -> String {
        var s = (m ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if s.hasPrefix("Refused:") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// space k: the type at a position, into `pop`.
    public func hover(_ p: Position?, _ w: Where?) {
        guard let p, let w else { pop = .note("nothing to type here"); return }
        pop = .wait("asking tsgo…")
        let b = body(p, path: p.path, side: p.side, w)
        Task { @MainActor in
            guard let r = await asking("/lsp/hover", w, b, LSPHover.self) else { return }
            if r.ok, let c = r.contents, !c.isEmpty { pop = .hover(c) }
            else { pop = .note(r.ok ? "no type here" : Self.plainNote(r.message).isEmpty ? "types aren't available" : Self.plainNote(r.message)) }
        }
    }

    static let gotoWords: [LSPGoto: (asking: String, none: String, title: String)] = [
        .definition: ("finding the definition…", "no definition found", "definitions"),
        .typeDefinition: ("finding the type's definition…", "no type definition here", "type definitions"),
        .implementation: ("finding the implementations…", "no implementations found", "implementations"),
        .references: ("finding the references…", "no references found", "references"),
    ]

    /// g d / g y / g I / g r: one place goes there, several open the picker.
    public func goto(_ kind: LSPGoto, _ p: Position?, _ w: Where?) {
        guard let p, let w else { pop = .note("nothing to look up here"); return }
        let words = Self.gotoWords[kind]!
        pop = .wait(words.asking)
        let b = body(p, path: p.path, side: p.side, w)
        Task { @MainActor in
            let first = await asking(kind.route, w, b, LSPLocations.self)
            var r = first
            if let f = first, f.isWholeModule, let m = p.member {
                var mb = b
                mb.character = m
                if let mr = await asking(kind.route, w, mb, LSPLocations.self), mr.ok, !(mr.locations ?? []).isEmpty { r = mr }
            }
            guard let r else { return }
            let locs = r.ok ? (r.locations ?? []) : []
            if locs.isEmpty {
                pop = .note(r.ok ? words.none : Self.plainNote(r.message).isEmpty ? "types aren't available" : Self.plainNote(r.message))
                return
            }
            pop = nil
            let places = locs.map { Loc(repo: w.repo, sha: r.sha ?? "", path: $0.path, line: $0.line, end: $0.span?.count == 2 ? $0.span![1] : nil) }
            guard let app else { return }
            if places.count == 1 { return app.nav.go(places[0]) }
            app.nav.pick("\(words.title) · \(places.count)", places.map { PickItem(loc: $0, label: "\($0.path):\($0.line)") })
            fillTexts(places)
        }
    }

    /// space S: a file's symbols, in the picker.
    public func symbols(path: String?, side: String = "new", _ w: Where?) {
        guard let path, let w else { pop = .note("no file to list"); return }
        pop = .wait("reading the file's symbols…")
        let b = body(nil, path: path, side: side, w)
        Task { @MainActor in
            guard let r = await asking("/lsp/symbols", w, b, LSPSymbols.self) else { return }
            let syms = r.ok ? (r.symbols ?? []) : []
            if syms.isEmpty {
                pop = .note(r.ok ? "no symbols in this file" : Self.plainNote(r.message).isEmpty ? "types aren't available" : Self.plainNote(r.message))
                return
            }
            pop = nil
            app?.nav.pick("symbols · \(path)", syms.map {
                PickItem(loc: Loc(repo: w.repo, sha: r.sha ?? "", path: path, line: $0.line, end: $0.endLine),
                         label: String(repeating: "  ", count: $0.depth) + $0.name, text: "\($0.kind) :\($0.line)")
            })
        }
    }

    /// Each picker row's source line, as its file arrives (nav.ts pick).
    private func fillTexts(_ places: [Loc]) {
        guard let app else { return }
        let pg = ReviewPageState.of(app)
        for (i, l) in places.enumerated() {
            Task { @MainActor in
                let lines = await pg.linesOf(l)
                guard app.nav.picker != nil, app.nav.picker?.items.indices.contains(i) == true, app.nav.picker?.items[i].loc == l else { return }
                app.nav.setText(i, (l.line >= 1 && l.line <= lines.count ? lines[l.line - 1] : "").trimmingCharacters(in: .whitespaces))
            }
        }
    }

    public func dismiss() {
        seq += 1
        if pop != nil { pop = nil }
    }
}

/// Every /lsp answer can say "still loading".
protocol Settles {
    var ok: Bool { get }
    var state: String? { get }
    var message: String? { get }
}
extension LSPHover: Settles {}
extension LSPLocations: Settles {}
extension LSPSymbols: Settles {}

/// The `space k` popover (TypesPop.tsx): the type, or what tsgo is doing. Place it where the code
/// is; it draws nothing while there's nothing to say.
public struct TypesPopView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        if let p = CodeLookup.of(app).pop {
            Group {
                switch p {
                case .wait(let t): Text(t).foregroundStyle(theme.inkDim).italic()
                case .note(let t): Text(t).foregroundStyle(theme.inkDim)
                case .hover(let md): ScrollView { MarkdownView(md).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 260)
                }
            }
            .font(Theme.mono(12))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: 560, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(theme.vellumRaise)
            .overlay { Rectangle().stroke(theme.goldDeep, lineWidth: 1) }
        }
    }
}
