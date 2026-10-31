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

    /// The keys are the server's: they must be exactly the web app's (node over review/diff.ts).
    @Test func blockKeysAreTheWebAppsBitForBit() {
        #expect(Self.keys(Self.narrow) == ["1ax3zbksxx", "1ru9mehgcvd"])
        #expect(blocksOf(parsePatch("dir/ünï €.ts", "@@ -1,1 +1,1 @@\n-𝒳 old\n+new 😀 é")).map(\.key) == ["1o2so8t1nlx"])
        var bin = parsePatch("img.png", "")
        bin.status = .binary
        #expect(blocksOf(bin).map(\.key) == ["pkzjdhyy6l"])
        let twice = ["@@ -1,3 +1,3 @@", " a", "-c", "+C", " b", "@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].joined(separator: "\n")
        #expect(Self.keys(twice) == ["1ax3zbksxx", "1ax3zbksxx.1"])
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
    func app() async throws -> (AppModel, Int) {
        Self.nextPort += 1
        let p = Self.nextPort
        ShipStub.answer(p, "GET", "/loops/node", Self.payload)
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

    @Test func theDiffLandsWithTheCursorOnItsFirstLine() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        #expect(pg.here?.key == "l|a.ts|R:1")
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
        keys(a, "j")
        #expect(pg.here?.key == "l|a.ts|R:2", "split: the changed pair is one row, keyed by its new line")
        keys(a, "}")
        #expect(pg.here?.key == "l|a.ts|R:22", "the next hunk's first changed line")
        keys(a, "{")
        #expect(pg.here?.key == "l|a.ts|R:2")
        keys(a, "]")
        #expect(pg.here?.key == "f|b.ts")
        keys(a, "[")
        #expect(pg.here?.key == "f|a.ts")
        keys(a, "n")
        #expect(pg.here?.key == "t|\(Self.branch)#T1")
        #expect(a.liveScopes().contains(.thread))
        keys(a, "G")
        #expect(pg.here?.key == pg.stops.last?.key)
        keys(a, "g", "g")
        #expect(pg.here?.key == pg.stops.first?.key)
    }

    @Test func jumpsComeBackWithCtrlO() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "]")
        #expect(pg.here?.key == "f|b.ts")
        keys(a, "C-o")
        #expect(pg.here?.key == "l|a.ts|R:1")
        keys(a, "C-i")
        #expect(pg.here?.key == "f|b.ts")
    }

    @Test func mMarksTheHunkViewedAndMovesOnMUnmarks() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true,"count":1,"on":true}"#)
        let hunk0 = pg.fileOf("a.ts")!.blocks.filter { $0.hunk == 0 }.map(\.key)
        keys(a, "m")
        #expect(hunk0.allSatisfy(pg.isSeen))
        #expect(pg.here?.key == "l|a.ts|R:22", "on to the next unviewed hunk")
        await until("the post") { ShipStub.posts(p).contains { $0.path == "/loops/viewed" } }
        let post = ShipStub.posts(p).last { $0.path == "/loops/viewed" }!
        #expect(post.body["on"] == .bool(true))
        #expect(post.body["keys"] == .array(hunk0.map(JSONValue.string)))
        // the last hunk of a.ts: m finishes the file and moves to b.ts
        keys(a, "m")
        #expect(pg.fileOf("a.ts")!.viewed)
        #expect(pg.here?.key == "f|b.ts")
        #expect(!pg.stops.contains { $0.key == "l|a.ts|R:1" }, "a viewed file folds")
        keys(a, "[")
        keys(a, "M")
        #expect(!pg.fileOf("a.ts")!.viewed)
    }

    @Test func selectModeMarksEveryHunkInTheRange() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "POST", "/loops/viewed", #"{"ok":true}"#)
        keys(a, "v", "}", "m")
        #expect(a.keys.mode == .normal)
        #expect(pg.fileOf("a.ts")!.viewed)
    }

    @Test func JAndKWalkTheStackStayingOnReview() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        ShipStub.answer(p, "GET", "/loops/node", Self.payload)
        keys(a, "]")      // on b.ts
        keys(a, "K")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"), "nothing before the first")
        keys(a, "J")
        #expect(a.router.route == .review(repo: "loops", branch: "hankles-next"))
        await until("the neighbour's diff") { pg.payload?.key.hasPrefix("loops:hankles-next@") == true }
        #expect(pg.here?.key == "f|b.ts", "the same file, since the neighbour touches it")
        keys(a, "g", "k")
        #expect(a.router.route == .review(repo: "loops", branch: "add-hankles-limited-label"))
    }

    @Test func minusClimbsToTheForestWithTheBranchUnderTheCursor() async throws {
        let (a, _) = try await app()
        keys(a, "-")
        #expect(a.router.route == .forest(repo: "loops", project: "hankles-limited-label"))
        #expect(a.selected == RowKey.branch(Self.branch))
    }

    /// h / l move across what you see: the old and new halves of a split line, then the pane beside.
    @Test func hAndLCrossTheSplitThenThePanes() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        keys(a, "j")
        #expect(pg.here?.key == "l|a.ts|R:2" && pg.range?.side == .right)
        keys(a, "h")
        #expect(pg.column == .left && pg.range?.side == .left && a.pane?.id == reviewDiffPane, "the old half of the same row")
        keys(a, "h")
        #expect(pg.column == .left && a.pane?.id == reviewTreePane, "past the old half, the files list to its left")
        keys(a, "l")
        #expect(pg.column == .left && a.pane?.id == reviewDiffPane, "back on the old half")
        keys(a, "l")
        #expect(pg.column == .right && pg.range?.side == .right)
        pg.open(Loc(repo: "loops", sha: "zzz", path: "other.ts", line: 4))
        keys(a, "h")
        #expect(a.pane?.id == reviewDiffPane, "from the code beside the diff, h is the diff")
        keys(a, "l")
        #expect(a.pane?.id == reviewCodePane, "past the new half, l is the code beside it")
    }

    @Test func escOnlyCancels() async throws {
        let (a, _) = try await app()
        let pg = ReviewPageState.of(a)
        pg.open(Loc(repo: "loops", sha: "zzz", path: "other.ts", line: 4))
        #expect(pg.side != nil && a.pane?.id == reviewCodePane)
        keys(a, "esc")
        #expect(pg.side == nil && a.pane?.id == reviewDiffPane)
        keys(a, "esc")
        #expect(a.router.route.surfaceID == "review")
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

    @Test func gdGoesInTheDiffOrBesideIt() async throws {
        let (a, p) = try await app()
        let pg = ReviewPageState.of(a)
        let tip = pg.tip
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"b.ts","line":6,"character":0}]}"#)
        keys(a, "g", "d")
        await until("the jump") { pg.here?.key == "l|b.ts|R:6" }
        let ask = ShipStub.posts(p).last { $0.path == "/loops/lsp/definition" }!
        #expect(ask.body["branch"] == "add-hankles-limited-label" && ask.body["path"] == "a.ts" && ask.body["line"] == 1)
        keys(a, "C-o")
        #expect(pg.here?.key == "l|a.ts|R:1")
        // somewhere the diff doesn't show: beside it, at the commit
        ShipStub.answer(p, "POST", "/loops/lsp/definition", #"{"ok":true,"sha":"\#(tip)","locations":[{"path":"lib/z.ts","line":2,"character":0}]}"#)
        ShipStub.answer(p, "GET", "/loops/lsp/src", #"{"path":"lib/z.ts","sha":"x","text":"one\ntwo\nthree"}"#)
        keys(a, "g", "d")
        await until("the side pane") { pg.sideText != nil }
        #expect(pg.side?.path == "lib/z.ts" && a.selected == "s:2")
        #expect(ReviewSurface().title(for: "s:2", a) == "2 two")
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
        #expect(a.nav.picker != nil)
        a.nav.typed("new two")
        keys(a, "ret")
        #expect(ReviewPageState.of(a).here?.key == "l|a.ts|R:3")
    }

    /// Ship's half, by key on the real page: `x` marks a range, `c` opens Ship's comment box on it.
    @Test func aShipCommandRunsByKeyOnTheReviewPage() async throws {
        let (a, _) = try await app()
        keys(a, "j")          // a.ts R:2 (new one), paired with what it replaced
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
        keys(a, "2")
        #expect(pg.tab == "commits")
        ShipState.of(a).commitScope = "c1"
        pg.commitScopeChanged("c1")
        await until("the commit's diff") { pg.files.map(\.path) == ["c.ts"] }
        #expect(a.panes.map(\.id).contains(reviewDiffPane))
        pg.focusDiff(a, true)
        #expect(pg.here?.key == "l|c.ts|R:1")
        keys(a, "3")
        #expect(pg.scoped == false && pg.files.map(\.path) == ["a.ts", "b.ts"])
    }

    @Test func theDiffsKeysKeepTheRules() async throws {
        let (a, _) = try await app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("review.") || $0.hasPrefix("inline.") } == [])
        for (id, verb) in ["review.file.next": Verb.nextFile, "review.hunk.next": .nextHunk, "review.thread.next": .nextThread,
                           "review.branch.next": .nextSibling, "review.parent": .parent, "review.filter": .find, "review.unviewed": .unmark] {
            #expect(a.registry.command(id)?.verbs == [verb], "\(id)")
        }
        #expect(a.registry.command("review.viewed")?.keys == ["m"])
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
