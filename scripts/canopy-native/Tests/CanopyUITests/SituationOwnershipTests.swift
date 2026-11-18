import Foundation
import Testing

/// Where a branch stands and what's next is derived once (`ShipRules.stand`): the push rules it composes are read only
/// by the derivation and the few places that make it, so no surface can grow a second answer.
struct SituationOwnershipTests {
    static let allowed: [String: Set<String>] = [
        "ShipRules.stand(": ["Pages/Forests/Ship.swift", "Pages/Forests/ForestModel.swift", "Pages/Forests/BranchCommands.swift"],
        "canPush(": ["Pages/Forests/Ship.swift", "Pages/Forests/BranchCommands.swift"],
        "pushableButGates(": ["Pages/Forests/Ship.swift"],
        "gatesAdvise(": ["Pages/Forests/Ship.swift", "Pages/Forests/BranchCommands.swift", "Pages/Forests/Loop.swift"],
    ]

    @Test func onlyTheDerivationReadsThePushRules() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/CanopyUI").standardized
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var strays: [String] = []
        for file in files {
            let rel = String(file.standardized.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            for (needle, owners) in Self.allowed where text.contains(needle) && !owners.contains(rel) { strays.append("\(rel): \(needle)") }
        }
        #expect(strays.isEmpty, "read the branch's Stand (actor, next, ready) instead: \(strays)")
    }
}
