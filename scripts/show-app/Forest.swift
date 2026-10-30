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

/// Where a forest deck's repo is checked out: its `repoPath`, else `~/coding/loops` for `"repo": "loops"`.
func repoCheckout(_ deck: Deck) -> String? {
    if let path = deck.repoPath, !path.isEmpty { return (path as NSString).expandingTildeInPath }
    return deck.repo == "loops" ? ("~/coding/loops" as NSString).expandingTildeInPath : nil
}

/// Each branch section's current tip, read with `git rev-parse` off the main thread and cached; a section whose `sha` no longer matches has moved.
final class BranchFreshness {
    private(set) var tips: [String: String] = [:]
    private var generation = 0
    var onChange: (() -> Void)?

    static func readTips(_ deck: Deck) -> [String: String] {
        guard deck.isForest, let checkout = repoCheckout(deck) else { return [:] }
        var tips: [String: String] = [:]
        for section in deck.sections where section.rank != nil && section.sha != nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", checkout, "rev-parse", "--verify", "--quiet", section.key + "^{commit}"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let tip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0, !tip.isEmpty {
                tips[section.key] = tip
            }
        }
        return tips
    }

    func refresh(_ deck: Deck) {
        generation += 1
        let mine = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tips = Self.readTips(deck)
            DispatchQueue.main.async {
                guard let self, self.generation == mine, tips != self.tips else { return }
                self.tips = tips
                self.onChange?()
            }
        }
    }

    /// Reads the tips on this thread; for snapshots, which can't wait for the async read.
    func refreshNow(_ deck: Deck) {
        generation += 1
        tips = Self.readTips(deck)
    }

    /// The written and current tips when the branch moved since its page was written; nil when it hasn't, or Show can't tell.
    func moved(_ section: Section) -> (written: String, now: String)? {
        guard let written = section.sha?.lowercased(), !written.isEmpty, let now = tips[section.key]?.lowercased() else { return nil }
        return now.hasPrefix(written) || written.hasPrefix(now) ? nil : (written, now)
    }
}

extension DeckController {
    /// Forest's own keys, registered once with the first deck.
    static let forestKeys: Void = KeyTable.register([
        KeyBinding(id: "section.regenerate", menu: "Section", title: "Regenerate Branch Page", key: "R", modifiers: [.command, .shift], workspaces: [.forest],
                   isEnabled: { $0.workspaces[.forest]?.currentDeck?.selectedSection?.rank != nil }) { $0.regenerateBranchPage() },
    ])
}

extension AppDelegate {
    /// ⌘⇧R: asks Claude to rewrite the selected branch's page, through the deck's thread delivery.
    func regenerateBranchPage() {
        guard let controller = workspaces[active] else { return }
        guard active == .forest, let deck = controller.currentDeck else {
            controller.say("⌘⇧R regenerates a branch page from the Forest workspace")
            return
        }
        controller.say(deck.regenerateSelected())
    }
}
