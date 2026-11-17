import Testing
@testable import CanopyUI

@MainActor struct OwnedValuesTests {
    @Test func aFailureOnlyRestoresItsOwnKeysIncludingClearedValues() {
        let values = OwnedValues<String, String>()
        values.set("a", "old")
        let receipt = values.stage([.init(key: "a", value: nil)])
        values.set("b", "new")
        values.rollback(receipt)
        #expect(values.values == ["a": "old", "b": "new"])
        values.rollback(receipt)
        #expect(values.values == ["a": "old", "b": "new"])
    }

    @Test func anOrdinaryEditRevokesOlderOwnershipEvenAfterAnEqualValueRoundTrip() {
        let values = OwnedValues<String, String>()
        values.set("a", "old")
        let receipt = values.stage([.init(key: "a", value: nil)])
        values.set("a", "new")
        values.set("a", nil)
        values.rollback(receipt)
        #expect(values.values["a"] == nil)
    }

    @Test func allThreeWriteOutcomesAndReplyOrdersPreserveTheLastAcceptedValue() {
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for accepted in 0..<8 {
            for order in orders {
                let values = OwnedValues<String, String>()
                values.set("a", "base")
                let receipts = (0..<3).map { values.stage([.init(key: "a", value: "\($0)")]) }
                for i in order {
                    if accepted & (1 << i) != 0 { values.accept(receipts[i]) }
                    else { values.rollback(receipts[i]) }
                }
                let latest = (0..<3).last { accepted & (1 << $0) != 0 }
                #expect(values.values["a"] == latest.map(String.init) ?? "base")
                for i in 0..<3 {
                    let previous = (0..<i).last { accepted & (1 << $0) != 0 }
                    #expect(values.before(receipts[i], "a") == previous.map(String.init) ?? "base")
                }
            }
        }
    }

    @Test func aReceiptCannotBeAppliedToAnotherStore() {
        let first = OwnedValues<String, String>()
        let second = OwnedValues<String, String>()
        first.set("a", "base")
        let receipt = first.stage([.init(key: "a", value: nil)])
        second.accept(receipt)
        second.rollback(receipt)
        #expect(second.before(receipt, "a") == nil)
        first.rollback(receipt)
        #expect(first.values["a"] == "base" && second.values.isEmpty)
    }

    @Test func independentPartsCanBeAcceptedOrRefusedSeparately() {
        let values = OwnedValues<String, String>()
        values.set("title", "S0"); values.set("body", "B0")
        let body = values.stage([.init(key: "body", value: "B1")])
        let title = values.stage([.init(key: "title", value: "S1")])
        values.rollback(body)
        values.accept(title)
        #expect(values.values == ["title": "S1", "body": "B0"])
        let undo = values.stage([.init(key: "title", value: "S0"), .init(key: "body", value: "B1")])
        values.rollback(undo, keys: ["body"])
        values.accept(undo, keys: ["title"])
        #expect(values.values == ["title": "S0", "body": "B0"])
    }

    @Test func aNewerPendingWriteKeepsItsBaselineWhenAnAncestorIsAccepted() {
        let values = OwnedValues<String, String>()
        let first = values.stage([.init(key: "a", value: "first")])
        let second = values.stage([.init(key: "a", value: "second")])
        values.accept(first)
        values.rollback(second)
        #expect(values.values["a"] == "first")
        #expect(values.before(second, "a") == "first")
    }

    @Test func aCanonicalReplyUpdatesItsDescendantsBaselineWithoutReplacingTheirValue() {
        let values = OwnedValues<String, String>()
        values.set("a", "old")
        let undo = values.stage([.init(key: "a", value: "old")])
        let newer = values.stage([.init(key: "a", value: "new")])
        values.accept(undo, replacing: [.init(key: "a", value: nil)])
        #expect(values.values["a"] == "new")
        values.rollback(newer)
        #expect(values.values["a"] == nil && values.before(newer, "a") == nil)
    }

    @Test func observationsOnlyRetireUnchangedValuesWhichWereAlreadyAccepted() {
        let values = OwnedValues<String, String>()
        values.set("stable", "value")
        values.set("aba", "value")
        let pending = values.stage([.init(key: "pending", value: "value")])
        let snapshot = values.snapshot()
        values.set("aba", "other"); values.set("aba", "value")
        values.set("new", "value")
        values.accept(pending)
        values.discardUnchanged(snapshot)
        #expect(values.values == ["aba": "value", "pending": "value", "new": "value"])
        let next = values.snapshot()
        let foreign = OwnedValues<String, String>()
        foreign.discardUnchanged(next)
        #expect(foreign.values.isEmpty && values.values.count == 3)
        values.discardUnchanged(next)
        #expect(values.values.isEmpty)
    }


    @Test func aReadOnlyReconcilesItsOwnKeysAndAHiddenCanonicalReplyKeepsANewerAcceptance() {
        let values = OwnedValues<String, String>()
        values.set("a", "A"); values.set("b", "B")
        let snapshot = values.snapshot()
        values.discardUnchanged(snapshot, keys: ["a"])
        #expect(values.values == ["b": "B"])
        let undo = values.stage([.init(key: "b", value: "B")])
        let newer = values.stage([.init(key: "b", value: "new")])
        values.accept(newer)
        values.accept(undo, replacing: [.init(key: "b", value: nil)])
        #expect(values.values["b"] == "new" && values.before(newer, "b") == nil)
    }


    @Test func pendingOwnershipIncludesANilValuedHeadUntilItIsAnsweredOrReplaced() {
        let values = OwnedValues<String, String>()
        let receipt = values.stage([.init(key: "a", value: nil)])
        #expect(values.isPending("a"))
        values.accept(receipt)
        #expect(!values.isPending("a"))
        let newer = values.stage([.init(key: "a", value: nil)])
        values.set("a", nil)
        #expect(!values.isPending("a"))
        values.rollback(newer)
        #expect(!values.isPending("a") && values.values["a"] == nil)
    }

}
