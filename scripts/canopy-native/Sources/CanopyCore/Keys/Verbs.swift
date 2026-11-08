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
    case halfDown = "half-down", halfUp = "half-up", pageDown = "page-down", pageUp = "page-up"
    case windowTop = "window-top", windowCenter = "window-center", windowBottom = "window-bottom"
    case left, right, out
    case nextWord = "next-word", previousWord = "previous-word"
    case lineStart = "line-start", lineEnd = "line-end", firstNonBlank = "first-non-blank"
    case findChar = "find-char", tillChar = "till-char", findCharBack = "find-char-back", tillCharBack = "till-char-back"
    case cancel
    case nextSibling = "next-sibling", previousSibling = "previous-sibling"
    case root, tip
    case nextFile = "next-file", previousFile = "previous-file"
    case nextHunk = "next-hunk", previousHunk = "previous-hunk"
    case nextUnviewed = "next-unviewed", previousUnviewed = "previous-unviewed"
    case nextThread = "next-thread", previousThread = "previous-thread"
    case nextConversation = "next-conversation", previousConversation = "previous-conversation"
    case nextTest = "next-test", previousTest = "previous-test", nextGitHunk = "next-git-hunk", previousGitHunk = "previous-git-hunk"
    case lastFinding = "last-finding", firstFinding = "first-finding"
    case nextLongWord = "next-long-word", previousLongWord = "previous-long-word", longWordEnd = "long-word-end"
    case scrollDown = "scroll-down", scrollUp = "scroll-up"
    case face
    case labels, find, search, map, conversation
    case nextComment = "next-comment", previousComment = "previous-comment", wordEnd = "word-end", searchBack = "search-back"
    case match, changedFiles = "changed-files"
    case nextFunction = "next-function", previousFunction = "previous-function", nextType = "next-type", previousType = "previous-type"
    case nextFinding = "next-finding", previousFinding = "previous-finding", firstChange = "first-change", lastChange = "last-change"
    case nextCommit = "next-commit", previousCommit = "previous-commit"
    case repeatMotion = "repeat-motion", viewCenter = "view-center", viewTop = "view-top", viewBottom = "view-bottom"
    case searchWord = "search-word"
    case type, definition, typeDefinition = "type-definition", implementations, references, symbols
    case github, preview
    case githubMain = "github-main", githubBranch = "github-branch"
    case goForests = "go-forests", goDashboard = "go-dashboard", goTodo = "go-todo"
    case goMachine = "go-machine", goWiki = "go-wiki", goTutor = "go-tutor"
    case alternate
    case slot1 = "slot-1", slot2 = "slot-2", slot3 = "slot-3", slot4 = "slot-4", slot5 = "slot-5"
    case slot6 = "slot-6", slot7 = "slot-7", slot8 = "slot-8", slot9 = "slot-9"
    case jumpBack = "jump-back", jumpForward = "jump-forward", saveJump = "save-jump"
    case branches, jumps, flags, grep, lastPicker = "last-picker"
    case paneLeft = "pane-left", paneDown = "pane-down", paneUp = "pane-up", paneRight = "pane-right", paneNext = "pane-next"
    case splitRight = "split-right", splitBelow = "split-below", closeWindow = "close-window", onlyWindow = "only-window"
    case pickRight = "pick-right", pickBelow = "pick-below"
    case command, menu, keys, select
    case leader
    // ── shared: bare letters a page may implement, never invent ──
    case main
    case write
    case mark, unmark
    case putAway = "put-away"
    case apply, copy, push, sync, words, editor, comment, reply, extend, undo, rename
    case wordsTitle = "words-title", wordsWhy = "words-why", wordsDescription = "words-description", wordsCommit = "words-commit"
    case copyPlace = "copy-place"
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

/// Which-key's sections: what can follow a prefix reads by meaning, as Helix's infobox keeps its
/// keymap's written order, not by letter. The sections show in this order; letters sort inside one.
public enum KeySection: String, CaseIterable, Sendable {
    case places, pickers, code, review, stack, words
    case screen = "on screen", view, windows, outside, choose, help

