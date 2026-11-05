import AppKit
import Testing
@testable import CanopyUI

@MainActor
@Suite struct PinnedHeaderTests {
    func file(_ path: String, lines: Int) -> [Segment] {
        [Segment(key: "h|\(path)") {
            let b = DocBuilder()
            b.put("☐ " + path)
            b.endRow(RowInfo(kind: .file, stop: "f|\(path)", path: path), Para.row(indent: 2, spacing: 8))
            return b.build([.font: DocFont.font])
        }, Segment(key: "b|\(path)") {
            let b = DocBuilder()
            for i in 1...lines {
                b.put("line \(i)")
                b.endRow(RowInfo(kind: .line, stop: "l|\(path)|\(i)", path: path), Para.row(indent: 14))
            }
            return b.build([.font: DocFont.font])
        }]
    }

    func canvas() -> Canvas {
        let c = Canvas()
        c.scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        c.text.colors = CanvasColors(.dark)
        c.apply(file("a.ts", lines: 80) + file("b.ts", lines: 80))
        c.text.layoutManager!.ensureLayout(for: c.text.textContainer!)
        c.text.sizeToFit()
        return c
    }

    func scroll(_ c: Canvas, to y: CGFloat) {
        c.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        c.scroll.reflectScrolledClipView(c.scroll.contentView)
        c.updatePin()
    }

    @Test func noPinWhileTheFirstHeaderIsOnScreen() {
        let c = canvas()
        scroll(c, to: 0)
        #expect(c.pin.isHidden)
    }

    @Test func theFileUnderTheTopEdgeKeepsItsHeaderPinned() {
        let c = canvas()
        let b = c.text.rect(for: c.range(of: "f|b.ts")!)!
        scroll(c, to: b.minY / 2)
        #expect(!c.pin.isHidden)
        #expect(c.pin.path == "a.ts")
        #expect(c.pin.shift == 0)
        scroll(c, to: b.minY + 40)
        #expect(c.pin.path == "b.ts")
    }

    @Test func theNextHeaderPushesThePinUp() {
        let c = canvas()
        let b = c.text.rect(for: c.range(of: "f|b.ts")!)!
        scroll(c, to: b.minY - 5)
        #expect(c.pin.path == "a.ts")
        #expect(c.pin.shift < 0)
        #expect(c.pin.frame.height < b.height)
    }

    @Test func thePinnedCheckboxMarksTheFileAndTheRestOfItGoesToTheHeader() {
        let c = canvas()
        var viewed: String?
        var clicked: String?
        c.text.onViewed = { viewed = $0 }
        c.text.onClick = { s, _ in clicked = s }
        let b = c.text.rect(for: c.range(of: "f|b.ts")!)!
        scroll(c, to: b.minY / 2)
        #expect(onCheckbox(c.pin.header, x: 2))
        #expect(!onCheckbox(c.pin.header, x: 200))
        c.pin.onClick?("a.ts", true)
        #expect(viewed == "a.ts")
        c.pin.onClick?("a.ts", false)
        #expect(clicked == "f|a.ts")
    }

    @Test func aViewportRowRoundTripsAndStopsAtTheDocumentsEnds() {
        let c = canvas()
        let stop = "l|a.ts|40"
        let line = c.text.rect(for: c.range(of: stop)!)!
        scroll(c, to: line.minY - 5 * line.height)
        #expect(c.viewportRow(of: stop) == 5)
        scroll(c, to: 0)
        #expect(c.settle(stop, row: 5))
        #expect(c.viewportRow(of: stop) == 5)
        #expect(c.settle("l|a.ts|1", row: 10))
        #expect(c.scroll.contentView.bounds.minY == 0, "the top of the document stops it")
        let maxY = c.text.frame.height - c.scroll.contentView.bounds.height
        #expect(c.settle("l|b.ts|80", row: 0))
        #expect(c.scroll.contentView.bounds.minY == maxY, "so does the bottom")
    }

    @Test func anAnchorPlacesTheNextScrollToItsStopOnly() {
        let c = canvas()
        let stop = "l|a.ts|40"
        c.anchor = (stop, 3)
        c.setMarks(CanvasMarks(cursor: stop), scrollTick: 1)
        #expect(c.viewportRow(of: stop) == 3)
        #expect(c.anchor == nil)
        c.anchor = ("l|a.ts|60", 3)
        c.setMarks(CanvasMarks(cursor: "l|a.ts|50"), scrollTick: 2)
        #expect(c.anchor == nil, "a cursor that went elsewhere drops it")
    }

    @Test func aFileJumpPutsItsHeaderAtTheTop() {
        let c = canvas()
        let head = c.text.rect(for: c.range(of: "f|b.ts")!)!
        c.lead = ("l|b.ts|1", "f|b.ts")
        c.setMarks(CanvasMarks(cursor: "l|b.ts|1"), scrollTick: 1)
        #expect(c.scroll.contentView.bounds.minY == head.minY)
        #expect(c.lead == nil)
        c.keepCursorInView()
        #expect(c.scroll.contentView.bounds.minY == head.minY, "settling layout keeps it there")
    }

    @Test func aShortLastFilesHeaderStillReachesTheTop() {
        let c = Canvas()
        c.scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        c.text.colors = CanvasColors(.dark)
        c.apply(file("a.ts", lines: 80) + file("b.ts", lines: 3))
        c.text.layoutManager!.ensureLayout(for: c.text.textContainer!)
        c.text.sizeToFit()
        let head = c.text.rect(for: c.range(of: "f|b.ts")!)!
        #expect(head.minY > c.text.frame.height - 300, "the file is shorter than the view")
        c.lead = ("l|b.ts|1", "f|b.ts")
        c.setMarks(CanvasMarks(cursor: "l|b.ts|1"), scrollTick: 1)
        #expect(c.scroll.contentView.bounds.minY == head.minY)
    }

    @Test func leadTopMath() {
        #expect(Canvas.leadTop(headY: 800, stopMaxY: 840, viewHeight: 320) == 800)
        #expect(Canvas.leadTop(headY: 800, stopMaxY: 1200, viewHeight: 320) == nil, "the cursor would fall off")
        #expect(Canvas.roomBelow(top: 1900, docHeight: 2000, viewHeight: 320) == 220)
        #expect(Canvas.roomBelow(top: 800, docHeight: 2000, viewHeight: 320) == 0)
    }

    @Test func viewportRowMath() {
        #expect(Canvas.viewportRow(y: 47, lineHeight: 16, viewHeight: 320) == 3)
        #expect(Canvas.viewportRow(y: -40, lineHeight: 16, viewHeight: 320) == 0)
        #expect(Canvas.viewportRow(y: 900, lineHeight: 16, viewHeight: 320) == 19, "kept on screen")
        #expect(Canvas.anchoredTop(stopY: 800, lineHeight: 16, row: 5, docHeight: 2000, viewHeight: 320) == 720)
        #expect(Canvas.anchoredTop(stopY: 40, lineHeight: 16, row: 5, docHeight: 2000, viewHeight: 320) == 0)
        #expect(Canvas.anchoredTop(stopY: 1990, lineHeight: 16, row: 0, docHeight: 2000, viewHeight: 320) == 1680)
    }
}
