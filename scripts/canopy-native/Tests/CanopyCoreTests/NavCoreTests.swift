import Foundation
import Testing
@testable import CanopyCore

@Suite struct LabelAssignmentTests {
    func spots(_ pane: String, _ n: Int, x: Double = 0) -> [Labels.Spot] {
        (0..<n).map { Labels.Spot(pane: pane, key: "\(pane)\($0)", x: x, y: Double($0) * 20) }
    }

    @Test func oneCharacterUpToTen() {
        let s = spots("left", 4) + spots("right", 6, x: 300)
        let l = Labels.assign(s, paneOrder: ["left", "right"])
        #expect(l.compactMap { $0 } == ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"])
    }

    @Test func positionNotInputOrderDecides() {
        let s = [Labels.Spot(pane: "p", key: "low", x: 0, y: 100), Labels.Spot(pane: "p", key: "high", x: 0, y: 10),
                 Labels.Spot(pane: "p", key: "right", x: 50, y: 10)]
        #expect(Labels.assign(s) == ["d", "a", "s"])
    }

    @Test func twoCharactersPastTenAndTheFirstPicksThePane() {
        let s = spots("left", 3) + spots("right", 12, x: 300)
        let l = Labels.assign(s, paneOrder: ["left", "right"])
        #expect(Array(l[0..<3]) == ["aa", "as", "ad"])
        #expect(l[3] == "sa" && l[14] == "sw")
        #expect(Set(l.compactMap { $0 }).count == 15)
    }

    @Test func aPanesLabelsDontMoveWhenAnotherPaneChanges() {
        let before = Labels.assign(spots("left", 8) + spots("right", 12, x: 300), paneOrder: ["left", "right"])
        let after = Labels.assign(spots("left", 3) + spots("right", 12, x: 300), paneOrder: ["left", "right"])
        #expect(Array(before[8...]) == Array(after[3...]))
        #expect(Labels.assign(spots("x", 30)) == Labels.assign(spots("x", 30)), "same screen, same labels")
    }

    @Test func aBigPaneGetsWiderLabels() {
        let l = Labels.assign(spots("p", 45))
        #expect(l.allSatisfy { $0?.count == 3 })
        #expect(Set(l.compactMap { $0 }).count == 45)
        #expect(l.allSatisfy { $0?.first == "a" })
    }
}

@MainActor @Suite struct JumplistTests {
    func at(_ k: String) -> Place { Place(route: .forests, pane: "main", cursorKey: k) }

    @Test func backAndForwardRestoreExactly() {
        let j = Jumplist()
        j.record(at("a"))
        j.record(at("b"))
        #expect(j.goBack(from: at("c")) == at("b"))
        #expect(j.goBack(from: at("b")) == at("a"))
        #expect(j.goBack(from: at("a")) == nil)
        #expect(j.goForward(from: at("a")) == at("b"))
        #expect(j.goForward(from: at("b")) == at("c"))
        #expect(j.goForward(from: at("c")) == nil)
    }

    @Test func aNewJumpTruncatesTheForwardList() {
        let j = Jumplist()
        j.record(at("a")); j.record(at("b"))
        _ = j.goBack(from: at("c"))
        _ = j.goBack(from: at("b"))
        #expect(j.fwd.count == 2)
        j.record(at("a"))
        #expect(j.fwd.isEmpty)
        #expect(j.back.map(\.cursorKey) == ["a"])
    }

    @Test func identicalNeighboursCollapseAndHereIsSkipped() {
        let j = Jumplist()
        j.record(at("a")); j.record(at("a"))
        #expect(j.back.count == 1)
        var scrolled = at("a"); scrolled.row = 40
        j.record(scrolled)
        #expect(j.back.count == 1 && j.back[0].row == 40, "the row alone isn't a new spot; the newer one wins")
        j.save(at("b"))
        #expect(j.goBack(from: at("b")) == scrolled, "C-s at b then C-o from b skips b")
    }

    @Test func alternateIsWhereTheLastJumpLeftFrom() {
        let j = Jumplist()
        j.record(at("a"))
        #expect(j.alternate == at("a"))
        j.save(at("z"))
        #expect(j.alternate == at("a"), "a manual save isn't a jump")
    }

    @Test func placeFields() {
        let p = Place(route: .review(repo: "loops", branch: "a/b", base: "main"), tab: "files")
        #expect(p.surface == "review" && p.arg == "loops/a/b" && p.base == "main")
    }

