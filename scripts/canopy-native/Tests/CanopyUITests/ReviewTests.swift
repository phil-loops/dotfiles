import AppKit
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

// review.test.ts, review-context.test.ts and review-viewed.test.ts as Swift, plus the review page
// driven by key over the real registry. Every request is answered by ShipStub; nothing reaches a server.

// ── diff.ts / highlight.ts (review.test.ts) ──

@Suite struct DiffTests {
    static let patch = """
    diff --git a/x.ts b/x.ts
    index 1..2 100644
    --- a/x.ts
    +++ b/x.ts
    @@ -1,4 +1,5 @@
     keep
    -old one
    -old two
    +new one
    +new two
    +new three
     tail

    """

    @Test func helixsStatusLineSaysWhereItsCursorIs() {
        #expect(helixStatus(" NOR   pages/campaigns/index.tsx                1 sel  1:1 ")! == ("pages/campaigns/index.tsx", 1))
        #expect(helixStatus(" INS   models/team-membership.ts [+]   2 sels  48:12")! == ("models/team-membership.ts", 48))
        #expect(helixStatus("  45   import { sortCampaigns } from \"../../lib/utils/cardSorting\";") == nil)
        #expect(helixStatus("") == nil)
    }

    @Test func changedWordsAreTheOnesThatDiffer() {
        let (l, r) = changedWords("for (let i = 0; i < 101; i++) {", "for (let i = 0; i < 2 * SIZE - 3; i++) {")
        let ns = "for (let i = 0; i < 2 * SIZE - 3; i++) {" as NSString
        #expect(l.map { ("for (let i = 0; i < 101; i++) {" as NSString).substring(with: $0) } == ["101"])
        #expect(r.map { ns.substring(with: $0) } == ["2", "*", "SIZE", "-", "3"])
        #expect(changedWords("alpha beta", "gamma delta") == ([], []), "nothing shared: the band says it, no word lights")
    }

    @Test func aPatchParsesIntoNumberedLines() {
        let f = parsePatch("x.ts", Self.patch)
        #expect(f.add == 3 && f.del == 2)
        let got = f.hunks[0].lines.map { "\($0.kind.rawValue) \($0.old.map(String.init) ?? "-") \($0.new.map(String.init) ?? "-")" }
        #expect(got == ["ctx 1 1", "del 2 -", "del 3 -", "add - 2", "add - 3", "add - 4", "ctx 4 5"])
    }

    @Test func aNewFileIsAddedAndKeepsItsBlankLines() {
        let f = parsePatch("n.ts", "new file mode 100644\n--- /dev/null\n+++ b/n.ts\n@@ -0,0 +1,3 @@\n+a\n+\n+b\n")
        #expect(f.status == .added)
        #expect(f.hunks[0].lines.map(\.new) == [1, 2, 3])
    }

    @Test func crlfLinesKeepTheirReturnLikeTheWebApp() {
        let f = parsePatch("w.ts", "@@ -1,1 +1,1 @@\r\n-a\r\n+b\r\n")
        #expect(f.hunks.count == 0 || f.hunks[0].lines.map(\.text) == ["a\r", "b\r"])
        let g = parsePatch("w.ts", "@@ -1,1 +1,1 @@\n-a\r\n+b\r\n")
        #expect(g.hunks[0].lines.map(\.text) == ["a\r", "b\r"])
    }

    @Test func splitPairsEachRemovalWithTheAdditionBesideIt() {
        let rows = splitRows(parsePatch("x.ts", Self.patch))
        #expect(rows.map { "\($0.left?.old ?? 0)/\($0.right?.new ?? 0)" } == ["1/1", "2/2", "3/3", "0/4", "4/5"])
        #expect(rowAnchors(rows[1]) == ["R:2", "L:2"])
    }

    @Test func unifiedRowsAnchorBySideAndAKeptLineAnswersToBoth() {
        let f = parsePatch("x.ts", Self.patch)
        #expect(unifiedRows(f).map(\.key) == ["R:1", "L:2", "L:3", "R:2", "R:3", "R:4", "R:5"])
        #expect(anchorsOf(f.hunks[0].lines[0]) == ["R:1", "L:1"])
    }

    // highlight.ts: the web app's spans for these lines, read with node from the v2 source
    static func spans(_ line: String, _ lang: Lang) -> String {
        let u = Array(line.utf16)
        return tokens(line, lang).map { "\($0.kind.rawValue):\(String(utf16CodeUnits: Array(u[$0.location..<($0.location + $0.length)]), count: $0.length))" }.joined(separator: " ")
    }

    @Test func highlightMatchesTheWebApp() {
        #expect(Self.spans(#"export const x: Widget = "a<b>" // note"#, .ts) == #"k:export k:const t:Widget s:"a<b>" c:// note"#)
        #expect(Self.spans("  * doc comment", .ts) == "c:  * doc comment")
        #expect(Self.spans("#!/bin/sh", .ts) == "")
        #expect(Self.spans("#!/bin/sh", .py) == "c:#!/bin/sh")
        #expect(Self.spans("x = 12abc + 1.5x + 3.25 + 0x1F", .ts) == "n:1 n:3.25")
        #expect(Self.spans(#"s = 'it\'s' + `t${a}`"#, .ts) == #"s:'it\'s' s:`t${a}`"#)
        #expect(Self.spans("/* a */ b /* open", .ts) == "c:/* a */ c:/* open")
        #expect(Self.spans("foo#bar baz # c", .ts) == "")
        #expect(Self.spans("foo#bar baz # c", .sh) == "c:#bar baz # c")
        #expect(Self.spans("def f(self): return None", .py) == "k:def k:self k:return k:None")
        #expect(tokens("anything", .plain).isEmpty)
    }

    @Test func langOfFollowsTheExtension() {
        #expect(langOf("a/b.tsx") == .ts)
        #expect(langOf("x.py") == .py)
        #expect(langOf("Makefile") == .sh)
        #expect(langOf("README.md") == .plain)
    }

    // ── review-context.test.ts ──

    static let lines = (1...30).map { "n\($0)" } + [""]
    static let ctxPatch = ["@@ -8,5 +8,5 @@ function a() {", " n8", " n9", "-old10", "+n10", " n11", " n12",
                           "@@ -23,6 +23,5 @@ function b() {", " n23", " n24", "-gone", "-old25", "+n25", " n26", " n27"].joined(separator: "\n")
    static func nums(_ f: FileDiff) -> String { unifiedRows(f).map { "\($0.left?.old.map(String.init) ?? "-")/\($0.right?.new.map(String.init) ?? "-")" }.joined(separator: " ") }

    @Test func unreadTheGapsBeforeEachHunkAndAnOpenEndedOneAfter() {
        let (_, gaps) = expand(parsePatch("x.ts", Self.ctxPatch), nil, [:])
        #expect(gaps == [Gap(at: 0, first: 1, last: 7, label: "function a() {"), Gap(at: 1, first: 13, last: 22, label: "function b() {"), Gap(at: 2, first: 28, last: nil, label: "")])
    }

    @Test func revealingAboveAHunkAddsContextNearestTheChangeFirst() {
        let (file, gaps) = expand(parsePatch("x.ts", Self.ctxPatch), Self.lines, [1: 3])
        #expect(Self.nums(file).contains("12/12 20/20 21/21 22/22 23/23"))
        #expect(gaps.map { [$0.at, $0.first, $0.last ?? -1] } == [[0, 1, 7], [1, 13, 19], [2, 28, 30]])
        #expect(file.hunks[1].lines[0].text == "n20")
    }

    @Test func revealingPastAGapClosesItAndOldNumbersKeepTheOffsetAfterTheLastHunk() {
        let (file, gaps) = expand(parsePatch("x.ts", Self.ctxPatch), Self.lines, [0: 50, 2: 2])
        #expect(gaps.map(\.at) == [1, 2])
        #expect(Self.nums(file).hasPrefix("1/1 2/2 "))
        #expect(Self.nums(file).hasSuffix(" 28/27 29/28 30/29"))
        #expect(gaps[1].first == 30 && gaps[1].last == 30)
    }

    @Test func addedDeletedAndBinaryFilesHaveNothingHidden() {
        var f = parsePatch("x.ts", Self.ctxPatch)
        f.status = .added
        #expect(expand(f, Self.lines, [:]).gaps.isEmpty)
        f.status = .deleted
        #expect(expand(f, nil, [:]).gaps.isEmpty)
    }

    // ── review-viewed.test.ts ──