    /// The section a verb reads in. No default: a new verb has to say where it goes.
    public static func of(_ verb: Verb) -> KeySection? {
        switch verb {
        case .conversation, .changedFiles, .map, .alternate,
             .goForests, .goDashboard, .goTodo, .goMachine, .goWiki, .goTutor,
             .slot1, .slot2, .slot3, .slot4, .slot5, .slot6, .slot7, .slot8, .slot9:
            return .places
        case .find, .branches, .jumps, .flags, .grep, .lastPicker:
            return .pickers
        case .type, .definition, .typeDefinition, .implementations, .references, .symbols, .rename, .match,
             .nextFunction, .previousFunction, .nextType, .previousType, .nextTest, .previousTest:
            return .code
        case .nextFile, .previousFile, .nextHunk, .previousHunk, .nextUnviewed, .previousUnviewed,
             .nextThread, .previousThread, .nextConversation, .previousConversation, .nextComment, .previousComment,
             .nextFinding, .previousFinding, .firstFinding, .lastFinding, .nextGitHunk, .previousGitHunk,
             .firstChange, .lastChange, .nextCommit, .previousCommit:
            return .review
        case .root, .tip, .nextSibling, .previousSibling, .out:
            return .stack
        case .wordsTitle, .wordsWhy, .wordsDescription, .wordsCommit:
            return .words
        case .next, .previous, .first, .last, .windowTop, .windowCenter, .windowBottom,
             .lineStart, .lineEnd, .firstNonBlank, .labels:
            return .screen
        case .viewCenter, .viewTop, .viewBottom, .scrollDown, .scrollUp:
            return .view
        case .paneLeft, .paneDown, .paneUp, .paneRight, .paneNext, .splitRight, .splitBelow,
             .closeWindow, .onlyWindow, .pickRight, .pickBelow:
            return .windows
        case .github, .githubMain, .githubBranch, .preview:
            return .outside
        case .nth1, .nth2, .nth3, .nth4, .nth5, .nth6, .nth7, .nth8, .nth9:
            return .choose
        case .keys, .menu, .command:
            return .help
        // bare keys: no prefix's box shows them
        case .halfDown, .halfUp, .pageDown, .pageUp, .left, .right, .nextWord, .previousWord,
             .findChar, .tillChar, .findCharBack, .tillCharBack, .cancel, .nextLongWord, .previousLongWord, .longWordEnd,
             .face, .search, .wordEnd, .searchBack, .repeatMotion, .searchWord, .jumpBack, .jumpForward, .saveJump,
             .select, .leader, .main, .write, .mark, .unmark, .putAway, .apply, .copy, .push, .sync, .words, .editor,
             .comment, .reply, .extend, .undo, .copyPlace, .moveUp, .moveDown, .send, .newline:
            return nil
        }
    }
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
        v(.next, .nav, ["j", "down", "g j"], entry: ["down", "C-n", "C-j", "tab"], "the next row, line or item"),
        v(.previous, .nav, ["k", "up", "g k"], entry: ["up", "C-p", "C-k"], "the previous row, line or item"),
        v(.first, .nav, ["g g"], jump: true, "the first row"),
        v(.last, .nav, ["G", "g e"], jump: true, "the last row"),
        v(.halfDown, .nav, ["C-d"], "down half a page"),
        v(.halfUp, .nav, ["C-u"], "up half a page"),
        v(.pageDown, .nav, ["C-f"], "down a page"),
        v(.pageUp, .nav, ["C-b"], "up a page"),
        v(.windowTop, .nav, ["g t"], "the top of what's on screen"),
        v(.windowCenter, .nav, ["g c"], "the middle of what's on screen"),
        v(.windowBottom, .nav, ["g b"], "the bottom of what's on screen"),
        v(.left, .nav, ["h", "left"], "a character left in code (onto the old half at a removed line's start), else the pane to the left"),
        v(.right, .nav, ["l", "right"], "a character right in code (from the old half's end onto the new), else the pane to the right"),
        v(.nextWord, .nav, ["w"], "the next name in the code, across lines — what g d and space k ask about"),
        v(.previousWord, .nav, ["b"], "the previous name in the code"),
        v(.wordEnd, .nav, ["e"], "the end of the name (Helix e)"),
        v(.nextLongWord, .nav, ["W"], "the next WORD (Helix W)"),
        v(.previousLongWord, .nav, ["B"], "the previous WORD (Helix B)"),
        v(.longWordEnd, .nav, ["E"], "the end of the WORD (Helix E)"),
        v(.lineStart, .nav, ["g h", "home"], "the start of the line in code"),
        v(.lineEnd, .nav, ["g l", "end"], "the end of the line in code"),
        v(.firstNonBlank, .nav, ["g s"], "the line's first character that isn't a space, in code"),
        v(.findChar, .nav, ["f"], "on to the next of a character you type, along the line in code"),
        v(.tillChar, .nav, ["t"], "up to just before the next of a character you type, in code"),
        v(.findCharBack, .nav, ["F"], "back to the previous of a character you type, in code"),
        v(.tillCharBack, .nav, ["T"], "back to just after the previous of a character you type, in code"),
        v(.out, .nav, ["-"], "up a level: line → file → branch → forest → forests (↵ goes in)"),
        v(.cancel, .nav, ["esc"], "close the innermost transient thing — never changes page"),
        v(.nextSibling, .nav, ["J", "] b"], jump: true, "the next branch in merge order (the forest's numbered list), staying on this kind of page"),
        v(.previousSibling, .nav, ["K", "[ b"], jump: true, "the previous branch in merge order, staying on this kind of page"),
        v(.root, .nav, ["g K"], jump: true, "the root of the branch's stack"),
        v(.tip, .nav, ["g J"], jump: true, "the tip of the branch's stack"),
        v(.nextFile, .nav, ["g n", "}"], jump: true, "the next file, at its first change (Helix's next buffer)"),
        v(.previousFile, .nav, ["g p", "{"], jump: true, "the previous file, at its first change (Helix's previous buffer)"),
        v(.nextHunk, .nav, ["] g"], "the next change, into the next file at the end of one (Helix ]g)"),
        v(.previousHunk, .nav, ["[ g"], "the previous change (Helix [g)"),
        v(.nextUnviewed, .nav, ["] u"], "the next change not yet marked viewed, across files, wrapping to the top"),
        v(.previousUnviewed, .nav, ["[ u"], "the previous change not yet marked viewed, wrapping to the bottom"),
        v(.nextThread, .nav, ["n"], jump: true, "the next search match (Helix n)"),
        v(.previousThread, .nav, ["N"], jump: true, "the previous search match (Helix N)"),
        v(.nextConversation, .nav, ["] r"], jump: true, "the next conversation, open ones first"),
        v(.previousConversation, .nav, ["[ r"], jump: true, "the previous conversation"),
        v(.nextComment, .nav, ["] c"], "the next comment in the diff's code (Helix ]c)"),
        v(.previousComment, .nav, ["[ c"], "the previous comment (Helix [c)"),
        v(.nextTest, .nav, ["] T"], jump: true, "the next test file (Helix ]T)"),
        v(.previousTest, .nav, ["[ T"], jump: true, "the previous test file (Helix [T)"),
        v(.nextGitHunk, .nav, ["] p"], "the next git hunk (Helix ]p)"),
        v(.previousGitHunk, .nav, ["[ p"], "the previous git hunk (Helix [p)"),
        v(.nextFunction, .nav, ["] f"], "the next function in this file's diff (Helix ]f)"),
        v(.previousFunction, .nav, ["[ f"], "the previous function (Helix [f)"),
        v(.nextType, .nav, ["] t"], "the next class, interface or enum in this file's diff (Helix ]t)"),
        v(.previousType, .nav, ["[ t"], "the previous one (Helix [t)"),
        v(.nextFinding, .nav, ["] d"], "the next finding push-ready's review left on this branch (Helix ]d: the next diagnostic)"),
        v(.previousFinding, .nav, ["[ d"], "the previous finding (Helix [d)"),
        v(.lastFinding, .nav, ["] D"], "the last finding (Helix ]D)"),
        v(.firstFinding, .nav, ["[ D"], "the first finding (Helix [D)"),
        v(.nextCommit, .nav, ["] h"], "the diff covers the next commit alone (from the whole branch: its first)"),
        v(.previousCommit, .nav, ["[ h"], "the diff covers the previous commit alone (from the whole branch: its last)"),
        v(.firstChange, .nav, ["[ G"], jump: true, "the branch's first change (Helix [G)"),
        v(.lastChange, .nav, ["] G"], jump: true, "the branch's last change (Helix ]G)"),
        v(.repeatMotion, .nav, ["A-."], "repeat the last f / t / F / T (Helix alt-.)"),
        v(.viewCenter, .nav, ["z z", "z c"], "scroll the code so the cursor's line is in the middle (Helix zz)"),
        v(.viewTop, .nav, ["z t"], "scroll so the cursor's line is at the top (Helix zt)"),
        v(.viewBottom, .nav, ["z b"], "scroll so the cursor's line is at the bottom (Helix zb)"),
        v(.scrollDown, .nav, ["z j"], "scroll down a line (Helix zj)"),
        v(.scrollUp, .nav, ["z k"], "scroll up a line (Helix zk)"),
        v(.match, .nav, ["m m"], "the matching thing: the other half of this edit — what replaced the line, or what it replaced (Helix mm)"),
        v(.face, .nav, ["tab"], "the page's other face (story ⇄ branches, the next tab, web ⇄ jobs)"),
        v(.labels, .nav, ["g w"], "label everything on screen; type a label to go there"),
        v(.find, .nav, ["space f"], "find something on this page by name"),
        v(.changedFiles, .nav, ["space g", "space b"], "the files this branch changes, to pick one (Helix's changed-file picker)"),
        v(.search, .nav, ["/"], "search this page's text"),
        v(.grep, .nav, ["space /"], "search the branch's changes for text, every file (Helix's global search)"),
        v(.searchBack, .nav, ["?"], "search this page's text backwards (Helix ?)"),
        v(.searchWord, .nav, ["*"], "search for the name under the cursor (n / N then step through its uses)"),
        v(.map, .nav, ["space m"], "the map around what you're on"),
        v(.conversation, .nav, ["space c"], "the conversation, in place of what you're reading; esc brings it back"),
        v(.type, .nav, ["space k"], "the type under the cursor (hover)"),
        v(.definition, .nav, ["g d"], "go to the definition"),
        v(.typeDefinition, .nav, ["g y"], "go to the definition of its type"),
        v(.implementations, .nav, ["g i"], "go to its implementations"),
        v(.references, .nav, ["g r"], "list its references"),
        v(.symbols, .nav, ["space s"], "list the file's symbols"),
        v(.github, .nav, ["space o g"], "open it on GitHub"),
        v(.githubMain, .nav, ["space o m"], "open these lines on GitHub, on main"),
        v(.githubBranch, .nav, ["space o b"], "open these lines on GitHub, at the branch (the open file: at its commit)"),
        v(.preview, .nav, ["space o p"], "preview it on a side port"),
        v(.goForests, .nav, ["g F"], "go to Forests"),
        v(.goDashboard, .nav, ["g S"], "go to the dashboard"),
        v(.goTodo, .nav, ["g O"], "go to the tracker"),
        v(.goMachine, .nav, ["g M"], "go to the machine"),
        v(.goWiki, .nav, ["g W"], "go to the wiki"),
        v(.goTutor, .nav, ["g T"], "go to the tutor"),
        v(.alternate, .nav, ["g a"], "the alternate place (where the last jump left from)"),
        v(.slot1, .nav, ["g 1"], "focus forest 1"), v(.slot2, .nav, ["g 2"], "focus forest 2"), v(.slot3, .nav, ["g 3"], "focus forest 3"),
        v(.slot4, .nav, ["g 4"], "focus forest 4"), v(.slot5, .nav, ["g 5"], "focus forest 5"), v(.slot6, .nav, ["g 6"], "focus forest 6"),
        v(.slot7, .nav, ["g 7"], "focus forest 7"), v(.slot8, .nav, ["g 8"], "focus forest 8"), v(.slot9, .nav, ["g 9"], "focus forest 9"),
        v(.jumpBack, .nav, ["C-o"], "jump back (the jumplist)"),
        v(.jumpForward, .nav, ["C-i"], "jump forward again"),
        v(.saveJump, .nav, ["C-s"], "save this spot to the jumplist"),
        v(.branches, .nav, ["space B"], "find a branch in any forest"),
        v(.jumps, .nav, ["space j"], "pick from the jumplist"),
        v(.flags, .nav, ["space !"], "pick a change you flagged (, !), on any branch"),
        v(.lastPicker, .nav, ["space '"], "reopen the last picker"),
        v(.paneLeft, .nav, ["C-h", "C-w h", "space w h", "A-h"], "focus the pane to the left"),
        v(.paneDown, .nav, ["C-w j", "space w j", "A-j"], "focus the pane below"),
        v(.paneUp, .nav, ["C-w k", "space w k", "A-k"], "focus the pane above"),
        v(.paneRight, .nav, ["C-l", "C-w l", "space w l", "A-l"], "focus the pane to the right"),
        v(.paneNext, .nav, ["C-w w", "space w w"], "focus the next pane"),
        v(.splitRight, .nav, ["C-w v", "C-w C-v", "space w v"], "a copy of this window beside it"),
        v(.splitBelow, .nav, ["C-w s", "C-w C-s", "space w s"], "a copy of this window under it"),
        v(.closeWindow, .nav, ["C-w q", "C-w C-q", "space w q"], "close this window"),
        v(.onlyWindow, .nav, ["C-w o", "C-w C-o", "space w o"], "close the other windows"),
        v(.pickRight, .nav, [], entry: ["C-v"], "in a picker: open the pick in a window beside this one"),
        v(.pickBelow, .nav, [], entry: ["C-s"], "in a picker: open the pick in a window under this one"),
        v(.command, .nav, [":"], "the command line: run anything by name"),
        v(.menu, .nav, ["space ?"], "the command menu"),
        v(.keys, .nav, ["g ?"], "every key, here and now"),
        v(.select, .nav, ["v"], "select a range (again to stop)"),
        v(.leader, .nav, [","], "this page's own keys follow (which-key lists them)"),

