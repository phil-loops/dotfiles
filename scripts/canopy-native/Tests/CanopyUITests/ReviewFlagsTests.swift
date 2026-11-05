import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite struct ReviewFlagsTests {
    @Test func noReviewYetIsAskedAgainAndAReviewOnceRunIsKept() async throws {
        let (a, port) = try ShipTests().app()
        let t = ReviewPageState.Target(repo: "loops", name: "add-hankles-limited-label", id: ShipTests.branch)
        let flags = ReviewFlags.of(a)
        ShipStub.answer(port, "GET", "/loops/review-flags", #"{"flags":null}"#)
        #expect(await flags.load(a, t) == nil)
        ShipStub.answer(port, "GET", "/loops/review-flags", #"{"flags":[{"path":"a.ts","line":3,"text":"why"}]}"#)
        #expect(await flags.load(a, t)?.map(\.text) == ["why"], "a review that lands after the first look shows on the same tip")
        ShipStub.answer(port, "GET", "/loops/review-flags", #"{"flags":null}"#)
        #expect(await flags.load(a, t)?.map(\.text) == ["why"], "once run, a tip's review is read once")
    }
}