    static func keys(_ patch: String, _ path: String = "x.ts") -> [String] { blocksOf(parsePatch(path, patch)).map(\.key) }
    static let wide = ["@@ -1,12 +1,12 @@", " a", " b", "-c", "+C", " d", " e", " f", " g", "-h", "+H", " i", " j", " k"].joined(separator: "\n")
    static let narrow = ["@@ -2,3 +2,3 @@", " b", "-c", "+C", " d", "@@ -7,3 +7,3 @@", " g", "-h", "+H", " i"].joined(separator: "\n")

    @Test func aChangeKeepsItsKeyWhetherGitGroupsItIntoOneHunkOrTwo() {
        #expect(Self.keys(Self.wide).count == 2)
        #expect(Self.keys(Self.wide) == Self.keys(Self.narrow))
    }

    @Test func lineShiftsAndEditedContextDontChangeAKeyEditingTheChangeDoes() {
        let shifted = ["@@ -40,3 +52,3 @@", " other", "-c", "+C", " lines"].joined(separator: "\n")
        #expect(Self.keys(shifted)[0] == Self.keys(Self.narrow)[0])
        let edited = ["@@ -2,3 +2,3 @@", " b", "-c", "+C2", " d"].joined(separator: "\n")
        #expect(Self.keys(edited)[0] != Self.keys(Self.narrow)[0])
    }

    @Test func theSameChangeElsewhereOrTwiceGetsItsOwnKey() {
        #expect(Self.keys(Self.narrow, "y.ts")[0] != Self.keys(Self.narrow)[0])
        let twice = ["@@ -1,3 +1,3 @@", " a", "-c", "+C", " b", "@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].joined(separator: "\n")
        let k = Self.keys(twice)
        #expect(k[0] != k[1])
    }

    @Test func aBlockKnowsItsHunkAndAFileWithNoChangedLinesStillHasOneThingToView() {
        #expect(blocksOf(parsePatch("x.ts", Self.narrow)).map(\.hunk) == [0, 1])
        var bin = parsePatch("img.png", "")
        bin.status = .binary
        let b = blocksOf(bin)
        #expect(b.count == 1 && b[0].hunk == -1)
    }

    /// Marks made before 2026-11-05 are stored under the web app's keys: `legacy` must be exactly those.
    @Test func legacyBlockKeysAreTheWebAppsBitForBit() {
        func legacy(_ patch: String, _ path: String = "x.ts") -> [String] { blocksOf(parsePatch(path, patch)).map(\.legacy) }
        #expect(legacy(Self.narrow) == ["1ax3zbksxx", "1ru9mehgcvd"])
        #expect(legacy("@@ -1,1 +1,1 @@\n-𝒳 old\n+new 😀 é", "dir/ünï €.ts") == ["1o2so8t1nlx"])
        var bin = parsePatch("img.png", "")
        bin.status = .binary
        #expect(blocksOf(bin).map(\.legacy) == ["pkzjdhyy6l"] && blocksOf(bin).map(\.key) == ["pkzjdhyy6l"])
        let twice = ["@@ -1,3 +1,3 @@", " a", "-c", "+C", " b", "@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].joined(separator: "\n")
        #expect(legacy(twice) == ["1ax3zbksxx", "1ax3zbksxx.1"])
    }

    @Test func aReformatKeepsAKey() {
        let reflowed = ["@@ -2,3 +2,3 @@", " b", "-c", "+  C", " d", "@@ -7,3 +7,3 @@", " g", "-h", "+H ", " i"].joined(separator: "\n")
        #expect(Self.keys(reflowed) == Self.keys(Self.narrow))
        let wrapped = ["@@ -1,3 +1,4 @@", " a", "-f(x, y)", "+f(x,", "+  y)", " b"].joined(separator: "\n")
        let flat = ["@@ -1,3 +1,3 @@", " a", "-f(x, y)", "+f(x,y)", " b"].joined(separator: "\n")
        #expect(Self.keys(wrapped) == Self.keys(flat))
    }

    /// The bug the ordinal had: a copy added above a read change took its number, and with it the mark.
    @Test func aNewCopyOfAChangeNeverTakesTheOldOnesKey() {
        let once = ["@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].joined(separator: "\n")
        let copyAbove = ["@@ -1,3 +1,3 @@", " a", "-c", "+C", " b", "@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].joined(separator: "\n")
        let read = Self.keys(once)[0]
        let now = Self.keys(copyAbove)
        #expect(!now.contains(read), "neither copy keeps the lone change's key: both come back to read")
        #expect(now[0] != now[1])
        let copyBelow = ["@@ -9,3 +9,3 @@", " y", "-c", "+C", " z", "@@ -20,3 +20,3 @@", " p", "-c", "+C", " q"].joined(separator: "\n")
        #expect(Self.keys(copyBelow)[0] == now[1], "a copy's key follows its own neighbours, not its place in the file")
    }

    // ── types.ts positions ──

    @Test func theCursorLinesFirstNameSkipsKeywordsAndKnowsItsMember() {
        let p = CodeLookup.position(path: "a.ts", line: 3, text: "export const foo = Bar.baz(1)")
        #expect(p?.character == 13)
        let q = CodeLookup.position(path: "a.ts", line: 3, text: "return Bar.baz(1)")
        #expect(q?.character == 7 && q?.member == 11)
        #expect(CodeLookup.position(path: "a.ts", line: 1, text: "  } else {") == nil)
        #expect(CodeLookup.wordAt("call(fooBar)", 7).map { [$0.start, $0.end] } == [5, 11])
        #expect(CodeLookup.wordAt("a  b", 2) == nil)
    }
}

// ── the page, by key ──

@MainActor @Suite(.serialized) struct ReviewPageTests {
    static let branch = "loops:add-hankles-limited-label"
    nonisolated(unsafe) static var nextPort = 43000

    static let patchA = ["@@ -1,4 +1,5 @@", " keep", "-old one", "+new one", "+new two", " mid", " tail",
                         "@@ -20,3 +21,3 @@ function far() {", " x", "-y", "+Y", " z"].joined(separator: "\n")
    static let patchB = ["@@ -5,2 +5,2 @@", " a", "-b", "+B"].joined(separator: "\n")

    static var payload: String {
        let files: JSONValue = .array([
            ["path": "a.ts", "add": 3, "del": 2, "patch": .string(patchA)],
            ["path": "b.ts", "add": 1, "del": 1, "patch": .string(patchB)],
        ])
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123", "files": files]
        return String(decoding: try! JSONEncoder().encode(o), as: UTF8.self)
    }

    /// The review page on the fixture's branch, its diff answered by the stub, a second branch after
    /// it in merge order, an open thread on a.ts's new line 3.
    func app(_ payload: String? = nil) async throws -> (AppModel, Int) {
        Self.nextPort += 1
        let p = Self.nextPort
        ShipStub.answer(p, "GET", "/loops/node", payload ?? Self.payload)
        var c = AppConfig()
        c.route = .review(repo: "loops", branch: "add-hankles-limited-label")
        let a = AppModel(config: c, port: p, telemetry: false, protocolClasses: [ShipStub.self])
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../CanopyCoreTests/Fixtures/state.json")
        var state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object!
        var ents = state["entities"]!.object!
        var branches = ents["branch"]!.object!
        var next = branches[Self.branch]!.object!
        next["id"] = .string("loops:hankles-next"); next["name"] = .string("hankles-next"); next["order"] = .number(2); next["parentId"] = .string(Self.branch); next["tip"] = .string("abc")
        branches["loops:hankles-next"] = .object(next)
        ents["branch"] = .object(branches)
        var threads = ents["thread"]!.object!
        var t = threads["\(Self.branch)#PRRT_kwDOGSZuWM6xwpk_"]!.object!
        t["id"] = .string("\(Self.branch)#T1"); t["node"] = .string("T1"); t["path"] = .string("a.ts"); t["resolved"] = .bool(false); t["outdated"] = .bool(false)
        t["local"] = ["line": 3]
        threads["\(Self.branch)#T1"] = .object(t)
        ents["thread"] = .object(threads)
        state["entities"] = .object(ents)
        a.store.hydrate(try Snapshot.decode(JSONEncoder().encode(JSONValue.object(state))))
        a.transport.repos = ["loops"]
        ShipState.of(a).openURL = { _ in Issue.record("a test tried to open a browser") }
        let pg = ReviewPageState.of(a)
        pg.sync()
        await until("the diff") { pg.payload != nil }
        return (a, p)
    }

    func until(_ what: String, timeout: Double = 3, _ ok: () -> Bool) async {
        let t0 = Date()
        while !ok() {
            if Date().timeIntervalSince(t0) > timeout { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func keys(_ a: AppModel, _ ks: String...) { for k in ks { a.keys.handle(k) } }

    @Test func theDiffLandsWithTheCursorOnItsFirstChange() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.key == "l|a.ts|R:2", "past the context line, on the first changed pair")
        #expect(a.pane?.id == reviewDiffPane)
        #expect(pg.stops.first?.key == "f|a.ts")
        #expect(pg.stops.contains { $0.key == "t|\(Self.branch)#T1" })
        #expect(pg.stops.contains { $0.key == "g|a.ts|1" })
        #expect(ReviewPage.treeRows(pg) == ["f|a.ts", "f|b.ts"])
        #expect(a.liveScopes().first == .line)
    }

    @Test func movingByLineHunkFileAndThread() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.key == "l|a.ts|R:2", "split: the changed pair is one row, keyed by its new line")
        keys(a, "]", "g")
        #expect(pg.here?.key == "l|a.ts|R:22", "the next change's first line")
        keys(a, "[", "g")
        #expect(pg.here?.key == "l|a.ts|R:2")
        keys(a, "}")
        #expect(pg.here?.key == "l|b.ts|R:6", "the next file's first change, not its header")
        keys(a, "{")
        #expect(pg.here?.key == "l|a.ts|R:2", "the previous file's first change")
        keys(a, "]", "r")
        #expect(pg.here?.key == "t|\(Self.branch)#T1")
        #expect(a.liveScopes().contains(.thread))
        keys(a, "G")
        #expect(pg.here?.key == pg.stops.last { $0.row.map(changed) ?? false }?.key, "the last change")
        keys(a, "g", "g")
        #expect(pg.here?.key == "l|a.ts|R:2", "the first change")
    }

    /// In a one-file diff ] [ walk its changes, and } { say there's no other file and what to press.
    @Test func bracketsWalkChangesBracesSayWhyInAOneFileDiff() async throws {
        let patch = ["@@ -1,5 +1,4 @@", " import {", "-  Gone,", "   Kept,", " } from \"x\";", " tail",
                     "@@ -40,3 +39,3 @@", " a", "-b", "+B", " c"].joined(separator: "\n")
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123",
                            "files": .array([["path": "a.ts", "add": 1, "del": 2, "patch": .string(patch)]])]
        let (a, _) = try await app(String(decoding: try JSONEncoder().encode(o), as: UTF8.self))
        let pg = ReviewPageState.of(a)
        let removed = pg.here?.key
        keys(a, "}")
        #expect(pg.here?.key == removed && a.runner.note == "the only file in this diff · ] g [ g move by change")
        keys(a, "]", "g")
        #expect(pg.here?.key == "l|a.ts|R:40", "the next change, from the removed line")
        keys(a, "]", "g")
        #expect(pg.here?.key == "l|a.ts|R:40" && a.runner.note?.hasPrefix("the last change") == true)
        keys(a, "[", "g")
        #expect(pg.here?.key == removed)
    }

    /// Two edits git keeps in one hunk are two changes: ] stops at each.
    @Test func bracketsStopAtEachEditInsideAHunk() async throws {
        let patch = ["@@ -1,6 +1,6 @@", " a", "-b", "+B", " c", " d", "-e", "+E", " f"].joined(separator: "\n")
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123",
                            "files": .array([["path": "a.ts", "add": 2, "del": 2, "patch": .string(patch)]])]
        let (a, _) = try await app(String(decoding: try JSONEncoder().encode(o), as: UTF8.self))
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.key == "l|a.ts|R:2")
        keys(a, "]", "g")
        #expect(pg.here?.key == "l|a.ts|R:5", "the second edit, though git holds both in one hunk")
        #expect(a.position?.contains("change 2 of 2") == true, "the statusline counts the same changes: \(a.position ?? "-")")
        keys(a, "k", "k", "[", "g")
        #expect(pg.here?.key == "l|a.ts|R:2", "from the unchanged lines between, [ is the edit above")
        keys(a, "j", "]", "g")
        #expect(pg.here?.key == "l|a.ts|R:5")
    }

