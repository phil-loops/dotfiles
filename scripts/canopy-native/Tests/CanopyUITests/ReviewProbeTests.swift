import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// Adversarial probes of the motion rules: odd diffs, odd text, odd modes.
@MainActor @Suite(.serialized) struct ReviewProbeTests {
    let base = ReviewPageTests()
    func payload(_ files: [(String, String)]) -> String {
        let fs: JSONValue = .array(files.map { ["path": .string($0.0), "add": 1, "del": 1, "patch": .string($0.1)] })
        let o: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123", "files": fs]
        return String(decoding: try! JSONEncoder().encode(o), as: UTF8.self)
    }
    func keys(_ a: AppModel, _ ks: String...) { for k in ks { a.keys.handle(k) } }

    @Test func theColumnSurvivesRowsWithoutCode() async throws {
        let (a, _) = try await base.app()
        let pg = ReviewPageState.of(a)
        keys(a, "l", "l", "l")
        let col = try #require(pg.hereWord?.lowerBound)
        var guardN = 0
        while pg.here?.kind != .thread && guardN < 10 { keys(a, "j"); guardN += 1 }
        #expect(pg.here?.kind == .thread)
        keys(a, "j")
        #expect(pg.here?.kind == .line && pg.hereWord?.lowerBound == col, "past the conversation, the same column: \(String(describing: pg.hereWord)) want \(col)")
    }

    @Test func lNeverSplitsACharacter() async throws {
        let (a, _) = try await base.app(payload([("e.ts", ["@@ -1,1 +1,1 @@", "-a", "+s = \"😀é x\";"].joined(separator: "\n"))]))
        let pg = ReviewPageState.of(a)
        let text = try #require(pg.here?.row?.right?.text) as NSString
        for _ in 0..<12 {
            keys(a, "l")
            guard let w = pg.hereWord else { break }
            let whole = text.rangeOfComposedCharacterSequence(at: w.lowerBound)
            #expect(whole.location == w.lowerBound && whole.length == w.count, "a whole character: \(w) inside \(whole)")
        }
    }

    @Test func theOldHalfIsOnlyWhereALineWasRemoved() async throws {
        let (a, _) = try await base.app()
        let pg = ReviewPageState.of(a)
        var n = 0
        while pg.range?.side != .left && n < 20 { keys(a, "h"); n += 1 }   // onto the old half of R:2
        #expect(pg.range?.side == .left)
        var guardN = 0
        while !(pg.here?.row.map { $0.left?.kind == .ctx } ?? false) && guardN < 10 { keys(a, "j"); guardN += 1 }
        #expect(pg.range?.side == .right, "on an unchanged line the old half reads the same: the cursor is on the new one")
    }

    @Test func everyFileViewedStillMovesAndSays() async throws {
        let (a, _) = try await base.app()
        let pg = ReviewPageState.of(a)
        for f in pg.files { pg.viewedOverride[f.path] = true }
        for k in ["g g", "G", "]", "[", "}", "{", "j", "k", "h", "l", "n"] {
            let before = pg.here?.key
            for part in k.split(separator: " ") { keys(a, String(part)) }
            #expect(pg.here?.key != before || a.runner.note != nil, "\(k) with every file viewed: did nothing, said nothing")
        }
    }

    @Test func anEmptyDiffSaysSo() async throws {
        let (a, _) = try await base.app(payload([]))
        for k in ["g g", "G", "]", "}", "j", "h", "l", "n"] {
            let before = a.runner.note
            for part in k.split(separator: " ") { keys(a, String(part)) }
            #expect(a.runner.note != nil && a.runner.note != before || a.runner.note != nil, "\(k) on an empty diff said nothing")
        }
    }

    @Test func aDeletedFilesLinesWalkByCharacter() async throws {
        let (a, _) = try await base.app(payload([("gone.ts", ["@@ -1,2 +0,0 @@", "-first line", "-second"].joined(separator: "\n"))]))
        let pg = ReviewPageState.of(a)
        keys(a, "l")
        #expect(pg.hereWord == 0..<1 && pg.range?.side == .left, "a deleted file is all old half: \(String(describing: pg.hereWord))")
        keys(a, "l", "j")
        #expect(pg.hereWord == 1..<2)
    }

    @Test func selectModeJumpsExtend() async throws {
        let (a, _) = try await base.app()
        let pg = ReviewPageState.of(a)
        let start = pg.here?.key
        keys(a, "v", "}")
        #expect(a.keys.mode == .select && a.selection.contains(start ?? "") && a.selection.contains(pg.here?.key ?? "-"), "} in select mode extends from where it began: \(a.selection)")
    }

    @Test func aClickPutsTheCursorOnTheHalfAndCharacterClicked() async throws {
        let (a, _) = try await base.app()
        let pg = ReviewPageState.of(a)
        a.runner.dispatch("review.cursor.set", via: .click, target: "l|a.ts|R:2", arg: false)
        pg.click("l|a.ts|R:2", side: .left, at: 2)
        #expect(pg.range?.side == .left && pg.hereWord == 2..<3, "the removed line's old half, its third character")
        a.runner.dispatch("review.cursor.set", via: .click, target: "l|a.ts|R:1", arg: false)
        pg.click("l|a.ts|R:1", side: .left, at: 1)
        #expect(pg.range?.side == .right && pg.hereWord == 1..<2, "an unchanged line's old half reads the same: the new half")
        a.keys.handle("l")
        #expect(pg.hereWord == 2..<3, "and l goes on from the character clicked")
    }
}