        v(.main, .shared, ["ret"], "the thing's main action"),
        v(.write, .shared, ["i"], "start writing: the field for the thing under the cursor"),
        v(.mark, .shared, [], "mark it (viewed, done, answered) and go on"),
        v(.unmark, .shared, [], "take the mark off"),
        v(.putAway, .shared, ["X"], "put it away: archive, drop, delete, kill, forget, cut"),
        v(.apply, .shared, ["A"], "apply the suggested fix"),
        v(.copy, .shared, ["y"], "copy it"),
        v(.copyPlace, .nav, ["Y"], "copy where you are, in words: the page, the file and line, then the link"),
        v(.push, .shared, ["p"], "send it out: push to origin, send the draft"),
        v(.sync, .shared, ["s"], "sync it: fold or stash dirt, rebase onto its parent, shape the commits"),
        v(.words, .shared, ["d"], "the words: what's written about it, in full"),
        v(.wordsTitle, .nav, ["D t"], "the branch's title — what lands on main — open to write (:title <text> writes it)"),
        v(.wordsWhy, .nav, ["D w"], "the branch's why, above the PR template, open to write (:why <text>)"),
        v(.wordsDescription, .nav, ["D d"], "the branch's one line, its description, open to write (:desc <text>)"),
        v(.wordsCommit, .nav, ["D c"], "pick one of the branch's commits and reword it (:reword <sha> <subject>)"),
        v(.editor, .shared, ["o"], "open it in Helix"),
        v(.rename, .shared, ["space r"], "rename the name under the cursor across the program: a commit you see first"),
        v(.comment, .shared, ["c"], "comment on it"),
        v(.reply, .shared, ["r"], "reply to it"),
        v(.extend, .shared, ["x"], "extend the selection a line"),
        v(.undo, .shared, ["u"], "undo the last change"),
        v(.moveUp, .shared, ["C-k"], "move it up its hand-ordered list"),
        v(.moveDown, .shared, ["C-j"], "move it down its hand-ordered list"),
        v(.nth1, .shared, ["space 1"], "the 1st choice shown (a picker, a prompt); a tab is reached by its name, not its slot"), v(.nth2, .shared, ["space 2"], "the 2nd one shown"),
        v(.nth3, .shared, ["space 3"], "the 3rd one shown"), v(.nth4, .shared, ["space 4"], "the 4th one shown"), v(.nth5, .shared, ["space 5"], "the 5th one shown"),
        v(.nth6, .shared, ["space 6"], "the 6th one shown"), v(.nth7, .shared, ["space 7"], "the 7th one shown"), v(.nth8, .shared, ["space 8"], "the 8th one shown"),
        v(.nth9, .shared, ["space 9"], "the 9th one shown"),