    /// } at the last file wraps to the first, as Helix's g n cycles its buffers — and says it wrapped.
    @Test func nextFileWrapsAtTheEnd() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        let start = pg.here?.key
        keys(a, "}")
        #expect(pg.here?.path == "b.ts")
        keys(a, "}")
        #expect(pg.here?.key == start && a.runner.note == "wrapped to the first file")
        keys(a, "{")
        #expect(pg.here?.path == "b.ts" && a.runner.note == "wrapped to the last file")
    }

    /// ] p walks git's hunks: one stop per @@, across files, then says it's at the last.
    @Test func bracketPWalksGitHunks() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "]", "p")
        #expect(pg.here?.path == "a.ts" && pg.here?.row?.right?.new == 21, "a.ts's second hunk: \(pg.here?.key ?? "-")")
        keys(a, "]", "p")
        #expect(pg.here?.path == "b.ts" && pg.here?.row?.right?.new == 5)
        keys(a, "]", "p")
        #expect(pg.here?.path == "b.ts" && a.runner.note == "the last hunk in this diff")
        keys(a, "[", "p")
        #expect(pg.here?.path == "a.ts" && pg.here?.row?.right?.new == 21)
    }

    /// ] T skips to the next test file; past the last one it says so.
    @Test func bracketTWalksTestFiles() async throws {
        let p = ["@@ -1,1 +1,1 @@", "-a", "+A"].joined(separator: "\n")
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123", "files": .array([
            ["path": "src/x.ts", "add": 1, "del": 1, "patch": .string(p)],
            ["path": "src/y.ts", "add": 1, "del": 1, "patch": .string(p)],
            ["path": "src/x.test.ts", "add": 1, "del": 1, "patch": .string(p)],
        ])]
        let (a, _) = try await app(String(decoding: try JSONEncoder().encode(o), as: UTF8.self))
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.path == "src/x.ts")
        keys(a, "]", "T")
        #expect(pg.here?.path == "src/x.test.ts")
        keys(a, "]", "T")
        #expect(pg.here?.path == "src/x.test.ts" && a.runner.note == "no test file after this one")
        #expect(isTestPath("a/__tests__/b.ts") && isTestPath("c_spec.rb") && !isTestPath("contest.ts"))
    }

    /// ] r reaches a conversation; ] c a comment in the code (Helix); n with no search says so.
    @Test func bracketRIsConversationsBracketCIsComments() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "]", "r")
        #expect(pg.here?.kind == .thread, "landed on \(pg.here?.key ?? "-")")
        keys(a, "n")
        #expect(a.runner.note == "no search · / or ? searches")
        let patch = ["@@ -1,3 +1,4 @@", " a", "+// why b", " b", " c"].joined(separator: "\n")
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123",
                            "files": .array([["path": "z.ts", "add": 1, "del": 0, "patch": .string(patch)]])]
        let (b, _) = try await app(String(decoding: try JSONEncoder().encode(o), as: UTF8.self))
        let pb = ReviewPageState.of(b)
        keys(b, "g", "g", "]", "c")
        #expect(pb.here?.row?.right?.text == "// why b", "\(pb.here?.key ?? "-")")
        keys(b, "]", "c")
        #expect(b.runner.note == "the last comment")
    }

    /// W / B step over runs of non-blank characters; E lands on a run's last character.
    @Test func longWordsAreRunsOfNonBlanks() async throws {
        #expect(longWords("  a.b(c)  d ") == [2..<8, 10..<11])
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "E")
        let first = pg.hereWord?.lowerBound
        keys(a, "E")
        let second = pg.hereWord?.lowerBound
        #expect(first == 2 && second == 6, "\"xxx one\": E at 2 then 6, got \(String(describing: first)) \(String(describing: second))")
        keys(a, "B")
        #expect(pg.hereWord?.lowerBound == 4)
    }

    /// Digits are Helix's counts: 3 j is three lines, 2 } two files; esc drops a count; space N picks a tab.
    @Test func digitsAreCountsAndSpaceDigitPicks() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        let start = try #require(pg.here.flatMap { pg.stopIndex[$0.key] })
        keys(a, "j", "j", "j")
        let three = pg.here?.key
        keys(a, "k", "k", "k")
        #expect(pg.stopIndex[pg.here?.key ?? ""] == start)
        keys(a, "3")
        #expect(a.keys.count == 3 && pg.tab == "files", "a bare digit waits as a count, never a tab")
        keys(a, "j")
        #expect(pg.here?.key == three && a.keys.count == nil)
        keys(a, "1", "2", "esc")
        #expect(a.keys.count == nil && pg.here?.key == three, "esc drops the count")
        keys(a, "2", "}")
        #expect(pg.here?.path == "a.ts", "two files on from a.ts, wrapping: \(pg.here?.key ?? "-")")
        keys(a, "space", "1")
        #expect(pg.tab == "conversation")
        keys(a, "space", "3")
        #expect(pg.tab == "files")
    }

    /// A tab is a place, named by its key: space h the history, space c the conversation, space g the files; again goes back.
    @Test func eachTabHasANamedKey() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "space", "h")
        #expect(pg.tab == "commits")
        keys(a, "space", "h")
        #expect(pg.tab == "files", "the same key brings the diff back")
        keys(a, "space", "c")
        #expect(pg.tab == "conversation")
        keys(a, "space", "h")
        #expect(pg.tab == "commits", "from one face straight to another")
        keys(a, "space", "g")
        #expect(pg.tab == "files")
    }

    /// A place names the commit it shows: the address keeps it and opening the address comes back to it.
    @Test func theCommitInViewSurvivesTheAddress() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":2,"del":0,"patch":"@@ -1,0 +1,2 @@\n+hi\n+there"}]}"#)
        keys(a, "space", "2")
        ShipState.of(a).showCommit("c1")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        pg.focusDiff(a, true)
        keys(a, "j")
        let at = a.here()
        #expect(at.commit == "c1" && at.address.contains("commit=c1"), "\(at.address)")
        #expect(Place(address: at.address).commit == "c1")

        let (b, q) = try await app()
        ShipStub.answer(q, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":2,"del":0,"patch":"@@ -1,0 +1,2 @@\n+hi\n+there"}]}"#)
        let pb = ReviewPageState.of(b)
        b.open(address: at.address)
        await until("back on the commit") { pb.commitScope == "c1" && pb.files.map(\.path) == ["c.ts"] }
        await until("at the same line") { pb.here?.key == pg.here?.key }
        #expect(pb.tab == "commits" && pb.here?.key == pg.here?.key, "\(pb.here?.key ?? "-") vs \(pg.here?.key ?? "-")")
    }

    @Test func jumpsComeBackWithCtrlO() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "}")
        #expect(pg.here?.key == "l|b.ts|R:6")
        keys(a, "C-o")
        #expect(pg.here?.key == "l|a.ts|R:2")
        keys(a, "C-i")
        #expect(pg.here?.key == "l|b.ts|R:6")
    }

    @Test func mMarksTheHunkViewedAndMovesOnMUnmarks() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true,"count":1,"on":true}"#)
        let hunk0 = pg.fileOf("a.ts")!.blocks.filter { $0.hunk == 0 }
        keys(a, ",", "m")
        #expect(hunk0.allSatisfy(pg.isSeen))
        #expect(pg.here?.key == "l|a.ts|R:22", "on to the next unviewed hunk")
        await until("the post") { ShipStub.posts(p).contains { $0.path == "/loops/viewed" } }
        let post = ShipStub.posts(p).last { $0.path == "/loops/viewed" }!
        #expect(post.body["marks"] == .object(Dictionary(uniqueKeysWithValues: hunk0.map { ($0.key, JSONValue.string("viewed")) })))
        // the last hunk of a.ts: m finishes the file and moves to b.ts
        keys(a, ",", "m")
        #expect(pg.fileOf("a.ts")!.viewed)
        #expect(pg.here?.key == "l|b.ts|R:6", "the next file's first change")
        #expect(!pg.stops.contains { $0.key == "l|a.ts|R:1" }, "a viewed file folds")
        keys(a, "{")
        #expect(pg.here?.key == "f|a.ts", "a viewed file is just its header")
        keys(a, ",", "M")
        #expect(!pg.fileOf("a.ts")!.viewed)
    }

    @Test func bangFlagsAChangeUStopsOnItAndBangAgainTakesItOff() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true}"#)
        let start = pg.here?.key
        let first = pg.fileOf("a.ts")!.blocks[0]
        keys(a, ",", "!")
        #expect(pg.mark(first) == .flagged)
        #expect(pg.here?.key != start, "flagging moves on, like reading")
        await until("the post") { ShipStub.posts(p).contains { $0.path == "/loops/viewed" } }
        #expect(ShipStub.posts(p).last { $0.path == "/loops/viewed" }!.body["marks"] == .object([first.key: .string("flagged")]))
        // read everything else: ] u still finds the flagged one
        for v in pg.views { for b in v.blocks where b != first { pg.viewedOverride[b.key] = .viewed } }
        keys(a, "]", "u")
        #expect(pg.here?.key == start, "] u stops on a flagged change")
        #expect(pg.fileOf("a.ts")!.flagged == 1 && !pg.fileOf("a.ts")!.viewed, "flagged is read, not viewed: the file stays open")
        keys(a, ",", "!")
        #expect(pg.mark(first) == .unread, ", ! on a flagged change takes the flag off")
    }

    @Test func aFlagKeepsWhereItWasAndSpaceBangComesBackToIt() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true}"#)
        // a change that isn't where a page lands by itself
        guard let last = pg.views.last, let first = last.blocks.last, let start = pg.stopOf(block: first.key, in: last.file.path),
              start != pg.here?.key, let place = pg.flagPlace(first.key) else { Issue.record("no later change to flag"); return }
        pg.setCursor(start)
        keys(a, ",", "!")
        await until("the post") { ShipStub.posts(p).contains { $0.path == "/loops/viewed" } }
        let body = ShipStub.posts(p).last { $0.path == "/loops/viewed" }!.body
        #expect(body["where"] == .object([first.key: .object(["path": .string(last.file.path), "line": .number(Double(place.line)), "text": .string(place.text)])]),
                "a flag says where it was made")
        let flag = #"{"key":"\#(first.key)","at":1,"path":"\#(last.file.path)","line":\#(place.line),"text":"x"}"#
        a.store.applyPatch(try Patch.decode(Data(#"{"domain":"review","version":\#((a.store.versions["review"] ?? 0) + 1),"upserts":{"viewed":{"\#(Self.branch)":{"id":"\#(Self.branch)","repo":"loops","branch":"add-hankles-limited-label","keys":[],"flagged":["\#(first.key)"],"flags":[\#(flag)]}}}}"#.utf8)))
        keys(a, "g", "g")
        #expect(pg.here?.key != start)
        keys(a, "space", "!")
        #expect(a.nav.picker?.title == "flagged")
        a.keys.handle("ret")
        #expect(pg.here?.key == start, "picking the flag puts the cursor back on its change")
        // from another branch: the flag's branch opens with the cursor on it once its diff is here
        ShipStub.answer(p, "GET", "/loops/node", Self.payload)
        keys(a, "g", "g", "J")
        await until("the neighbour's diff") { pg.payload?.key.hasPrefix("loops:hankles-next@") == true }
        keys(a, "space", "!")
        a.keys.handle("ret")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"))
        await until("its diff") { pg.here?.key == start }
    }

    @Test func mOnAChangeMarksJustThatChangeNotItsWholeHunk() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true}"#)
        guard let fv = pg.fileOf("a.ts"), let row = pg.here?.row, let b = fv.rowBlock[row.key] else { Issue.record("no change under the cursor"); return }
        keys(a, ",", "m")
        let after = pg.fileOf("a.ts")!
        #expect(after.marks[b] == .viewed)
        #expect(after.marks.enumerated().allSatisfy { $0.offset == b || $0.element == .unread }, "only the change under the cursor")
    }

    @Test func selectModeMarksEveryHunkInTheRange() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true}"#)
        keys(a, "v", "]", "g", ",", "m")
        #expect(a.keys.mode == .normal)
        #expect(pg.fileOf("a.ts")!.viewed)
    }

    @Test func JAndKWalkTheStackStayingOnReview() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/node", Self.payload)
        keys(a, "}")      // on b.ts
        keys(a, "K")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"), "nothing before the first")
        keys(a, "J")
        #expect(a.router.route == .review(repo: "loops", branch: "hankles-next"))
        await until("the neighbour's diff") { pg.payload?.key.hasPrefix("loops:hankles-next@") == true }
        #expect(pg.here?.key == "l|b.ts|R:6" && a.pane?.id == reviewDiffPane, "the same file's first change, keyboard with it")
        keys(a, "[", "b")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"))
    }

    @Test func minusClimbsToTheForestWithTheBranchUnderTheCursor() async throws {
        let (a, _) = try await app()
        keys(a, "-")
        #expect(a.router.route == .forest(repo: "loops", project: "hankles-limited-label"))
        #expect(a.selected == RowKey.branch(Self.branch))
    }

    /// h / l move a character along the code; at the new half's start h crosses onto the old half of a
    /// removed line, and l crosses back. They never leave the diff: ⌃h / ⌃l move panes.
    @Test func hAndLMoveACharacterAndCtrlMovesPanes() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        let row = try #require(pg.here?.row)
        #expect(pg.here?.key == "l|a.ts|R:2" && pg.hereWord == nil)
        let new = row.right?.text ?? "", old = row.left?.text ?? ""
        let start = new.utf16.firstIndex { $0 != 32 }.map { new.utf16.distance(from: new.utf16.startIndex, to: $0) } ?? 0
        keys(a, "l")
        #expect(pg.column == .right && pg.hereWord == start..<(start + 1), "l enters the line at its first character")
        keys(a, "l")
        #expect(pg.hereWord == (start + 1)..<(start + 2), "then one character at a time")
        keys(a, "h", "h")
        #expect(pg.hereWord == (start - 1)..<start || start == 0)
        for _ in 0..<start { keys(a, "h") }
        #expect(pg.column == .left && pg.range?.side == .left, "past the new half's start, the old half of the removed line")
        #expect(pg.hereWord == (old.utf16.count - 1)..<old.utf16.count && a.pane?.id == reviewDiffPane, "at its last character")
        keys(a, "l")
        #expect(pg.column == .right && pg.range?.side == .right, "and l crosses back")
        keys(a, "j")
        #expect(pg.hereWord?.count == 1 && pg.here?.key != "l|a.ts|R:2", "j keeps the character cursor on the next line")
        keys(a, "C-h")
        #expect(a.pane?.id == reviewTreePane, "⌃h, the pane to the left")
        keys(a, "C-l")
        #expect(a.pane?.id == reviewDiffPane)
        pg.open(Loc(repo: "loops", sha: "zzz", path: "other.ts", line: 4))
        #expect(a.pane?.id == reviewCodePane && !a.panes.contains { $0.id == reviewDiffPane }, "the file is in the diff's place")
        keys(a, "C-h")
        #expect(a.pane?.id == reviewTreePane, "⌃h, the pane to the left of it")
        keys(a, "C-l")
        #expect(a.pane?.id == reviewCodePane)
    }

    /// The motion rules, checked on every review motion command from every kind of starting place —
    /// a new motion gets them checked without anyone writing a test for it:
    /// a key that can't act says why; the keyboard goes where the cursor went; a jump lands on code.
    @Test func everyMotionKeepsTheRules() async throws {
        let motions: Set<Verb> = [.next, .previous, .first, .last, .halfDown, .halfUp, .left, .right, .nextWord, .previousWord,
                                  .nextFile, .previousFile, .nextHunk, .previousHunk, .nextThread, .previousThread,
                                  .nextConversation, .previousConversation, .nextTest, .previousTest, .nextGitHunk, .previousGitHunk,
                                  .nextLongWord, .previousLongWord, .longWordEnd, .scrollDown, .scrollUp]
        let jumps: Set<Verb> = [.first, .last, .nextFile, .previousFile, .nextHunk, .previousHunk, .nextTest, .previousTest,
                                .nextGitHunk, .previousGitHunk]
        let starts: [(String, @MainActor (AppModel, ReviewPageState) -> Void)] = [
            ("the first change", { _, _ in }),
            ("a file header", { _, pg in pg.setCursor("f|a.ts") }),
            ("the diff's last row", { _, pg in pg.setCursor(pg.stops.last?.key) }),
            ("a conversation", { _, pg in pg.setCursor("t|\(Self.branch)#T1") }),
            ("the old half of a removed line", { _, pg in pg.column = .left }),
            ("the file list", { a, _ in a.focus(pane: reviewTreePane) }),
        ]
        let (probe, _) = try await app()
        let ids = probe.registry.commands.filter { $0.scope == .review && !motions.isDisjoint(with: $0.verbs) }.map(\.id)
        #expect(ids.count >= 14, "the motions are all found: \(ids)")
        for id in ids {
            let isJump = !jumps.isDisjoint(with: probe.registry.command(id)?.verbs ?? [])
            for (from, setup) in starts {
                let (a, _) = try await app()
                let pg = ReviewPageState.of(a)
                setup(a, pg)
                guard let cmd = a.registry.command(id), cmd.available?(nil) != false, cmd.modes.contains(a.keys.mode) else { continue }
                let before = (pg.here?.key, pg.hereWord, a.pane?.id, pg.column, a.selected)
                a.runner.dispatch(id, via: .key)
                let after = (pg.here?.key, pg.hereWord, a.pane?.id, pg.column, a.selected)
                let moved = before.0 != after.0 || before.1 != after.1 || before.2 != after.2 || before.3 != after.3 || before.4 != after.4
                #expect(moved || a.runner.note != nil, "\(id) from \(from): did nothing and said nothing")
                if before.0 != after.0 { #expect(a.pane?.id == reviewDiffPane, "\(id) from \(from): moved the diff cursor but left the keyboard in \(a.pane?.id ?? "-")") }
                if isJump && moved { #expect(pg.here?.kind == .line, "\(id) from \(from): landed on a \(pg.here?.kind.rawValue ?? "-"), not code") }
            }
        }
    }

    /// On a row with no code (a file's header), h / l say so instead of leaving the diff.
    @Test func hOnAHeaderStaysInTheDiff() async throws {
        let (a, _) = try await app()
        ReviewPageState.of(a).setCursor("f|a.ts")
        #expect(ReviewPageState.of(a).here?.kind == .file)
        keys(a, "h")
        #expect(a.pane?.id == reviewDiffPane)
    }

    /// The margin is the files alone, the same width wherever the keyboard is; the commits are the
    /// header chip's and the commits tab's, never a pane beside the diff.
    @Test func theMarginIsTheFilesAtOneWidth() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        #expect(pg.scopesCommits)
        #expect(a.panes.map(\.id).first == reviewTreePane && !a.panes.contains { $0.id == ShipSeam.historyPane })
        let width = pg.treeWidth
        keys(a, "C-h")
        #expect(a.pane?.id == reviewTreePane && pg.treeWidth == width)
    }

    /// , h picks what the diff covers: one commit, then every commit again; the files tab keeps the reader.
    @Test func commaHPicksTheCommitsTheDiffCovers() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let ship = ShipState.of(a)
        let b = try #require(pg.branch)
        ship.putHistory(b, [HistoryCommit(sha: "c2", subject: "use a plain delete"), HistoryCommit(sha: "c1", subject: "feat: add x")])
        ShipStub.answer(p, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":2,"del":0,"patch":"@@ -1,0 +1,2 @@\n+hi\n+there"}]}"#)
        keys(a, ",", "h")
        #expect(a.nav.picker?.title == "the diff covers" && a.nav.picker?.items.count == 3)
        a.nav.move(2)
        keys(a, "ret")
        #expect(a.nav.picker == nil && ship.commitScope == "c1" && pg.tab == "files")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        #expect(a.pane?.id == reviewDiffPane)
        keys(a, ",", "h")
        keys(a, "ret")
        #expect(ship.commitScope == nil && pg.tab == "files", "the first row is every commit")
    }

    /// w / b put a one-character cursor on each name's first character, crossing lines; g d / space k ask about that name.
    @Test func wAndBStepNameToNameAcrossLines() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "w")
        let first = try #require(pg.here)
        let names = CodeLookup.names(first.row?.right?.text ?? "")
        let start = { (r: Range<Int>?) in r.map { $0.lowerBound ..< $0.lowerBound + 1 } }
        #expect(pg.hereWord == start(names.first))
        var presses = 0
        while pg.here?.key == first.key && presses < 20 { keys(a, "w"); presses += 1 }
        #expect(presses == names.count, "every name on the line, then the next line's")
        let next = try #require(pg.here)
        #expect(next.key != first.key && pg.hereWord == start(CodeLookup.names(next.row?.right?.text ?? "").first))
        keys(a, "b")
        #expect(pg.here?.key == first.key && pg.hereWord == start(names.last), "back to the last name of the line before")
        keys(a, "j")
        #expect(pg.hereWord?.count == 1, "j keeps the column as a one-character cursor")
    }

    /// i on a new line opens Helix there, in the branch's diff checkout; quitting it commits what changed.
    @Test func iOpensHelixOnTheNewHalfAndQuittingCommits() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/review-helix", #"{"ok":true,"dir":"/tmp/x.diffbase","sha":"abc1234","message":"fixup! feat: x"}"#)
        keys(a, "i")
        await until("the checkout") { pg.helix?.dir != nil }
        let h = try #require(pg.helix)
        #expect(h.path == "a.ts" && h.line == 2 && h.dir == "/tmp/x.diffbase" && h.sha == "abc1234")
        let asked = try #require(ShipStub.posts(p).last { $0.path == "/loops/review-helix" })
        #expect(asked.body["op"] == .string("where"))
        pg.landHelix(a)
        #expect(pg.helix == nil, "the diff is back at once")
        await until("the land") { ShipStub.posts(p).contains { $0.body["op"] == .string("land") } }
        let land = try #require(ShipStub.posts(p).last { $0.body["op"] == .string("land") })
        #expect(land.body["dir"] == .string("/tmp/x.diffbase") && land.body["sha"] == .string("abc1234"))
    }

    /// o from the code beside the diff opens Helix at that file, line and name — not the diff's
    /// cursor — and quitting puts that pane back where Helix left off.
    @Test func oFromTheCodeBesideTheDiffOpensHelixThere() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "POST", "/loops/review-helix", #"{"ok":true,"dir":"/tmp/x.diffbase","sha":"\#(tip)"}"#)
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":2,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\nconst two = three\n\nfour"}"#)
        keys(a, "g", "d")
        await until("the side pane") { pg.sideText != nil }
        keys(a, "w", "o")
        let h = try #require(pg.helix)
        #expect(h.path == "lib/z.ts" && h.line == 2 && h.col == 7 && h.whole && h.fromSide)
        await until("the checkout") { pg.helix?.dir != nil }
        pg.helixAt = ("lib/z.ts", 4)
        pg.landHelix(a)
        #expect(pg.side?.path == "lib/z.ts" && a.pane?.id == reviewCodePane && a.selected == "s:4", "back in the window, where Helix left off")
    }

    /// i on the old half has nothing to edit: that's history.
    @Test func iOnTheOldHalfOpensNothing() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        pg.column = .left
        keys(a, "i")
        #expect(pg.helix == nil)
    }

    /// space c puts the conversation where the diff was; esc brings the diff back.
    @Test func spaceCIsALayerOverTheDiff() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "space", "c")
        #expect(pg.tab == "conversation")
        keys(a, "esc")
        #expect(pg.tab == "files" && a.pane?.id == reviewDiffPane)
    }

    /// space r on a name asks for the new one; esc lets it go without a request.
    @Test func spaceRAsksForTheNewName() async throws {
        let (a, _) = try await app()
        keys(a, "w")
        keys(a, "space", "r")
        #expect(a.nav.picker?.title == "rename to…")
        keys(a, "esc")
        #expect(a.nav.picker == nil)
    }

    /// esc cancels; it never changes what the window shows (Helix) — C-o does.
    @Test func escOnlyCancels() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        pg.open(Loc(repo: "loops", sha: "zzz", path: "other.ts", line: 4))
        #expect(pg.side != nil && a.pane?.id == reviewCodePane)
        keys(a, "esc")
        #expect(pg.side != nil && a.pane?.id == reviewCodePane)
        #expect(a.router.route.surfaceID == "review")
    }

    /// A diff cursor put from underneath (a reload settling) waits in the diff; the file stays.
    @Test func aDiffCursorFromUnderneathLeavesTheFileShowing() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        pg.open(Loc(repo: "loops", sha: "zzz", path: "other.ts", line: 4))
        let was = a.selected
        pg.setCursor("l|b.ts|R:6", focus: false)
        #expect(pg.side != nil && a.pane?.id == reviewCodePane && a.selected == was)
        #expect(pg.diffCursor == "l|b.ts|R:6")
        pg.setCursor("l|a.ts|R:2")
        #expect(pg.side == nil && a.pane?.id == reviewDiffPane && a.selected == "l|a.ts|R:2", "a jump into the diff shows it")
    }

    @Test func theBaseRidesTheAddress() async throws {
        let (a, _) = try await app()
        keys(a, ",", "b", "m")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label", base: "main"))
        #expect(ReviewPageState.of(a).keyOf.hasSuffix("|main"))
    }

    @Test func retOnAGapShowsTwentyMoreLines() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/file", (1...40).map { "n\($0)" }.joined(separator: "\n"))
        pg.setCursor("g|a.ts|1")
        #expect(a.liveScopes().first == .gap)
        keys(a, "ret")
        await until("the gap to close") { pg.fileOf("a.ts")!.gaps.first { $0.at == 1 } == nil }
        #expect(pg.stops.contains { $0.key == "l|a.ts|R:12" }, "the 15 hidden lines show")
        #expect(pg.here?.key == "l|a.ts|R:6", "the cursor lands on the line the gap ended on")
    }

    /// g d replaces what the window shows (Helix's Action::Replace); C-o puts the diff back, C-i the file.
    @Test func gdReplacesWhatTheWindowShows() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"b.ts","line":6,"character":0}]}"#)
        keys(a, "g", "d")
        await until("the jump") { pg.here?.key == "l|b.ts|R:6" }
        let ask = ShipStub.posts(p).last { $0.path == "/loops/lsp/definition" }!
        #expect(ask.body["branch"] == "add-hankles-limited-label" && ask.body["path"] == "a.ts" && ask.body["line"] == 2)
        keys(a, "C-o")
        #expect(pg.here?.key == "l|a.ts|R:2")
        // somewhere the diff doesn't show: the file at the commit, in the diff's place
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":2,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\ntwo\nthree"}"#)
        keys(a, "g", "d")
        await until("the file") { pg.sideText != nil }
        #expect(pg.side?.path == "lib/z.ts" && a.selected == "s:2" && a.pane?.id == reviewCodePane)
        #expect(!a.panes.contains { $0.id == reviewDiffPane }, "in the diff's place, not beside it")
        #expect(ReviewSurface().title(for: "s:2", a) == "2 two")
        keys(a, "C-o")
        #expect(pg.side == nil && a.pane?.id == reviewDiffPane && pg.here?.key == "l|a.ts|R:2", "C-o: the diff, where the jump left it")
        keys(a, "C-i")
        #expect(pg.side?.path == "lib/z.ts" && a.pane?.id == reviewCodePane, "C-i: the file again")
    }

    /// C-w v / C-w s copy the focused window (of the diff: the file at the cursor's line on the tip)
    /// and go into the copy; C-w q closes one (never the last), C-w o all the others.
    @Test func windowsSplitCloseAndOnly() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"a.ts","sha":"x","text":"one\ntwo\nthree"}"#)
        keys(a, "C-w", "v")
        #expect(pg.windows.count == 2 && pg.diffWindow === pg.windows[0])
        let copy = try #require(pg.code)
        await until("the copy's text") { copy.text != nil }
        #expect(copy.doc?.path == "a.ts" && copy.doc?.sha == pg.tip && copy.doc?.line == 2 && a.selected == "s:2")
        #expect(a.panes.first { $0.id == copy.pane }?.column == 2, "beside the diff")
        keys(a, "C-w", "s")
        #expect(pg.windows.count == 3 && pg.code?.column == copy.column, "under the copy, same column")
        keys(a, "C-w", "q")
        #expect(pg.windows.count == 2)
        keys(a, "C-w", "h")
        #expect(a.pane?.id == reviewDiffPane)
        keys(a, "C-w", "o")
        #expect(pg.windows.count == 1 && pg.diffWindow != nil)
        keys(a, "C-w", "q")
        #expect(pg.windows.count == 1 && a.runner.note?.contains("last window") == true)
    }

    /// A jump in one window leaves the others; C-o walks the window's own jumps; a jump to the diff
    /// from a copy goes to the window the diff is in.
    @Test func eachWindowJumpsOnItsOwn() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\ntwo\nthree"}"#)
        keys(a, "C-w", "v")
        let copy = try #require(pg.code)
        await until("the copy's text") { copy.text != nil }
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":3,"character":0}]}"#)
        keys(a, "g", "d")
        await until("the jump in the copy") { copy.doc?.path == "lib/z.ts" }
        #expect(pg.diffWindow === pg.windows[0] && pg.here?.key == "l|a.ts|R:2", "the diff's window didn't move")
        keys(a, "C-w", "h", "C-o")
        #expect(a.pane?.id == reviewDiffPane && copy.doc?.path == "lib/z.ts", "the diff's C-o isn't the copy's jump")
        keys(a, "C-w", "l", "C-o")
        #expect(copy.doc?.path == "a.ts", "the copy's C-o is")
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"b.ts","line":6,"character":0}]}"#)
        keys(a, "g", "d")
        await until("the jump to the diff") { pg.here?.key == "l|b.ts|R:6" }
        #expect(a.pane?.id == reviewDiffPane && copy.doc != nil, "the diff lives in one window: the keyboard goes there")
    }

    /// Picker C-v opens the pick in a window beside this one; ret, in this one.
    @Test func pickerCtrlVOpensThePickBeside() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "POST", "/loops/lsp/references", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":3,"character":0},{"path":"lib/y.ts","line":1,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\ntwo\nthree"}"#)
        keys(a, "g", "r")
        await until("the picker") { a.nav.picker != nil }
        keys(a, "C-v")
        #expect(a.nav.picker == nil && pg.windows.count == 2 && pg.code?.doc?.path == "lib/z.ts" && pg.diffWindow === pg.windows[0])
        keys(a, "C-o")
        #expect(pg.code?.doc?.path == "lib/z.ts", "a new window has no jumps of its own yet")
    }

    /// The code beside the diff reads like Helix: w / b walk its names (what g d asks about), v and x
    /// select lines, space o m / space o b open them on GitHub.
    @Test func theCodeBesideTheDiffMovesLikeHelix() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        var opened: [String] = []
        ShipState.of(a).openURL = { opened.append($0.absoluteString) }
        pg.githubWeb = { _ in "https://github.com/o/r" }
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":2,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\nconst two = three\n\nfour"}"#)
        keys(a, "g", "d")
        await until("the side pane") { pg.sideText != nil }
        keys(a, "w")
        #expect(a.selected == "s:2" && pg.sideHereWord == 6..<7, "two (const is a keyword, not a name)")
        keys(a, "w")
        #expect(pg.sideHereWord == 12..<13, "three")
        keys(a, "w")
        #expect(a.selected == "s:4" && pg.sideHereWord == 0..<1, "past the blank line, four")
        keys(a, "b")
        #expect(a.selected == "s:2" && pg.sideHereWord == 12..<13, "back up, three")
        keys(a, "k")
        #expect(a.selected == "s:1" && pg.sideHereWord == 2..<3, "k keeps the column, as far as the shorter line reaches")
        keys(a, "j")
        #expect(a.selected == "s:2" && pg.sideHereWord == 12..<13, "j goes back to the column it aimed for")
        let asked = ShipStub.posts(p).filter { $0.path == "/loops/lsp/definition" }.count
        keys(a, "g", "d")
        await until("the second ask") { ShipStub.posts(p).filter { $0.path == "/loops/lsp/definition" }.count > asked }
        let ask = ShipStub.posts(p).last { $0.path == "/loops/lsp/definition" }!
        #expect(ask.body["line"] == 2 && ask.body["character"] == 12, "g d asks about the name w landed on")
        await until("the jump, to line 2 of the same file") { a.selected == "s:2" && pg.sideWord == nil }

        keys(a, "x")
        #expect(a.keys.mode == .select && a.selection == ["s:2"])
        keys(a, "x", "j")
        #expect(a.selection == ["s:2", "s:3", "s:4"])
        keys(a, "space", "o", "m")
        await until("the browser") { opened.count == 1 }
        #expect(opened.last == "https://github.com/o/r/blob/main/lib/z.ts#L2-L4")
        keys(a, "esc", "space", "o", "b")
        await until("the browser") { opened.count == 2 }
        #expect(opened.last == "https://github.com/o/r/blob/\(tip)/lib/z.ts#L4", "at the commit the code is shown at")

        // C-o walks back through both jumps (the second g d's start, then the diff)
        for _ in 0..<3 where pg.side != nil { keys(a, "C-o") }
        #expect(pg.side == nil)
        keys(a, "space", "o", "b")
        await until("the browser") { opened.count == 3 }
        #expect(opened.last == "https://github.com/o/r/blob/add-hankles-limited-label/a.ts#L2", "the diff's line, at the branch")
    }

    @Test func originsBecomeGitHubPages() {
        #expect(ReviewPageState.githubPage(remote: "git@github.com:Loops-so/loops.git\n") == "https://github.com/Loops-so/loops")
        #expect(ReviewPageState.githubPage(remote: "https://github.com/phil-loops/loops") == "https://github.com/phil-loops/loops")
        #expect(ReviewPageState.githubPage(remote: "git@gitlab.com:x/y.git") == nil)
    }

    @Test func spaceKAsksAgainWhileTsgoLoads() async throws {
        let (a, p) = try await app()
        let look = CodeLookup.of(a)
        look.retry = 0.02
        ShipStub.answer(p, "POST", "/loops/lsp/hover", #"{"ok":false,"state":"loading","message":"starting"}"#)
        keys(a, "space", "k")
        await until("the wait line") { look.pop == .wait("types are loading — starting") }
        ShipStub.answer(p, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"```ts\nconst keep: string\n```"}"#)
        await until("the type") { look.pop == .hover("```ts\nconst keep: string\n```") }
        #expect(Markdown.parse("```ts\nconst keep: string\n```") == [.code(lang: "ts", lines: ["const keep: string"])], "the hover draws as a code block")
        keys(a, "j")
        #expect(look.pop == nil)
    }

    @Test func slashSearchesTheDiffText() async throws {
        let (a, _) = try await app()
        #expect(ReviewSurface().title(for: "l|a.ts|R:3", a) == "a.ts:3 new two")
        keys(a, "/")
        #expect(a.nav.picker == nil, "no modal")
        PageSearch.of(a).typed(a, "new two")
        #expect(ReviewPageState.of(a).here?.key == "l|a.ts|R:3", "the cursor follows the typing")
        keys(a, "ret")
        keys(a, "g", "g")
        keys(a, "n")
        #expect(ReviewPageState.of(a).here?.key == "l|a.ts|R:3", "n goes to the match, not a thread, while the search is kept")
        keys(a, "esc")
        keys(a, "/")
        PageSearch.of(a).typed(a, "zzz-nothing")
        keys(a, "esc")
        #expect(!PageSearch.of(a).active, "esc while typing drops it")
    }

    /// `/` the Helix way: n steps match by match (two on one line take two presses) and lands on the
    /// match itself, selected like a name; only code is searched — not paths, conversations or gaps.
    @Test func slashLandsOnEachMatchInTheCode() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        func type(_ s: String) { for ch in s { keys(a, ch == " " ? "space" : String(ch)) } }
        pg.setCursor("f|a.ts")
        keys(a, "/"); type("e"); keys(a, "ret")
        #expect(pg.here?.key == "l|a.ts|R:1" && pg.hereWord == 1..<2, "keep: its first e")
        keys(a, "n")
        #expect(pg.here?.key == "l|a.ts|R:1" && pg.hereWord == 2..<3, "the second e on the same line")
        keys(a, "n")
        #expect(pg.here?.key == "l|a.ts|R:2" && pg.column == .right && pg.hereWord == 1..<2, "new one, on the new half")
        keys(a, "N", "N")
        #expect(pg.here?.key == "l|a.ts|R:1" && pg.hereWord == 1..<2)
        keys(a, "esc", "/"); type("old"); keys(a, "ret")
        #expect(pg.here?.key == "l|a.ts|R:2" && pg.column == .left && pg.hereWord == 0..<1, "a removed line's old half")
        keys(a, "esc", "/"); type("a.ts"); keys(a, "ret")
        #expect(PageSearch.of(a).hits(a).isEmpty, "file headers aren't code")
        keys(a, "esc", "/"); type("hankles"); keys(a, "ret")
        #expect(PageSearch.of(a).hits(a).isEmpty, "neither are conversations")
    }

    /// `*` searches for the name under the cursor, from there; n goes to its next use.
    @Test func starSearchesTheNameUnderTheCursor() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "w")
        #expect(pg.here?.key == "l|a.ts|R:2" && pg.hereWord == 4..<5, "one (new is a keyword)")
        keys(a, "*")
        #expect(PageSearch.of(a).query == "one" && !PageSearch.of(a).typing && pg.hereWord == 4..<5, "stays on the name it searched")
    }

    /// The code beside the diff searches its text, not its line numbers, and lights its matches.
    @Test func slashSearchesTheCodeBesideTheDiff() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":1,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"alpha\nbeta 3\ngamma\nx alpha alpha"}"#)
        keys(a, "g", "d")
        await until("the side pane") { pg.sideText != nil }
        keys(a, "/", "3", "ret")
        #expect(PageSearch.of(a).hits(a).map(\.row) == ["s:2"], "the 3 in beta 3, not line 3")
        keys(a, "esc", "/", "a", "l", "p", "h", "a", "ret")
        #expect(a.pane?.id == reviewCodePane && a.selected == "s:4" && pg.sideHereWord == 2..<3, "the first alpha after where it began (line 2)")
        keys(a, "n")
        #expect(a.selected == "s:4" && pg.sideHereWord == 8..<9, "the second alpha on that line")
        keys(a, "n")
        #expect(a.selected == "s:1" && pg.sideHereWord == 0..<1, "wrapping to the top")
        #expect(PageSearch.of(a).tally(a) == (1, 3))
    }

    /// Ship's half, by key on the real page: `x` marks a range, `c` opens Ship's comment box on it.
    @Test func aShipCommandRunsByKeyOnTheReviewPage() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.key == "l|a.ts|R:2")
        keys(a, "x", "x")
        #expect(pg.range == ReviewLineRange(path: "a.ts", side: .right, line: 3, startLine: 2))
        keys(a, "c")
        guard case .line(_, let path, let side, let line, let start, _) = ShipState.of(a).composer else {
            Issue.record("no comment box: \(String(describing: ShipState.of(a).composer))"); return
        }
        #expect(path == "a.ts" && side == .right && line == 3 && start == 2)
        #expect(a.keys.mode == .insert && a.keys.fieldLines == .multi, "the comment box is many lines")
        #expect(!a.keys.handle("ret"), "↵ is a newline in the box, never a send")
        #expect(ShipState.of(a).composer != nil && a.keys.mode == .insert)
        #expect(ReviewDocument.segments(pg, a, CanvasColors(.dark)).contains { $0.key.contains("R:3") })
        keys(a, "esc", "esc")     // out of insert, then the box
        #expect(ShipState.of(a).composer == nil, "esc closes Ship's box")
    }

    @Test func theCommitsTabShowsTheSelectedCommitsDiff() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":1,"del":0,"patch":"@@ -1,0 +1,1 @@\n+hi"}]}"#)
        keys(a, "space", "2")
        #expect(pg.tab == "commits")
        pg.commitScopeChanged("c1")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        #expect(a.panes.map(\.id).contains(reviewDiffPane))
        pg.focusDiff(a, true)
        #expect(pg.here?.key == "l|c.ts|R:1")
        let words = try #require(a.panes.first { $0.id == ShipSeam.wordsPane })
        let diff = try #require(a.panes.first { $0.id == reviewDiffPane })
        #expect(diff.column == words.column && diff.row == words.row + 1, "the diff sits under the commit's words, as drawn")
        keys(a, "space", "3")
        #expect(pg.scoped && pg.files.map(\.path) == ["c.ts"], "the outline's scope carries into the files view")
        ShipState.of(a).showCommit(nil)
        #expect(pg.scoped == false && pg.files.map(\.path) == ["a.ts", "b.ts"], "= on main: the whole branch again")
    }

    /// The commit a branch's commits tab shows belongs to that branch: on the next branch nothing from
    /// the last one is still selected, so its tab opens on its own newest commit (2026-11-05: it opened blank).
    @Test func theShownCommitResetsWithTheBranch() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/commit-diff", #"{"sha":"c1","files":[{"path":"c.ts","add":1,"del":0,"patch":"@@ -1,0 +1,1 @@\n+hi"}]}"#)
        keys(a, "space", "2")
        ShipState.of(a).showCommit("c1")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        #expect(ShipState.of(a).commitScope == "c1")
        a.open(address: "canopy://v2/b/loops/hankles-next")
        await until("the next branch arrives") { pg.commitScope == nil }
        #expect(ShipState.of(a).commitScope == nil, "Ship reads the page's commit, never a copy left from the last branch")
    }

    @Test func anAddressLandsOnItsLineOnceTheDiffIsHereAndYCopiesItBack() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        a.open(address: "canopy://v2/b/loops/hankles-next?file=b.ts&line=6")
        #expect(a.router.route == .review(repo: "loops", branch: "hankles-next"))
        await until("the line") { pg.here?.key == "l|b.ts|R:6" }
        #expect(a.pane?.id == reviewDiffPane)
        keys(a, "y")
        #expect(Clipboard.text == "canopy://v2/b/loops/hankles-next?file=b.ts&line=6")
        keys(a, "Y")
        let words = Clipboard.text?.split(separator: "\n").map(String.init) ?? []
        #expect(words.first?.contains("hankles-next") == true, "the breadcrumb leads")
        #expect(words.dropFirst().first == "b.ts:6")
        #expect(words.last == "canopy://v2/b/loops/hankles-next?file=b.ts&line=6")
        keys(a, "C-o")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"), "following a link is a jump")
        pg.sync()   // the view does on a route change
        a.open(address: "/v2/b/loops/add-hankles-limited-label?file=b.ts")
        await until("the file") { a.selected == "f|b.ts" }
        a.open(address: "/v2/b/loops/add-hankles-limited-label?file=a.ts&line=10")
        await until("a line the diff hasn't, beside it") { pg.side?.line == 10 && pg.side?.sha == pg.tip }
    }

    @Test func anAddressesRowAnchorsTheCursorOnceTheDiffIsHere() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        a.open(address: "canopy://v2/b/loops/hankles-next?file=b.ts&line=6&row=4")
        await until("the line") { pg.here?.key == "l|b.ts|R:6" }
        #expect(pg.diffCanvas.canvas.anchor?.stop == "l|b.ts|R:6" && pg.diffCanvas.canvas.anchor?.row == 4)
        a.open(address: "canopy://v2/b/loops/hankles-next?file=b.ts&line=6")
        #expect(pg.diffCanvas.canvas.anchor == nil, "no row: the least move, as before")
        a.restore(Place(route: a.router.route, pane: reviewDiffPane, cursorKey: "l|b.ts|R:6", row: 2))
        #expect(pg.diffCanvas.canvas.anchor?.row == 2, "a jumplist entry on a diff that's here anchors at once")
    }

    @Test func theDiffsKeysKeepTheRules() async throws {
        let (a, _) = try await app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("review.") || $0.hasPrefix("inline.") } == [])
        for (id, verb) in ["review.file.next": Verb.nextFile, "review.hunk.next": .nextHunk, "review.conversation.next": .nextConversation, "review.comment.next": .nextComment,
                           "review.branch.next": .nextSibling, "review.parent": .parent, "review.filter": .find, "review.files": .changedFiles, "review.unviewed": .unmark, "review.match": .match] {
            #expect(a.registry.command(id)?.verbs == [verb], "\(id)")
        }
        #expect(a.registry.command("review.viewed")?.keys == [", m"])
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    /// A 6,000-line diff: stops, the canvas text and a key press stay quick.
    @Test func aBigDiffStaysQuick() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        var files: [JSONValue] = []
        for f in 0..<30 {
            var lines = ["@@ -1,200 +1,200 @@"]
            for i in 0..<200 { lines.append(i % 3 == 0 ? "+const v\(i): Widget = \"s\(i)\" // c" : i % 3 == 1 ? "-let x\(i) = \(i)" : " return foo(\(i))") }
            files.append(["path": .string("dir/f\(f).ts"), "add": 67, "del": 67, "patch": .string(lines.joined(separator: "\n"))])
        }
        pg.land(pg.keyOf, try JSONValue.object(["files": .array(files)]).decode(NodePayload.self))
        _ = p
        var t0 = Date()
        let n = pg.stops.count
        let stopsMs = Date().timeIntervalSince(t0) * 1000
        #expect(n > 6000)
        t0 = Date()
        let segs = ReviewDocument.segments(pg, a, CanvasColors(.dark))
        let text = NSMutableAttributedString()
        for s in segs { text.append(s.build()) }
        let buildMs = Date().timeIntervalSince(t0) * 1000
        t0 = Date()
        for _ in 0..<50 { a.keys.handle("j") }
        let keyMs = Date().timeIntervalSince(t0) * 1000 / 50
        t0 = Date()
        _ = ReviewDocument.segments(pg, a, CanvasColors(.dark))
        let segKeysMs = Date().timeIntervalSince(t0) * 1000
        func time(_ f: () -> Void) -> String { let t = Date(); for _ in 0..<20 { f() }; return String(format: "%.2f", Date().timeIntervalSince(t) * 50) }
        print("parts: stops \(time { _ = pg.stops }) panes \(time { _ = a.panes }) selected \(time { _ = a.selected }) here \(time { _ = pg.here }) scopes \(time { _ = a.liveScopes() }) views \(time { _ = pg.views }) threads \(time { _ = pg.threads })")
        print("big diff: \(n) stops in \(Int(stopsMs))ms · canvas text \(text.length) chars in \(Int(buildMs))ms · j \(String(format: "%.2f", keyMs))ms · segment keys \(Int(segKeysMs))ms")
        #expect(keyMs < 20)
        #expect(buildMs < 3000)
    }
}
