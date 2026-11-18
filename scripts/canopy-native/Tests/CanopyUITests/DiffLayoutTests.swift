import AppKit
import CanopyCore
import Testing
@testable import CanopyUI

@MainActor @Suite struct DiffLayoutTests {
    let mixed = """
    @@ -1,2 +1,3 @@
     context
    +addedOnly
     tail
    @@ -20,3 +21,3 @@
     context
    -removed
    +replacement
     tail
    @@ -40,3 +41,2 @@
     context
    -removedOnly
     tail
    """

    @Test func everyHunkOfATwoSidedFileSplits() {
        let source = splitRows(parsePatch("a.ts", mixed))
        let paired = DiffLayout.pairedHunks(source)
        #expect(paired == [0, 1, 2])
        for row in source {
            #expect(DiffLayout.rows(row, columns: 100, paired: paired.contains(row.hunk)).allSatisfy { $0.divider > 0 })
        }
    }

    @Test func aBlockMovedBetweenHunksRendersOldLeftAndNewRight() {
        let moved = """
        @@ -54,6 +54,3 @@
         keep
        -moved1
        -moved2
        -moved3
         keep
        @@ -80,2 +77,5 @@
         keep
        +moved1
        +moved2
        +moved3
         keep
        """
        let source = splitRows(parsePatch("team.ts", moved))
        let paired = DiffLayout.pairedHunks(source)
        for row in source {
            let display = DiffLayout.rows(row, columns: 100, paired: paired.contains(row.hunk))
            #expect(display.allSatisfy { $0.divider > 0 })
            for d in display {
                for piece in d.pieces where piece.line.kind == .del { #expect(piece.side == .left) }
                for piece in d.pieces where piece.line.kind == .add { #expect(piece.side == .right) }
            }
        }
    }

    @Test func aWhollyOneSidedFileStaysOneColumn() {
        let added = """
        @@ -0,0 +1,2 @@
        +one
        +two
        """
        let source = splitRows(parsePatch("new.ts", added))
        let paired = DiffLayout.pairedHunks(source)
        #expect(paired.isEmpty)
        for row in source {
            let display = DiffLayout.rows(row, columns: 100, paired: paired.contains(row.hunk))
            #expect(display.allSatisfy { $0.divider == 0 && $0.pieces.count == 1 })
        }
    }

    @Test(arguments: [20, 40, 60, 61, 100, 200])
    func narrowPanesStackSidesWithoutChangingTheirSource(_ width: Int) {
        let row = splitRows(parsePatch("a.ts", "@@ -1 +1 @@\n-old before\n+new after\n"))[0]
        let display = DiffLayout.rows(row, columns: width, paired: true)
        #expect(display.allSatisfy { width < 61 ? $0.divider == 0 : $0.divider > 0 })
        #expect(display.flatMap(\.pieces).filter { $0.side == .left }.map(\.text).joined() == "old before")
        #expect(display.flatMap(\.pieces).filter { $0.side == .right }.map(\.text).joined() == "new after")
        #expect(row.key == "R:1")
    }

    @Test(arguments: [24, 61, 100])
    func unicodeAndTabsKeepTheirUtf16SourceCoordinates(_ width: Int) throws {
        let old = "😀e\u{301}\toldValue = \"漢字\"; distantNeedle"
        let row = splitRows(parsePatch("a.ts", "@@ -1 +1 @@\n-\(old)\n+newValue\n"))[0]
        for display in DiffLayout.rows(row, columns: width, paired: true) {
            for piece in display.pieces {
                #expect(!piece.text.contains("\t"))
                #expect((display.text as NSString).substring(with: NSRange(location: piece.storage.lowerBound, length: piece.storage.count)) == piece.text)
                for (i, source) in piece.offsets.enumerated() {
                    let at = piece.storage.lowerBound + i
                    let mark = try #require(display.source(at: at))
                    #expect(mark.side == piece.side && mark.at.lowerBound == source)
                    #expect(display.storage(for: mark).contains { $0.contains(at) })
                }
            }
        }
    }

    func document(_ patch: String, columns: Int) async throws -> (AppModel, NSAttributedString) {
        let payload: JSONValue = ["branch": "add-hankles-limited-label", "baseSha": "base123",
                                  "files": [["path": "a.ts", "add": 2, "del": 2, "patch": .string(patch)]]]
        let (app, _) = try await ReviewPageTests().app(String(decoding: JSONEncoder().encode(payload), as: UTF8.self))
        let page = ReviewPageState.of(app)
        page.diffColumns = columns
        let text = NSMutableAttributedString()
        for segment in ReviewDocument.segments(page, app, CanvasColors(.dark)) { text.append(segment.build()) }
        return (app, text)
    }

    @Test(arguments: [30, 61, 100])
    func realTextKitUsesThePlannedColumnsAndPointerCoordinates(_ columns: Int) async throws {
        let old = "😀e\u{301}\toldValue = distantNeedle + anotherValue"
        let (app, document) = try await document("@@ -1 +1 @@\n-\(old)\n+newValue\n", columns: columns)
        _ = app
        let canvas = Canvas()
        canvas.scroll.frame = NSRect(x: 0, y: 0, width: CGFloat(columns + 4) * DocFont.charWidth, height: 300)
        canvas.apply([Segment(key: "fixture") { document }])
        let manager = try #require(canvas.text.layoutManager)
        let container = try #require(canvas.text.textContainer)
        manager.ensureLayout(for: container)
        var count = 0
        document.enumerateAttribute(.rvRow, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            guard let info = value as? RowInfo, let layout = info.layout else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var fragments = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in fragments += 1 }
            #expect(fragments == 1)
            for piece in layout.pieces where !piece.storage.isEmpty {
                let character = range.location + piece.storage.lowerBound
                let glyph = manager.glyphIndexForCharacter(at: character)
                let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let expected = CGFloat(piece.side == .right && layout.divider > 0 ? layout.divider + 6 : 6) * DocFont.charWidth
                #expect(abs(rect.minX - expected) < 1)
                let point = NSPoint(x: rect.midX + canvas.text.textContainerOrigin.x, y: rect.midY + canvas.text.textContainerOrigin.y)
                let source = canvas.text.codeSource(at: point)?.1
                #expect(source?.side == piece.side && source?.at.lowerBound == piece.offsets.first)
                count += 1
            }
        }
        #expect(count >= 2)
    }
    @Test func positioningAndReflowKeepTheSourceCursorOnScreen() async throws {
        let source = (0..<100).map { "part\($0)" }.joined(separator: " ")
        let (app, document) = try await document("@@ -1,3 +1,3 @@\n before\n-\(source)\n+replacement\n after\n", columns: 100)
        let page = ReviewPageState.of(app)
        let canvas = Canvas()
        canvas.scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 180)
        canvas.apply([Segment(key: "wide") { document }])
        canvas.text.layoutManager!.ensureLayout(for: canvas.text.textContainer!)
        canvas.text.sizeToFit()
        let stop = try #require(page.stops.first { $0.row?.left?.kind == .del }?.key)
        let offset = (source as NSString).range(of: "part50").location
        let mark = DiffSourceMark(side: .left, at: offset..<offset + 1)
        canvas.setMarks(CanvasMarks(cursor: stop, sourceWord: (stop, mark)), scrollTick: 1)
        for position in [0.0, 0.5, 1.0] {
            #expect(canvas.place(stop, at: position))
            let rect = try #require(canvas.visibleRect(of: stop))
            #expect(rect.minY >= -1 && rect.maxY <= canvas.scroll.contentView.bounds.height + 1)
        }
        #expect(canvas.place(stop, at: 0.5))
        let before = try #require(canvas.visibleRect(of: stop)).minY
        let searchStamp = page.searchStamp
        page.diffColumns = 40
        #expect(page.searchStamp == searchStamp)
        let segments = ReviewDocument.segments(page, app, CanvasColors(.dark))
        canvas.apply(segments)
        await until("the reflow anchor") { abs((canvas.visibleRect(of: stop)?.minY ?? -999) - before) < 1 }
        #expect(canvas.text.marks.sourceWord?.mark == mark)
        #expect(page.stops.contains { $0.key == stop })
    }

    @Test func aStackedReplacementRevealsTheSelectedSideBeforeAWordIsChosen() async throws {
        let source = (0..<100).map { "part\($0)" }.joined(separator: " ")
        let (app, document) = try await document("@@ -1 +1 @@\n-\(source)\n+replacement\n", columns: 30)
        let page = ReviewPageState.of(app)
        let canvas = Canvas()
        canvas.scroll.frame = NSRect(x: 0, y: 0, width: 250, height: 180)
        canvas.apply([Segment(key: "stacked") { document }])
        canvas.text.layoutManager!.ensureLayout(for: canvas.text.textContainer!)
        canvas.text.sizeToFit()
        let stop = try #require(page.stops.first { $0.row?.right?.kind == .add }?.key)
        canvas.setMarks(CanvasMarks(cursor: stop, column: .right), scrollTick: 1)
        let rect = try #require(canvas.visibleRect(of: stop))
        #expect(rect.minY >= 0 && rect.maxY <= canvas.scroll.contentView.bounds.height)
        #expect(canvas.scroll.contentView.bounds.minY > 0)
    }

}
