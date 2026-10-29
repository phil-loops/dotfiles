import CanopyCore
import Foundation

// STAND-IN for area B's LSP helper (review/types.ts), scoped to what the tutor's code pane needs:
// space k (hover), g d / g y / g I / g r (definition, type definition, implementations,
// references) and space S (symbols), asked at the pinned file's commit through `Transport.ask`, with
// one place opened through `app.nav.go` and several put in the picker. When Review publishes its
// helper, the tutor's commands call it instead and this file goes.
//
// Mouseless: v2 asks at the word under the mouse; here the position is the code pane's cursor
// line — its first name that isn't a keyword (v2's own fallback for the diff's cursor line).

/// Code outside a review page's diff: the repo it's in ("" for the server's own) and its commit.
struct CodeSource: Equatable {
    var repo: String
    var sha: String
}

/// Where a lookup asks: a file, a 1-based line, a 0-based UTF-16 character, and where `.member`
/// starts when the name is followed by one (a namespace's member is what `g d` wants).
struct CodePos: Equatable {
    var path: String
    var line: Int
    var character: Int
    var member: Int?
}

@MainActor
enum TutorLookup {
    /// keywords the cursor line's first name skips
    static let skip: Set<String> = Set("import export from const let var function return type interface async await new if else for while of in as default class extends implements".split(separator: " ").map(String.init))

    /// The first name worth a type on a line, and where its `.member` starts.
    static func firstName(_ text: String) -> (character: Int, member: Int?)? {
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: "[A-Za-z_$][\\w$]*")
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !skip.contains(ns.substring(with: m.range)) {
            let end = m.range.location + m.range.length
            return (m.range.location, memberAt(ns, end))
        }
        return nil
    }

    private static func isWord(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
    }

    private static func memberAt(_ ns: NSString, _ end: Int) -> Int? {
        end + 1 < ns.length && ns.character(at: end) == 46 && isWord(ns.character(at: end + 1)) ? end + 1 : nil
    }

    /// the server's sentences are markdown-ish ("_Refused: …_")
    static func plainNote(_ m: String?) -> String {
        var s = m ?? ""
        while s.hasPrefix("_") { s.removeFirst() }
        while s.hasSuffix("_") { s.removeLast() }
        if s.hasPrefix("Refused:") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    private static var seq = 0

    /// Ask until the answer settles: a `loading` answer is asked again every 500ms for up to 90s.
    /// nil when a newer lookup took over.
    static func asking<T: Decodable & LSPAnswer>(_ t: TutorState, _ route: String, _ src: CodeSource, _ body: LSPAsk) async -> T? {
        seq += 1
        let mine = seq
        let t0 = Date()
        while true {
            let r = await t.transport.ask(t.transport.atRepo(src.repo, route), body, as: T.self)
            if mine != seq { return nil }
            guard let r, !r.ok, r.state == "loading", Date().timeIntervalSince(t0) < 90 else { return r }
            t.pop = .wait("types are loading — \((r.message ?? "").isEmpty ? "starting tsgo" : r.message!)")
            try? await Task.sleep(for: .milliseconds(500))
            if mine != seq { return nil }
        }
    }

    static func dismiss(_ t: TutorState) {
        seq += 1
        t.pop = nil
    }

    static func hover(_ t: TutorState, _ src: CodeSource, _ p: CodePos?) {
        guard let p else { t.pop = .note("nothing to type here"); return }
        t.pop = .wait("asking tsgo…")
        Task { @MainActor in
            guard let r: LSPHover = await asking(t, "/lsp/hover", src, LSPAsk(path: p.path, line: p.line, character: p.character, side: "new", sha: src.sha)) else { return }
            if r.ok, let md = r.contents, !md.isEmpty { t.pop = .hover(md) }
            else { t.pop = .note(r.ok ? "no type here" : plainNote(r.message).isEmpty ? "types aren't available" : plainNote(r.message)) }
        }
    }

    static func say(_ kind: LSPGoto) -> (asking: String, none: String, title: String) {
        switch kind {
        case .definition: ("finding the definition…", "no definition found", "definitions")
        case .typeDefinition: ("finding the type's definition…", "no type definition here", "type definitions")
        case .implementation: ("finding the implementations…", "no implementations found", "implementations")
        case .references: ("finding the references…", "no references found", "references")
        }
    }

    /// g d, g y, g I, g r: one place goes there, several open the picker.
    static func goto(_ t: TutorState, _ kind: LSPGoto, _ src: CodeSource, _ p: CodePos?) {
        guard let p, let app = t.app else { t.pop = .note("nothing to look up here"); return }
        let words = say(kind)
        t.pop = .wait(words.asking)
        Task { @MainActor in
            let at = LSPAsk(path: p.path, line: p.line, character: p.character, side: "new", sha: src.sha)
            guard let first: LSPLocations = await asking(t, kind.route, src, at) else { return }
            var r = first
            if first.isWholeModule, let m = p.member {
                var again = at
                again.character = m
                if let member: LSPLocations = await asking(t, kind.route, src, again), member.ok, !(member.locations ?? []).isEmpty { r = member }
            }
            let locs = r.ok ? (r.locations ?? []) : []
            if locs.isEmpty {
                t.pop = .note(r.ok ? words.none : plainNote(r.message).isEmpty ? "types aren't available" : plainNote(r.message))
                return
            }
            t.pop = nil
            let places = locs.map { Loc(repo: src.repo, sha: r.sha ?? "", path: $0.path, line: $0.line, end: ($0.span?.count ?? 0) > 1 ? $0.span![1] : nil) }
            if places.count == 1 { return app.nav.go(places[0]) }
            app.nav.pick("\(words.title) · \(places.count)", places.map { PickItem(loc: $0, label: "\($0.path):\($0.line)") })
        }
    }

    /// space S: the pinned file's symbols, in the picker.
    static func symbols(_ t: TutorState, _ src: CodeSource, path: String) {
        guard let app = t.app else { return }
        t.pop = .wait("reading the file's symbols…")
        Task { @MainActor in
            guard let r: LSPSymbols = await asking(t, "/lsp/symbols", src, LSPAsk(path: path, side: "new", sha: src.sha)) else { return }
            let syms = r.ok ? (r.symbols ?? []) : []
            if syms.isEmpty {
                t.pop = .note(r.ok ? "no symbols in this file" : plainNote(r.message).isEmpty ? "types aren't available" : plainNote(r.message))
                return
            }
            t.pop = nil
            app.nav.pick("symbols · \(path)", syms.map {
                PickItem(loc: Loc(repo: src.repo, sha: r.sha ?? "", path: path, line: $0.line, end: $0.endLine),
                         label: String(repeating: "  ", count: $0.depth) + $0.name, text: "\($0.kind) :\($0.line)")
            })
        }
    }
}

/// The shared shape of every /lsp/* answer.
protocol LSPAnswer {
    var ok: Bool { get }
    var state: String? { get }
    var message: String? { get }
}

extension LSPHover: LSPAnswer {}
extension LSPLocations: LSPAnswer {}
extension LSPSymbols: LSPAnswer {}
