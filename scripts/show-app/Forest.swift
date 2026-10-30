import AppKit

/// A forest deck's reading order: sections with no `rank` (the merge story, live pages) first in file order,
/// then branches by rank, parent and file order, numbered by rank (tied siblings share a number) and nested under a parent in the deck.
struct ForestOrder {
    let overview: [Int]
    let branches: [(index: Int, number: Int, depth: Int)]

    init(_ deck: Deck) {
        let sections = deck.sections
        overview = sections.indices.filter { sections[$0].rank == nil }
        let ranked = sections.indices.filter { sections[$0].rank != nil }
            .sorted { a, b in
                let (x, y) = (sections[a], sections[b])
                return (x.rank ?? 0, x.parent ?? "", a) < (y.rank ?? 0, y.parent ?? "", b)
            }
        let numbers = Dictionary(uniqueKeysWithValues: Set(ranked.compactMap { sections[$0].rank }).sorted().enumerated().map { ($1, $0 + 1) })
        let byID = Dictionary(ranked.map { (sections[$0].key, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ index: Int, _ seen: Set<Int> = []) -> Int {
            guard let parent = sections[index].parent, let up = byID[parent], up != index, !seen.contains(up) else { return 0 }
            return depth(up, seen.union([index])) + 1
        }
        branches = ranked.map { ($0, numbers[sections[$0].rank ?? 0] ?? 0, depth($0)) }
    }
}

let forestTint = NSColor(name: "show.forest") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0xA4 / 255, green: 0xBC / 255, blue: 0xAE / 255, alpha: 1)
        : NSColor(srgbRed: 0x5A / 255, green: 0x75 / 255, blue: 0x66 / 255, alpha: 1)
}

/// The command ⌘⇧O runs for a branch section: `canopy /v2/b/<repo>/<branch>` (`SHOW_CANOPY` swaps the binary); nil for a non-branch.
func canopyCommand(_ deck: Deck, _ section: Section) -> [String]? {
    guard section.rank != nil, let repo = deck.repo, !repo.isEmpty else { return nil }
    let binary = ProcessInfo.processInfo.environment["SHOW_CANOPY"] ?? ("~/.dotfiles/scripts/canopy" as NSString).expandingTildeInPath
    return [binary, "/v2/b/\(repo)/\(section.key)"]
}
