import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite struct ComposerTests {
    static let otherBranch = "loops:another-branch"

    final class Host: ShipHost {
        var tab = "conversation"
        var commitScope: String?
        func lineRange(_ app: AppModel) -> ShipLineRange? { ShipLineRange(path: "a.ts", side: .right, line: 4) }
        func newLines(_ app: AppModel, path: String, from: Int, to: Int) -> [String] { [] }
        func showThread(_ app: AppModel, id: String) {}
        func commitScopeChanged(_ sha: String?) { commitScope = sha }
        var wholeBranch: Bool { true }
        func clearMark() {}
    }

    func app() throws -> (AppModel, Int) {
        let result = try ShipTests().app { state in
            var entities = state["entities"]!.object!
            for type in ["branch", "conv", "draft"] {
                var table = entities[type]!.object!
                var other = table[ShipTests.branch]!.object!
                other["id"] = .string(Self.otherBranch)
                other[type == "branch" ? "name" : "branch"] = "another-branch"
                table[Self.otherBranch] = .object(other)
                entities[type] = .object(table)
            }
            state["entities"] = .object(entities)
        }
        let ship = ShipState.of(result.0)
        ship.host = Host()
        return result
    }

    func comment(_ app: AppModel, text: String) throws -> ShipComposer {
        app.runner.dispatch("review.comment", via: .key, target: "l|a.ts|R:4")
        let composer = try #require(ShipState.of(app).composer)
        ShipState.of(app).setText(composer.key, text)
        app.keys.handle("esc")
        return composer
    }

    @Test func lineDraftsAndActiveComposersBelongToTheirBranch() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        let original = try comment(a, text: "first branch")
        a.router.navigate(.review(repo: "loops", branch: "another-branch"))
        #expect(ship.composer == nil)
        let other = try comment(a, text: "second branch")
        #expect(other.key != original.key)
        a.router.navigate(.review(repo: "loops", branch: "add-hankles-limited-label"))
        #expect(ship.composer == original && ship.text(original.key) == "first branch")
        a.router.navigate(.review(repo: "loops", branch: "another-branch"))
        #expect(ship.composer == other && ship.text(other.key) == "second branch")
    }

    @Test func aRefusedSaveRecoversItsOwnDraftWithoutReplacingAnotherBranchsComposer() async throws {
        let (a, port) = try app()
        let ship = ShipState.of(a)
        ShipStub.answer(port, "POST", "/loops/review-draft", #"{"ok":false,"err":"not saved"}"#)
        let original = try comment(a, text: "first branch")
        a.runner.dispatch("review.compose.draft", via: .key, target: ShipTests.branch)
        a.router.navigate(.review(repo: "loops", branch: "another-branch"))
        let other = try comment(a, text: "second branch")
        await until("the original words recovered") { ship.text(original.key) == "first branch" }
        #expect(ship.composer == other && ship.text(other.key) == "second branch")
        a.router.navigate(.review(repo: "loops", branch: "add-hankles-limited-label"))
        #expect(ship.composer == original)
    }

    @Test func recoveryDoesNotOverwriteNewerWordsAtTheSamePlace() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        let original = try comment(a, text: "older words")
        let recovery = ship.clearComposer(original, on: ShipTests.branch)
        let newer = try comment(a, text: "newer words")
        ship.restoreComposer(recovery)
        #expect(ship.composer == newer && ship.text(newer.key) == "newer words")
    }

    @Test func recoveryKeepsTheWordsWithoutReplacingANewerBox() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        let original = try comment(a, text: "older words")
        let recovery = ship.clearComposer(original, on: ShipTests.branch)
        let newer = ShipComposer.reply(key: "another-reply", threadID: "another-thread")
        ship.composer = newer
        ship.setText(newer.key, "new reply")
        ship.restoreComposer(recovery)
        #expect(ship.text(original.key) == "older words")
        #expect(ship.composer == newer && ship.text(newer.key) == "new reply")
    }

    @Test func explicitlyDiscardedWordsAreNotResurrectedByRecovery() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        let original = try comment(a, text: "discard me")
        let recovery = ship.clearComposer(original, on: ShipTests.branch)
        _ = try comment(a, text: "")
        a.runner.dispatch("review.compose.cancel", via: .key, target: ShipTests.branch)
        ship.restoreComposer(recovery)
        #expect(ship.composer == nil && ship.text(original.key).isEmpty)
    }

    @Test(arguments: [nil, "commit123"] as [String?])
    func olderUnownedWordsNeedExplicitRecovery(_ sha: String?) throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        ship.host.commitScopeChanged(sha)
        let key = "\(sha.map { "n|\($0)" } ?? "c")|a.ts|RIGHT|4|"
        ship.defaults.set("words from an earlier version", forKey: "canopy.ship.text.\(key)")
        let current = try comment(a, text: "")
        #expect(ship.text(current.key).isEmpty)
        #expect(ship.olderComposerText == "words from an earlier version")
        a.runner.dispatch("review.compose.recover", via: .key, target: ShipTests.branch)
        #expect(ship.text(current.key) == "words from an earlier version")
        #expect(ship.text(key).isEmpty && ship.olderComposerText == nil)
        a.router.navigate(.review(repo: "loops", branch: "another-branch"))
        let other = try comment(a, text: "")
        #expect(ship.text(other.key).isEmpty && ship.olderComposerText == nil)
    }

    @Test func recoveringOlderWordsDoesNotOverwriteTheCurrentDraft() throws {
        let (a, _) = try app()
        let ship = ShipState.of(a)
        ship.defaults.set("older words", forKey: "canopy.ship.text.c|a.ts|RIGHT|4|")
        let current = try comment(a, text: "keep this draft")
        a.runner.dispatch("review.compose.recover", via: .key, target: ShipTests.branch)
        #expect(ship.text(current.key) == "keep this draft")
        #expect(ship.olderComposerText == "older words")
    }
}
