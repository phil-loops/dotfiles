import Testing
@testable import Show

/// Where a spoken review can start, and which canopy addresses count as one place on its trail.
struct SpokenReviewTests {
    @Test func aReviewStartsFromAForestOrABranchPage() {
        #expect(SpokenReview.scope(of: "/v2/p/loops/lock-user-delete")! == ("lock-user-delete", nil))
        #expect(SpokenReview.scope(of: "/v2/b/loops/feat/x?file=a.ts&line=4")! == (nil, "feat/x"), "a branch name keeps its slashes")
        #expect(SpokenReview.scope(of: "/v2/machine") == nil)
        #expect(SpokenReview.scope(of: "/v2/b/other/x") == nil, "only the loops repo's branches resolve to commits")
    }

    @Test func scrollingAndSplitsAreTheSamePlace() {
        #expect(SpokenReview.spot("/v2/b/loops/x?file=a.ts&line=4&row=12&win=1,0") == "/v2/b/loops/x?file=a.ts&line=4")
        #expect(SpokenReview.spot("/v2/b/loops/x?row=3") == "/v2/b/loops/x")
    }
}
