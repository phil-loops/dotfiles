import AppKit
import CanopyCore
import Testing
@testable import CanopyUI

@MainActor @Suite struct CanvasCopyTests {
    func document(_ patch: String, columns: Int = 100) async throws -> NSAttributedString {
        try await DiffLayoutTests().document(patch, columns: columns).1
    }

    func all(_ d: NSAttributedString) -> NSRange { NSRange(location: 0, length: d.length) }

    /// The selection from the start of `needle`'s `nth` appearance on the canvas to the end of the canvas.
    func from(_ needle: String, nth: Int = 0, in d: NSAttributedString) throws -> NSRange {
        let s = d.string as NSString
        var at = 0
        for _ in 0...nth {
            let r = s.range(of: needle, range: NSRange(location: at, length: s.length - at))
            try #require(r.location != NSNotFound)
            at = r.location + 1
        }
        return NSRange(location: at - 1, length: s.length - at + 1)
    }

    @Test func aSplitSelectionCopiesOnlyTheHalfItStartedOn() async throws {
        let d = try await document("@@ -1,3 +1,3 @@\n keep\n-oldValue = 1\n+newValue = 2\n tail\n")
        #expect(CanvasCopy.text(d, all(d)) == "keep\noldValue = 1\ntail")
        #expect(CanvasCopy.text(d, try from("newValue", in: d)) == "newValue = 2\ntail")
    }

    @Test func noLineNumberOrGutterReachesTheCopy() async throws {
        let d = try await document("@@ -40,2 +41,2 @@\n-a\n+b\n c\n")
        let copied = try #require(CanvasCopy.text(d, all(d)))
        #expect(!copied.contains("40") && !copied.contains("41") && !copied.contains("\t"))
    }

    @Test(arguments: [30, 61])
    func aWrappedLineCopiesWholeWithoutBreaks(_ columns: Int) async throws {
        let long = (0..<30).map { "part\($0)" }.joined(separator: " ")
        let d = try await document("@@ -1 +1,2 @@\n \(long)\n+y\n", columns: columns)
        #expect(CanvasCopy.text(d, all(d)) == "\(long)\ny")
    }

    @Test func tabsAndBlankLinesComeBackAsWritten() async throws {
        let d = try await document("@@ -1,4 +1,4 @@\n \tindented\n \n-a\n+b\n end\n")
        #expect(CanvasCopy.text(d, all(d)) == "\tindented\n\na\nend")
    }

    @Test func aSelectionStartingMidLineCopiesFromThere() async throws {
        let d = try await document("@@ -1,2 +1,2 @@\n-const a = 1\n+const b = 2\n keep\n")
        #expect(CanvasCopy.text(d, try from("b = 2", in: d)) == "b = 2\nkeep")
    }

    @Test func aFilesLinesCopyAsTheFileHasThem() {
        let lines = ["  SELECT", "    e.id,", "", "  FROM \"DisableDomainEvent\" e"]
        let d = ReviewDocument.code(lines, path: "queries/x.ts", CanvasColors(.dark))
        #expect(CanvasCopy.text(d, all(d)) == lines.joined(separator: "\n"))
    }

    @Test func theHighlightCoversOnlyCopiedCode() async throws {
        let d = try await document("@@ -1,2 +1,2 @@\n-oldValue\n+newValue\n tail\n")
        let s = d.string as NSString
        for part in CanvasCopy.parts(d, all(d)) where part.range.length > 0 {
            #expect(s.substring(with: part.range) == part.text)
        }
    }
}
