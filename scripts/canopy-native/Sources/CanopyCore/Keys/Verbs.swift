import Foundation

/// Keys belong to verbs; pages implement verbs (NAV.md "Keys by verb"). A command says "I am
/// <verb> in scope <s>" (`Command(verb: .mark, …)`) or names a key under its page's leader
/// (`Command(leader: LocalKey(",c"), …)`) — never a raw key. This table is the one place a key's
/// meaning is decided, so a key can't mean two things on two pages by construction.
///
/// keys-native.toml overrides a verb by its name (`mark = "v"`); every page implementing it follows.
public enum Verb: String, CaseIterable, Sendable, Comparable {
    // ── nav: owned by the nav core, the same on every page ──
    case next, previous, first, last
    case halfDown = "half-down", halfUp = "half-up"
    case left, right, out
    case nextWord = "next-word", previousWord = "previous-word"
    case cancel
    case nextSibling = "next-sibling", previousSibling = "previous-sibling"
    case parent, child, root, tip
    case nextFile = "next-file", previousFile = "previous-file"
    case nextHunk = "next-hunk", previousHunk = "previous-hunk"
    case nextThread = "next-thread", previousThread = "previous-thread"
    case face
    case labels, find, search, map
    case type, definition, typeDefinition = "type-definition", implementations, references, symbols
    case github, preview
    case goForests = "go-forests", goDashboard = "go-dashboard", goTodo = "go-todo"
    case goMachine = "go-machine", goWiki = "go-wiki", goTutor = "go-tutor"
    case alternate
    case slot1 = "slot-1", slot2 = "slot-2", slot3 = "slot-3", slot4 = "slot-4", slot5 = "slot-5"
    case slot6 = "slot-6", slot7 = "slot-7", slot8 = "slot-8", slot9 = "slot-9"
    case jumpBack = "jump-back", jumpForward = "jump-forward", saveJump = "save-jump"
    case branches, jumps, lastPicker = "last-picker"
    case paneLeft = "pane-left", paneDown = "pane-down", paneUp = "pane-up", paneRight = "pane-right", paneNext = "pane-next"
    case command, menu, keys, select
    case leader
    // ── shared: bare letters a page may implement, never invent ──
    case main
    case write
    case mark, unmark
    case putAway = "put-away"
    case apply, copy, push, sync, words, editor, comment, reply, extend, undo, rename
    case moveUp = "move-up", moveDown = "move-down"
    case nth1 = "nth-1", nth2 = "nth-2", nth3 = "nth-3", nth4 = "nth-4", nth5 = "nth-5"
    case nth6 = "nth-6", nth7 = "nth-7", nth8 = "nth-8", nth9 = "nth-9"
    // ── insert: the fixed set while typing ──
    case send, newline

    /// The Nth one shown (1…9): a tab, a choice.
    public static func nth(_ n: Int) -> Verb { Verb(rawValue: "nth-\(n)")! }
    /// The Nth focus forest (1…9).
    public static func slot(_ n: Int) -> Verb { Verb(rawValue: "slot-\(n)")! }

    public var spec: VerbSpec { Verbs.byVerb[self]! }
    /// Its name as which-key, the `?` sheet and keys.toml say it.
    public var name: String { rawValue }

    public static func < (a: Verb, b: Verb) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public enum VerbTier: String, Sendable {
    /// `f`, `g …`, `space …`, h/l, J/K, C-o/C-i, `:`, `/`, `?`, esc, the review moves: the nav core's
    case nav
    /// bare letters (and a few chords) pages implement on their own things
    case shared
    /// while typing: esc stops, ⌃↵ sends (↵ too in a one-line field), ⌥↵ is a newline — nothing else
    case insert
}

/// One row of the table: a verb's default keys and the meaning every implementer must honor.
public struct VerbSpec: Sendable {
    public let verb: Verb
    public let tier: VerbTier
    /// keys in modes that don't take text (normal, select, the sheet, a page's own layer)
    public let keys: [String]
    /// keys in text-entry modes (insert, the `:` line, the menu, the picker) — never printable
    public let entry: [String]
    /// the one-line meaning a page implementing it must honor
    public let meaning: String
    /// it moves somewhere far: the jumplist remembers where you were first (NAV.md §4.4)
    public let jump: Bool
    /// the focused field does it itself; no command may bind it
    public let native: Bool
}

public enum Verbs {
    private static func v(_ verb: Verb, _ tier: VerbTier, _ keys: [String], entry: [String] = [], jump: Bool = false,
                          native: Bool = false, _ meaning: String) -> VerbSpec {
        VerbSpec(verb: verb, tier: tier, keys: keys, entry: entry, meaning: meaning, jump: jump, native: native)
    }