        v(.send, .insert, ["C-ret"], entry: ["ret", "C-ret"], "send or finish what's typed: ⌃↵ always; ↵ only in a one-line field"),
        v(.newline, .insert, [], entry: ["A-ret"], native: true, "a new line in what's typed (↵ too, in a many-line box)"),
    ]

    /// Keys that moved for Helix (2026-11-03): pressing the old one says where the verb went, and
    /// which-key under the old prefix shows it.
    public static let moved: [(old: String, now: String, verb: Verb)] = [
        ("] ]", "] g", .nextHunk), ("[ [", "[ g", .previousHunk),
        ("m", ", m", .mark), ("M", ", M", .unmark),
        ("g f", "g F", .goForests), ("g o", "g O", .goTodo), ("g m", "g M", .goMachine),
        ("g I", "g i", .implementations), ("g P", "space o p", .preview), ("space S", "space s", .symbols),
    ]

    /// The motions a count repeats (Helix's `3j`); before anything else a count is dropped.
    public static let countable: Set<Verb> = [
        .next, .previous, .halfDown, .halfUp, .pageDown, .pageUp, .left, .right,
        .nextWord, .previousWord, .nextLongWord, .previousLongWord, .longWordEnd,
        .nextSibling, .previousSibling, .nextFile, .previousFile, .nextHunk, .previousHunk, .nextUnviewed, .previousUnviewed,
        .nextThread, .previousThread, .nextConversation, .previousConversation, .nextFunction, .previousFunction,
        .nextType, .previousType, .nextFinding, .previousFinding, .nextTest, .previousTest, .nextGitHunk, .previousGitHunk,
        .repeatMotion, .scrollDown, .scrollUp, .extend, .nextCommit, .previousCommit, .jumpBack, .jumpForward, .nextComment, .previousComment, .wordEnd,
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