    @Test func anAddressIsAPlaceWrittenOut() {
        let review = Route.review(repo: "loops", branch: "a/b", base: "main")
        let line = Place(route: review, pane: "review.diff", tab: "files",
                         loc: Loc(repo: "loops", sha: "abc", path: "src/x y+z.ts", line: 12, diffKey: "l|src/x y+z.ts|r12"))
        #expect(line.address == "/v2/b/loops/a/b?base=main&file=src/x%20y%2Bz.ts&line=12")
        let back = Place(address: line.link)
        #expect(back.route == review)
        #expect(back.loc == Loc(repo: "loops", sha: "", path: "src/x y+z.ts", line: 12))

        let beside = Place(route: review, loc: Loc(repo: "loops", sha: "def", path: "a.ts", line: 3))
        #expect(Place(address: beside.address).loc?.sha == "def", "a line at another commit says which")

        #expect(Place(address: "/v2/b/loops/x?file=a.ts").cursorKey == "f|a.ts")
        #expect(Place(address: "canopy://v2/b/loops/x?thread=t9").cursorKey == "t|t9")
        let commits = Place(address: "/v2/b/loops/x?tab=commits&at=c|abc")
        #expect(commits.tab == "commits" && commits.cursorKey == "c|abc")
        #expect(commits.address == "/v2/b/loops/x?tab=commits&at=c%7Cabc")
        #expect(Place(route: .forests).address == "/v2")
    }

    @Test func anAddressCarriesTheCursorsRowOnScreen() {
        var p = Place(route: .review(repo: "loops", branch: "x"), loc: Loc(repo: "loops", sha: "", path: "a.ts", line: 4))
        p.row = 17
        #expect(p.address == "/v2/b/loops/x?file=a.ts&line=4&row=17")
        #expect(Place(address: p.link).row == 17)
        #expect(Place(address: "/v2/b/loops/x?file=a.ts&line=4").row == nil, "no row unless it's said")
        #expect(Place(address: "/v2/b/loops/x?at=c%7Cabc").address == "/v2/b/loops/x?at=c%7Cabc")
    }
}

@Suite struct FrecencyTests {
    @Test func recentBeatsFrequentOld() {
        var f = Frecency()
        let now = Date()
        for _ in 0..<5 { f.visit("old", at: now.addingTimeInterval(-30 * 86400)) }
        f.visit("new", at: now)
        #expect(f.score("new", now: now) == 4)
        #expect(f.score("old", now: now) == 1.25)
        #expect(f.rank(["old", "new", "never"], "", id: { $0 }, text: { $0 }, now: now) == ["new", "old", "never"])
    }

    @Test func aCloseMatchBeatsFrecency() {
        var f = Frecency()
        f.visit("loops:x-y-z-scattered")
        let r = f.rank(["loops:x-y-z-scattered", "loops:xyz"], "xyz", id: { $0 }, text: { $0 })
        #expect(r == ["loops:xyz", "loops:x-y-z-scattered"])
    }

    @Test func agingKeepsTheTotalUnderTheCap() {
        var f = Frecency()
        f.cap = 10
        for i in 0..<30 { f.visit("b\(i % 3)") }
        #expect(f.entries.values.reduce(0) { $0 + $1.rank } <= 10)
    }

    @Test func seedsFromTheUsageLog() {
        var f = Frecency()
        f.seed(jsonl: """
        {"type": "cmd", "id": "branch.open", "target": "loops:a", "ts": 100}
        {"type": "cmd", "id": "review.down", "target": "loops:a", "ts": 101}
        {"type": "cmd", "id": "review.down", "target": "loops:a", "ts": 102}
        {"type": "nav", "from": "review", "to": "review", "path": "/v2/b/loops/b", "ts": 103}
        {"type": "cmd", "id": "project.focus", "target": "loops:proj", "ts": 104}
        {"type": "cmd", "id": "branch.open", "target": "loops:a", "ts": 105}
        not json
        """)
        #expect(f.entries["loops:a"]?.rank == 2, "a run of events on one branch is one visit")
        #expect(f.entries["loops:b"]?.rank == 1)
        #expect(f.entries["loops:proj"] == nil)
        #expect(f.latest(["loops:a", "loops:b"]) == "loops:a")
    }
}