    /// The table, in the order NAV.md lists it.
    public static let table: [VerbSpec] = [
        v(.next, .nav, ["j", "down"], entry: ["down", "C-n", "C-j", "tab"], "the next row, line or item"),
        v(.previous, .nav, ["k", "up"], entry: ["up", "C-p", "C-k"], "the previous row, line or item"),
        v(.first, .nav, ["g g"], jump: true, "the first row"),
        v(.last, .nav, ["G"], jump: true, "the last row"),
        v(.halfDown, .nav, ["C-d"], "down half a page"),
        v(.halfUp, .nav, ["C-u"], "up half a page"),
        v(.left, .nav, ["h", "left"], "left in what you see: the old side of a split diff, else the pane to the left"),
        v(.right, .nav, ["l", "right"], "right in what you see: the new side of a split diff, else the pane to the right"),
        v(.nextWord, .nav, ["w"], "the next name in the code, across lines — what g d and space k ask about"),
        v(.previousWord, .nav, ["b"], "the previous name in the code"),
        v(.out, .nav, ["-"], "up a level: line → file → branch → forest → forests (↵ goes in)"),
        v(.cancel, .nav, ["esc"], "close the innermost transient thing — never changes page"),
        v(.nextSibling, .nav, ["J"], jump: true, "the next branch in merge order, staying on this kind of page"),
        v(.previousSibling, .nav, ["K"], jump: true, "the previous branch in merge order, staying on this kind of page"),
        v(.parent, .nav, ["g k"], jump: true, "the branch's parent"),
        v(.child, .nav, ["g j"], jump: true, "the branch's child (labels at a fork)"),
        v(.root, .nav, ["g K"], jump: true, "the root of the branch's stack"),
        v(.tip, .nav, ["g J"], jump: true, "the tip of the branch's stack"),
        v(.nextFile, .nav, ["]"], jump: true, "the next file"),
        v(.previousFile, .nav, ["["], jump: true, "the previous file"),
        v(.nextHunk, .nav, ["}"], "the next hunk"),
        v(.previousHunk, .nav, ["{"], "the previous hunk"),
        v(.nextThread, .nav, ["n"], jump: true, "the next conversation (open ones first)"),
        v(.previousThread, .nav, ["N"], jump: true, "the previous conversation (open ones first)"),
        v(.face, .nav, ["tab"], "the page's other face (story ⇄ branches, the next tab, web ⇄ jobs)"),
        v(.labels, .nav, ["g w", "f"], "label everything on screen; type a label to go there"),
        v(.find, .nav, ["space f"], "find something on this page by name"),
        v(.search, .nav, ["/"], "search this page's text"),
        v(.map, .nav, ["space m"], "the map around what you're on"),
        v(.type, .nav, ["space k"], "the type under the cursor (hover)"),
        v(.definition, .nav, ["g d"], "go to the definition"),
        v(.typeDefinition, .nav, ["g y"], "go to the definition of its type"),
        v(.implementations, .nav, ["g I"], "go to its implementations"),
        v(.references, .nav, ["g r"], "list its references"),
        v(.symbols, .nav, ["space S"], "list the file's symbols"),
        v(.github, .nav, ["g h"], "open it on GitHub"),
        v(.preview, .nav, ["g p"], "preview it on a side port"),
        v(.goForests, .nav, ["g f"], "go to Forests"),
        v(.goDashboard, .nav, ["g s"], "go to the dashboard"),
        v(.goTodo, .nav, ["g o"], "go to the tracker"),
        v(.goMachine, .nav, ["g m"], "go to the machine"),
        v(.goWiki, .nav, ["g i"], "go to the wiki"),
        v(.goTutor, .nav, ["g t"], "go to the tutor"),
        v(.alternate, .nav, ["g a"], "the alternate place (where the last jump left from)"),
        v(.slot1, .nav, ["g 1"], "focus forest 1"), v(.slot2, .nav, ["g 2"], "focus forest 2"), v(.slot3, .nav, ["g 3"], "focus forest 3"),
        v(.slot4, .nav, ["g 4"], "focus forest 4"), v(.slot5, .nav, ["g 5"], "focus forest 5"), v(.slot6, .nav, ["g 6"], "focus forest 6"),
        v(.slot7, .nav, ["g 7"], "focus forest 7"), v(.slot8, .nav, ["g 8"], "focus forest 8"), v(.slot9, .nav, ["g 9"], "focus forest 9"),
        v(.jumpBack, .nav, ["C-o"], "jump back (the jumplist)"),
        v(.jumpForward, .nav, ["C-i"], "jump forward again"),
        v(.saveJump, .nav, ["C-s"], "save this spot to the jumplist"),
        v(.branches, .nav, ["space b"], "find a branch in any forest"),
        v(.jumps, .nav, ["space j"], "pick from the jumplist"),
        v(.lastPicker, .nav, ["space '"], "reopen the last picker"),
        v(.paneLeft, .nav, ["C-w h", "A-h"], "focus the pane to the left"),
        v(.paneDown, .nav, ["C-w j", "A-j"], "focus the pane below"),
        v(.paneUp, .nav, ["C-w k", "A-k"], "focus the pane above"),
        v(.paneRight, .nav, ["C-w l", "A-l"], "focus the pane to the right"),
        v(.paneNext, .nav, ["C-w w"], "focus the next pane"),
        v(.command, .nav, [":"], "the command line: run anything by name"),
        v(.menu, .nav, ["space ?"], "the command menu"),
        v(.keys, .nav, ["?"], "every key, here and now"),
        v(.select, .nav, ["v"], "select a range (again to stop)"),
        v(.leader, .nav, [","], "this page's own keys follow (which-key lists them)"),

        v(.main, .shared, ["ret"], "the thing's main action"),
        v(.write, .shared, ["i"], "start writing: the field for the thing under the cursor"),
        v(.mark, .shared, ["m"], "mark it (viewed, done, answered) and go on"),
        v(.unmark, .shared, ["M"], "take the mark off"),
        v(.putAway, .shared, ["X"], "put it away: archive, drop, delete, kill, forget, cut"),
        v(.apply, .shared, ["A"], "apply the suggested fix"),
        v(.copy, .shared, ["y"], "copy it"),
        v(.push, .shared, ["p"], "send it out: push to origin, send the draft"),
        v(.sync, .shared, ["s"], "sync it: fold or stash dirt, rebase onto its parent, shape the commits"),
        v(.words, .shared, ["e"], "the words: what's written about it, in full"),
        v(.editor, .shared, ["o"], "open it in Helix"),
        v(.rename, .shared, ["space r"], "rename the name under the cursor across the program: a commit you see first"),
        v(.comment, .shared, ["c"], "comment on it"),
        v(.reply, .shared, ["r"], "reply to it"),
        v(.extend, .shared, ["x"], "extend the selection a line"),
        v(.undo, .shared, ["u"], "undo the last change"),
        v(.moveUp, .shared, ["C-k"], "move it up its hand-ordered list"),
        v(.moveDown, .shared, ["C-j"], "move it down its hand-ordered list"),
        v(.nth1, .shared, ["1"], "the 1st one shown: a tab, a choice"), v(.nth2, .shared, ["2"], "the 2nd one shown"),
        v(.nth3, .shared, ["3"], "the 3rd one shown"), v(.nth4, .shared, ["4"], "the 4th one shown"), v(.nth5, .shared, ["5"], "the 5th one shown"),
        v(.nth6, .shared, ["6"], "the 6th one shown"), v(.nth7, .shared, ["7"], "the 7th one shown"), v(.nth8, .shared, ["8"], "the 8th one shown"),
        v(.nth9, .shared, ["9"], "the 9th one shown"),

        v(.send, .insert, ["C-ret"], entry: ["ret", "C-ret"], "send or finish what's typed: ⌃↵ always; ↵ only in a one-line field"),
        v(.newline, .insert, [], entry: ["A-ret"], native: true, "a new line in what's typed (↵ too, in a many-line box)"),
    ]

