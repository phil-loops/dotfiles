import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct SyntaxSourceTests {
    let tip = "e1b98e2a133f5c4e82b6c74fb31efca5b5c3b233"
    let older = "1111111111111111111111111111111111111111"
    let path = "/loops/syntax/units"

    func answer(_ sha: String, name: String = "function one") -> String {
        #"{"ok":true,"sha":"\#(sha)","units":[{"line":1,"endLine":2,"name":"\#(name)","scope":1},{"line":3,"endLine":4,"name":"function two","scope":1}],"functions":[{"line":1,"endLine":4,"name":"\#(name)"}],"classes":[]}"#
    }

    func app() async throws -> (AppModel, Int) {
        try await ReviewPageTests().app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
    }

    @Test func syntaxRequestsTheNamedObjectAndQualifiesTheResponse() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app)
        ShipStub.answer(port, "POST", path, answer(tip))
        let syntax = await ReviewUnits.of(app).syntax(page, path: "a.ts")
        #expect(syntax?.functions.first?.name == "function one" && syntax?.unavailable == nil)
        let post = try #require(ShipStub.posts(port).first { $0.path == path })
        #expect(post.body["sha"] == .string(tip) && post.body["path"] == "a.ts" && post.body["branch"] == nil)
        #expect(ReviewUnits.Source(repo: "r", sha: String(tip.prefix(7)), path: "a.ts").accepts(tip))
        #expect(!ReviewUnits.Source(repo: "r", sha: tip, path: "a.ts").accepts(older))
    }

    @Test func aScopedDiffReadsItsOwnEndAndDoesNotBorrowTipGrouping() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
        ShipStub.answer(port, "POST", path, answer(tip))
        _ = await units.syntax(page, path: "a.ts")
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        page.commitScopeChanged(older)
        await until("the older syntax scope") { page.commitFiles?.sha == older }
        ShipStub.answer(port, "POST", path, answer(older, name: "historical function"))
        let historical = await units.syntax(page, path: "a.ts")
        #expect(historical?.functions.first?.name == "historical function")
        #expect(ShipStub.posts(port).filter { $0.path == path }.map { $0.body["sha"] } == [.string(tip), .string(older)])
        page.commitScopeChanged(nil)
        let current = await units.syntax(page, path: "a.ts")
        #expect(current?.functions.first?.name == "function one")
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 2)
    }

    @Test func aNewDisplayedDiffDerivesItsTouchedLinesFromTheSameImmutableSyntax() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
        ShipStub.answer(port, "POST", path, answer(tip))
        let original = try #require(await units.syntax(page, path: "a.ts"))
        #expect(!original.touched(original.functions).isEmpty)
        let scope = "main..\(tip)"
        ShipStub.answer(port, "GET", "/loops/commit-diff", #"{"files":[{"path":"a.ts","add":1,"del":1,"patch":"@@ -20,1 +20,1 @@\n-old\n+new"}]}"#)
        page.commitScopeChanged(scope)
        await until("same source, another diff") { page.commitFiles?.sha == scope }
        let different = try #require(await units.syntax(page, path: "a.ts"))
        #expect(different.changed == [20] && different.touched(different.functions).isEmpty)
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
    }

    @Test func mismatchedMissingOrMalformedEvidenceDoesNotPoisonASecondRead() async throws {
        let bad = [answer(older), answer(""), #"{"ok":true}"#,
                   #"{"ok":true,"sha":"\#(tip)","units":[],"functions":null,"classes":[]}"#,
                   #"{"ok":true,"sha":"\#(tip)","units":[],"functions":[{"line":0,"endLine":4,"name":"invalid"}],"classes":[]}"#]
        for reply in bad {
            let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
            ShipStub.answer(port, "POST", path, reply)
            #expect(await units.syntax(page, path: "a.ts") == nil)
            ShipStub.answer(port, "POST", path, answer(tip))
            #expect(await units.syntax(page, path: "a.ts")?.functions.first?.name == "function one")
            #expect(ShipStub.posts(port).filter { $0.path == path }.count == 2)
        }
    }

    @Test func unavailableAndFailedSyntaxKeepTheirReasonAndAreRetriedRatherThanCachedEmpty() async throws {
        for reply in [#"{"ok":false,"message":"grammar process failed"}"#,
                      #"{"ok":true,"units":null,"functions":null,"classes":null,"message":"no grammar for this file"}"#] {
            let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
            ShipStub.answer(port, "POST", path, reply)
            let unavailable = try #require(await units.syntax(page, path: "a.ts"))
            #expect(unavailable.unavailable?.contains("grammar") == true)
            ShipStub.answer(port, "POST", path, answer(tip))
            #expect(await units.syntax(page, path: "a.ts")?.functions.first?.name == "function one")
            #expect(ShipStub.posts(port).filter { $0.path == path }.count == 2)
        }
    }

    @Test func explicitEmptySyntaxIsAQualifiedReusableObservation() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
        ShipStub.answer(port, "POST", path, #"{"ok":true,"sha":"\#(tip)","units":[],"functions":[],"classes":[]}"#)
        let first = try #require(await units.syntax(page, path: "a.ts"))
        #expect(first.unavailable == nil && first.functions.isEmpty)
        _ = await units.syntax(page, path: "a.ts")
        #expect(ShipStub.posts(port).filter { $0.path == path }.count == 1)
    }

    @Test func aReplyForAPreviousScopeCannotBecomeTheCurrentDerivedSyntax() async throws {
        let (app, port) = try await app(), page = ReviewPageState.of(app), units = ReviewUnits.of(app)
        HeldLookupStub.hold(port, path)
        let task = Task { await units.syntax(page, path: "a.ts") }
        await until("held syntax") { HeldLookupStub.waiting(port, path) }
        ShipStub.answer(port, "GET", "/loops/commit-diff", ReviewPageTests.payload)
        page.commitScopeChanged(older)
        await until("changed scope") { page.commitFiles?.sha == older }
        HeldLookupStub.release(port, path, answer(tip))
        #expect(await task.value == nil)
        page.commitScopeChanged(nil)
        #expect(await units.syntax(page, path: "a.ts")?.functions.first?.name == "function one")
    }

    @Test func mutableNamesDoNotMasqueradeAsImmutableObjects() {
        for ref in ["HEAD", "main", "abcdef", "refs/stack/project-integration", "abcd123~1", ""] {
            #expect(!ReviewUnits.Source.objectName(ref))
        }
        #expect(ReviewUnits.Source.objectName(tip))
    }
}
