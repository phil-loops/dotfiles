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
}