    public static let byVerb: [Verb: VerbSpec] = Dictionary(table.map { ($0.verb, $0) }, uniquingKeysWith: { a, _ in a })
}

/// A key under the page's leader (`,`): actions with no general verb. `LocalKey(",c")` binds
/// `, c` — a page's own namespace, which can't collide with another page's or a future global.
/// Write the keys after the leader as typed: `",c"`, `",d p"` (a chord), `",C"`.
public struct LocalKey: Hashable, Sendable, CustomStringConvertible {
    /// what follows the leader, space-separated ("c", "d p")
    public let rest: String

    public init(_ s: String) {
        var t = Substring(s)
        if t.hasPrefix(",") { t = t.dropFirst() }
        rest = t.trimmingCharacters(in: .whitespaces)
    }

    public var description: String { ", \(rest)" }
    /// The full key under `leader` ("," unless keys.toml moved it).
    public func key(leader: String) -> String { "\(leader) \(rest)" }
}

/// The mode classes a verb's keys come in.
public extension KeyMode {
    /// true where keys go to a text field unless bound (insert, `:`, the menu, the picker)
    var takesText: Bool { KeyMode.textEntry.contains(self) }
}

/// The live key table: the verbs' keys after keys.toml.
public struct VerbKeys: Equatable, Sendable {
    public var keys: [Verb: [String]]
    public var entry: [Verb: [String]]
    public var leader: String { keys[.leader]?.first ?? "," }

    public static let defaults = VerbKeys(keys: Verbs.byVerb.mapValues(\.keys), entry: Verbs.byVerb.mapValues(\.entry))

    /// The keys `verb` binds in `mode`.
    public func of(_ verb: Verb, in mode: KeyMode) -> [String] { (mode.takesText ? entry[verb] : keys[verb]) ?? [] }
}
