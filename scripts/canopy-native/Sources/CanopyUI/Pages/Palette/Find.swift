import Foundation

/// What the space menu finds besides commands (find.ts): branches and forests by fuzzy name, a
/// branch by its PR number, wiki pages by title, the tutor's concepts by name. Each result is a
/// quiet command plus its argument, so opening one runs through the runner. Pure.
struct Find: Equatable {
    /// find.branch | find.forest | find.wiki | find.concept
    var cmd: String
    var id: String
    var title: String
    var sub: String
}

/// The world the finder searches: just the fields it reads, so archived forests' branches (from
/// `/state?archived=1`) and the live store feed it alike.
struct FindWorld {
    struct Branch: Equatable { var id: String; var name: String; var project: String }
    struct Project: Equatable { var id: String; var name: String; var archived: Bool }
    struct Pr: Equatable { var id: String; var number: Int }
    struct Page: Equatable { var slug: String; var title: String; var section: String }
    struct Concept: Equatable { var id: String; var name: String }

    var branches: [Branch] = []
    var projects: [Project] = []
    var prs: [Pr] = []
    var pages: [Page] = []
    var concepts: [Concept] = []
}

enum Finder {
    static let limit = 30

    /// Substring outranks subsequence; consecutive runs and word-start hits rank tighter (v1's ⌘K).
    /// -infinity when the letters aren't all there in order.
    static func fuzzyScore(_ needle: String, _ hay: String) -> Double {
        let h = Array(hay)
        if let r = hay.range(of: needle) {
            let at = hay.distance(from: hay.startIndex, to: r.lowerBound)
            return 1e6 - Double(at) * 10 - Double(h.count)
        }
        var score = 0.0
        var prev = -2
        for ch in needle {
            guard let j = h.indices.first(where: { $0 > prev && h[$0] == ch }) else { return -.infinity }
            score += j == prev + 1 ? 10 : 1
            if j == 0 || "-/ _.".contains(h[j - 1]) { score += 5 }
            prev = j
        }
        return score - Double(h.count) * 0.01
    }

    private static func squash(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// The branches, forests, wiki pages and concepts matching what's typed, best first; an archived
    /// forest's sink to the end.
    static func finds(_ q: String, _ w: FindWorld) -> [Find] {
        let needle = squash(q)
        guard !needle.isEmpty else { return [] }
        let projects = Dictionary(w.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prOf = Dictionary(w.prs.map { ($0.id, $0.number) }, uniquingKeysWith: { a, _ in a })
        let number = Rx.exec("^#?(\\d+)$", needle)?[1]
        var scored: [(f: Find, s: Double, archived: Bool, i: Int)] = []
        func push(_ f: Find, _ s: Double, _ archived: Bool) { scored.append((f, s, archived, scored.count)) }
        for p in w.projects {
            let s = fuzzyScore(needle, p.name.lowercased())
            if s > -.infinity { push(Find(cmd: "find.forest", id: p.id, title: p.name, sub: "forest"), s + 1, p.archived) }
        }
        for b in w.branches {
            let pr = prOf[b.id]
            let s = number.map { n in pr.map { String($0) == n ? 2e6 : -.infinity } ?? -.infinity } ?? fuzzyScore(needle, b.name.lowercased())
            if s == -.infinity { continue }
            let project = projects[b.project]
            let sub = [pr.map { "#\($0)" } ?? "", project?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            push(Find(cmd: "find.branch", id: b.id, title: b.name, sub: sub), s, project?.archived ?? false)
        }
        if number == nil {
            for p in w.pages {
                let s = max(fuzzyScore(needle, squash(p.title)), fuzzyScore(needle, p.slug))
                if s > -.infinity { push(Find(cmd: "find.wiki", id: p.slug, title: p.title, sub: "wiki · \(p.section)"), s, false) }
            }
            for c in w.concepts {
                let s = fuzzyScore(needle, squash(c.name))
                if s > -.infinity { push(Find(cmd: "find.concept", id: c.id, title: c.name, sub: "concept"), s, false) }
            }
        }
        return scored
            .sorted { a, b in a.archived != b.archived ? !a.archived : a.s != b.s ? a.s > b.s : a.i < b.i }
            .prefix(limit)
            .map(\.f)
    }
}
