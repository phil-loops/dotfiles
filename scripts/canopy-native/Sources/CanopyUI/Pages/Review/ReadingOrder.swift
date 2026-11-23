import Foundation

/// The order a diff's files are read in: schema → queries → models → everything else → wiring → UI →
/// test support, each test right after the file it covers, and files that only delete last. A path
/// matching no layer keeps plain path order, so an unlayered PR reads as before, tests aside.
enum ReadingOrder {
    static func sorted(_ files: [NodeFile]) -> [NodeFile] {
        files.enumerated().sorted { a, b in key(a.element) < key(b.element) || (key(a.element) == key(b.element) && a.offset < b.offset) }
            .map(\.element)
    }

    static func key(_ f: NodeFile) -> Key {
        let source = sourceOf(f.path)
        return Key(deletedOnly: f.add == 0 && f.del > 0, layer: layer(source), source: source, isTest: source != f.path)
    }

    struct Key: Comparable {
        var deletedOnly: Bool
        var layer: Int
        var source: String
        var isTest: Bool

        static func < (a: Key, b: Key) -> Bool {
            (a.deletedOnly ? 1 : 0, a.layer, a.source, a.isTest ? 1 : 0) < (b.deletedOnly ? 1 : 0, b.layer, b.source, b.isTest ? 1 : 0)
        }
    }

    /// `x.test.ts` / `x.spec.tsx` → `x.ts` / `x.tsx`; any other path is its own source.
    static func sourceOf(_ path: String) -> String {
        for marker in [".test.", ".spec."] {
            if let r = path.range(of: marker, options: .backwards) { return path.replacingCharacters(in: r, with: ".") }
        }
        return path
    }

    static func layer(_ path: String) -> Int {
        let dirs = path.split(separator: "/").dropLast().map(String.init)
        if path.hasSuffix("schema.prisma") || dirs.contains("migrations") { return 0 }
        if dirs.contains("queries") { return 1 }
        if dirs.contains("models") { return 2 }
        if dirs.contains("testing") { return 6 }
        if dirs.contains("components") || (dirs.first == "pages" && dirs.dropFirst().first != "api") { return 5 }
        if dirs.contains("trpc") || dirs.contains("jobs") || dirs.contains("script-runner") || (dirs.first == "pages" && dirs.dropFirst().first == "api") { return 4 }
        return 3
    }
}
