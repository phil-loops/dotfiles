import AppKit
import CanopyCore
import SwiftUI

// The code/diff canvas: one read-only, TextKit 1 NSTextView holding a whole diff (or a whole file),
// with non-contiguous layout so only what's on screen is laid out. Rows are paragraphs carrying a
// `RowInfo`; everything that changes per key press — the cursor, the `x` range, viewed hunks
// dimming, add/del bands — is drawn at draw time from that info, so moving the cursor or marking a
// hunk viewed never touches the text. The text itself is a list of segments (a file's header, a
// file's body) cached by key: a change re-sets only the segments whose key moved.
//
// What hangs under a row (a conversation, a pending comment, the comment box) is a SwiftUI view
// hosted over a paragraph whose line height the view's own height sets.

extension NSAttributedString.Key {
    static let rvRow = NSAttributedString.Key("canopy.rvRow")
}

/// What one paragraph of the canvas is.
final class RowInfo: NSObject {
    enum Kind { case line, gap, file, extras, code, note }
    let kind: Kind
    /// the cursor stop it is (an extras block: its first)
    let stop: String?
    /// an extras block: every stop inside it
    let stops: [String]
    let path: String
    let hunk: Int
    let left: LineKind?
    let right: LineKind?
    let oldLine: Int?
    let newLine: Int?
    /// a thread sits at this row
    let threaded: Bool
    /// split view: the column (in characters) the right half starts at
    let splitCol: Int
    /// where the code starts on the row, in UTF-16 units from the paragraph's start
    let codeStart: Int
    /// split: where the right half's code starts
    let rightCodeStart: Int
    /// an extras block's hosted view
    let extra: ExtraSpec?

    init(kind: Kind, stop: String?, stops: [String] = [], path: String = "", hunk: Int = -1, left: LineKind? = nil, right: LineKind? = nil,
         oldLine: Int? = nil, newLine: Int? = nil, threaded: Bool = false, splitCol: Int = 0, codeStart: Int = 0, rightCodeStart: Int = 0,
         extra: ExtraSpec? = nil) {
        self.kind = kind; self.stop = stop; self.stops = stops.isEmpty ? (stop.map { [$0] } ?? []) : stops; self.path = path; self.hunk = hunk
        self.left = left; self.right = right; self.oldLine = oldLine; self.newLine = newLine; self.threaded = threaded; self.splitCol = splitCol
        self.codeStart = codeStart; self.rightCodeStart = rightCodeStart; self.extra = extra
    }
}

/// A SwiftUI view hosted over an extras paragraph.
final class ExtraSpec {
    let id: String
    let view: () -> AnyView
    init(id: String, view: @escaping () -> AnyView) { self.id = id; self.view = view }
}

/// One cached piece of the canvas's text.
struct Segment {
    var key: String
    var build: () -> NSAttributedString
}

/// The canvas palette, from the theme.
struct CanvasColors {
    var ink, inkDim, inkFaint, gold, goldDeep, goldWash, ember, patina, rule, raise, edge, night, add, addBg, del, delBg, bg: NSColor
    var code: CodeColors

    init(_ t: Theme) {
        func c(_ x: Color) -> NSColor { NSColor(x) }
        ink = c(t.ink); inkDim = c(t.inkDim); inkFaint = c(t.inkFaint); gold = c(t.goldLeaf); goldDeep = c(t.goldDeep); goldWash = c(t.goldWash)
        ember = c(t.ember); patina = c(t.patina); rule = c(t.rule); raise = c(t.vellumRaise); edge = c(t.vellumEdge); night = c(t.vellumNight)
        add = c(t.add); addBg = c(t.addBg); del = c(t.del); delBg = c(t.delBg); bg = c(t.diffBg)
        code = CodeColors(ink: ink, inkDim: inkDim, inkFaint: inkFaint)
    }
}

/// What the canvas lights at draw time.
struct CanvasMarks: Equatable {
    var cursor: String?
    /// split: the half the cursor reads (nil: the whole row)
    var column: Side?
    /// the selected name: its row's stop and its UTF-16 range from the row's start
    var word: (stop: String, at: Range<Int>)?
    /// the range `x` marked, or the lines the selected conversation covers: path, side, from…to
    var range: (path: String, side: Side, from: Int, to: Int)?
    /// "<path>#<hunk>" whose changes are all viewed (dimmed)
    var seen: Set<String> = []
    /// the select-mode range's stops
    var selection: Set<String> = []
    /// code view: the lit lines
    var lit: ClosedRange<Int>?
    /// whether the canvas's pane has focus (the cursor draws dimmer when not)
    var focused = true

    static func == (a: CanvasMarks, b: CanvasMarks) -> Bool {
        a.cursor == b.cursor && a.column == b.column && a.word?.stop == b.word?.stop && a.word?.at == b.word?.at && a.range?.path == b.range?.path && a.range?.side == b.range?.side && a.range?.from == b.range?.from &&
            a.range?.to == b.range?.to && a.seen == b.seen && a.selection == b.selection && a.lit == b.lit && a.focused == b.focused
    }
}

@MainActor
final class CanvasTextView: NSTextView {
    var colors: CanvasColors?
    var marks = CanvasMarks()
    var charWidth: CGFloat = 7
    /// a click on a row: its stop key, and whether shift was held
    var onClick: ((String, Bool) -> Void)?
    /// the pointer over code: (row info, UTF-16 offset in the row's code, whether on the right half)
    var onPointer: ((RowInfo, Int, Bool) -> Void)?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // never the keyboard's: the KeyMonitor drives the cursor
    override var acceptsFirstResponder: Bool { true }

    func info(at charIndex: Int) -> RowInfo? {
        guard let ts = textStorage, charIndex >= 0, charIndex < ts.length else { return nil }
        return ts.attribute(.rvRow, at: charIndex, effectiveRange: nil) as? RowInfo
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = characterIndexForInsertion(at: p)
        if let inf = info(at: min(i, max(0, (textStorage?.length ?? 1) - 1))), let s = inf.stop {
            onClick?(s, event.modifierFlags.contains(.shift))
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self && t.userInfo?["canvas"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: visibleRect, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["canvas": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let tp = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let g = lm.glyphIndex(for: tp, in: tc, fractionOfDistanceThroughGlyph: &frac)
        let ci = lm.characterIndexForGlyph(at: g)
        guard let inf = info(at: ci), inf.kind == .line || inf.kind == .code else { return }
        var pr = NSRange()
        _ = ts.attribute(.rvRow, at: ci, effectiveRange: &pr)
        let para = (ts.string as NSString).paragraphRange(for: NSRange(location: ci, length: 0))
        let off = ci - para.location
        if inf.splitCol > 0, off >= inf.rightCodeStart { onPointer?(inf, off - inf.rightCodeStart, true) }
        else if off >= inf.codeStart { onPointer?(inf, off - inf.codeStart, false) }
    }

    /// The rect of a character range, in this view's coordinates.
    func rect(for range: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, range.location < (textStorage?.length ?? 0) else { return nil }
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g, in: tc)
        r.origin.x = 0
        r.size.width = bounds.width
        r.origin.y += textContainerOrigin.y
        return r
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let colors, let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return }
        colors.bg.setFill()
        rect.fill()
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: NSRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height), in: tc)
        let w = bounds.width
        let x0 = origin.x
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
            let ci = lm.characterIndexForGlyph(at: gr.location)
            guard let inf = ts.attribute(.rvRow, at: ci, effectiveRange: nil) as? RowInfo else { return }
            let band = NSRect(x: 0, y: frag.minY + origin.y, width: w, height: frag.height)
            self.drawBand(inf, band, x0: x0, colors)
            if let word = self.marks.word, inf.stop == word.stop {
                let row = (ts.string as NSString).paragraphRange(for: NSRange(location: ci, length: 0))
                let chars = NSRange(location: row.location + word.at.lowerBound, length: word.at.count)
                let g = lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
                guard NSLocationInRange(g.location, gr) else { return }
                let r = lm.boundingRect(forGlyphRange: g, in: tc).offsetBy(dx: origin.x, dy: origin.y)
                colors.gold.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 1), xRadius: 2, yRadius: 2).fill()
                colors.gold.setFill()
                NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 1.5).fill()
            }
        }
    }

    private func drawBand(_ inf: RowInfo, _ band: NSRect, x0: CGFloat, _ c: CanvasColors) {
        let gutter = x0 + charWidth * 12
        switch inf.kind {
        case .file:
            c.raise.setFill(); band.fill()
            c.edge.setFill(); NSRect(x: 0, y: band.maxY - 1, width: band.width, height: 1).fill()
        case .gap:
            c.patina.withAlphaComponent(inf.stop == marks.cursor ? 0.12 : 0.06).setFill(); band.fill()
        case .extras:
            c.night.setFill(); band.fill()
            c.edge.setFill()
            NSRect(x: 0, y: band.minY, width: band.width, height: 1).fill()
            NSRect(x: 0, y: band.maxY - 1, width: band.width, height: 1).fill()
        case .line:
            if inf.splitCol > 0 {
                let mid = x0 + charWidth * CGFloat(inf.splitCol)
                if let l = inf.left, l != .ctx { (l == .del ? c.delBg : c.addBg).setFill(); NSRect(x: 0, y: band.minY, width: mid, height: band.height).fill() }
                if inf.left == nil { c.ink.withAlphaComponent(0.02).setFill(); NSRect(x: gutter, y: band.minY, width: mid - gutter, height: band.height).fill() }
                if let r = inf.right, r != .ctx { (r == .add ? c.addBg : c.delBg).setFill(); NSRect(x: mid, y: band.minY, width: band.width - mid, height: band.height).fill() }
                if inf.right == nil { c.ink.withAlphaComponent(0.02).setFill(); NSRect(x: mid, y: band.minY, width: band.width - mid, height: band.height).fill() }
                c.rule.withAlphaComponent(0.5).setFill(); NSRect(x: mid - 1, y: band.minY, width: 1, height: band.height).fill()
            } else if inf.left == nil, inf.right == .add {
                c.addBg.setFill(); band.fill()
            } else if inf.right == nil, inf.left == .del {
                c.delBg.setFill(); band.fill()
            }
            if inf.threaded { c.ember.setFill(); NSRect(x: x0 + charWidth * 5.5, y: band.minY, width: 2, height: band.height).fill() }
            if let r = marks.range, r.path == inf.path {
                let n = r.side == .right ? inf.newLine : inf.oldLine
                if let n, n >= r.from, n <= r.to {
                    c.gold.withAlphaComponent(0.05).setFill(); band.fill()
                    c.goldDeep.setFill(); NSRect(x: 0, y: band.minY, width: 2, height: band.height).fill()
                }
            }
        case .code:
            if let lit = marks.lit, let n = inf.newLine, lit.contains(n) { c.goldWash.setFill(); band.fill() }
        case .note: break
        }
        if let s = inf.stop, marks.selection.contains(s) || inf.stops.contains(where: marks.selection.contains) {
            c.ember.withAlphaComponent(0.12).setFill(); band.fill()
        }
        if let cur = marks.cursor, inf.stops.contains(cur) {
            var lit = band
            if inf.kind == .line, inf.splitCol > 0, let col = marks.column {
                let mid = x0 + charWidth * CGFloat(inf.splitCol)
                let left = col == .left ? inf.left != nil : inf.right == nil
                lit = left ? NSRect(x: 0, y: band.minY, width: mid, height: band.height) : NSRect(x: mid, y: band.minY, width: band.width - mid, height: band.height)
            }
            c.goldWash.setFill(); lit.fill()
            (marks.focused ? c.gold : c.goldDeep).setFill()
            NSRect(x: lit.minX, y: band.minY, width: 2, height: band.height).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // viewed hunks dim, so what's left to read stands out (v2: opacity .5 unless under the cursor)
        guard let colors, !marks.seen.isEmpty, let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: NSRect(x: dirtyRect.minX - origin.x, y: dirtyRect.minY - origin.y, width: dirtyRect.width, height: dirtyRect.height), in: tc)
        colors.bg.withAlphaComponent(0.5).setFill()
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
            let ci = lm.characterIndexForGlyph(at: gr.location)
            guard let inf = ts.attribute(.rvRow, at: ci, effectiveRange: nil) as? RowInfo, inf.kind == .line, inf.stop != self.marks.cursor,
                  self.marks.seen.contains("\(inf.path)#\(inf.hunk)") else { return }
            NSRect(x: 0, y: frag.minY + origin.y, width: self.bounds.width, height: frag.height).fill(using: .sourceOver)
        }
    }
}

/// The canvas's AppKit side: the text view, its segments, the stop → range map, the hosted extras.
@MainActor
final class Canvas: NSObject {
    let scroll: NSScrollView
    let text: CanvasTextView
    private var segments: [(key: String, length: Int)] = []
    private var stopMap: [String: NSRange] = [:]
    private var built: [String: NSAttributedString] = [:]
    private var hosted: [String: NSHostingView<AnyView>] = [:]
    private var heights: [String: CGFloat] = [:]
    private var lastCursor: String?
    private var lastScrolledTick = -1
    var app: AppModel?
    var theme: Theme = .dark
    private var layoutPending = false

    override init() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        lm.backgroundLayoutEnabled = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        text = CanvasTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: tc)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.usesFindBar = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.layoutManager?.usesFontLeading = false
        scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(boundsMoved), name: NSView.frameDidChangeNotification, object: text)
        text.postsFrameChangedNotifications = true
    }

    @objc private func boundsMoved() { scheduleLayoutExtras() }

    var length: Int { text.textStorage?.length ?? 0 }

    /// Bring the text up to these segments: only the run between the unchanged head and tail is re-set.
    func apply(_ segs: [Segment]) {
        guard let ts = text.textStorage else { return }
        let keys = segs.map(\.key)
        let old = segments.map(\.key)
        if keys == old { return }
        var head = 0
        while head < min(keys.count, old.count), keys[head] == old[head] { head += 1 }
        var tail = 0
        while tail < min(keys.count, old.count) - head, keys[keys.count - 1 - tail] == old[old.count - 1 - tail] { tail += 1 }
        let start = segments[..<head].reduce(0) { $0 + $1.length }
        let oldMid = segments[head..<(segments.count - tail)].reduce(0) { $0 + $1.length }
        let mid = NSMutableAttributedString()
        var newMid: [(key: String, length: Int)] = []
        for s in segs[head..<(segs.count - tail)] {
            let a = built[s.key] ?? s.build()
            built[s.key] = a
            mid.append(a)
            newMid.append((s.key, a.length))
        }
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: start, length: oldMid), with: mid)
        ts.endEditing()
        segments = Array(segments[..<head]) + newMid + Array(segments[(segments.count - tail)...])
        let live = Set(keys)
        if built.count > keys.count * 2 + 64 { built = built.filter { live.contains($0.key) } }
        reindex()
        applyHeights()
        scheduleLayoutExtras()
    }

    /// Stop key → character range, over the whole text.
    private func reindex() {
        stopMap = [:]
        guard let ts = text.textStorage, ts.length > 0 else { return }
        ts.enumerateAttribute(.rvRow, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            guard let inf = v as? RowInfo else { return }
            for s in inf.stops {
                if let have = stopMap[s] { stopMap[s] = NSUnionRange(have, r) } else { stopMap[s] = r }
            }
        }
    }

    func range(of stop: String) -> NSRange? { stopMap[stop] }

    // ── marks and the cursor ──

    func setMarks(_ m: CanvasMarks, scrollTick: Int) {
        let was = text.marks
        text.marks = m
        if was != m { text.needsDisplay = true }
        if let c = m.cursor, c != lastCursor || scrollTick != lastScrolledTick {
            lastCursor = c
            lastScrolledTick = scrollTick
            reveal(c)
        }
    }

    /// Keep a stop on screen, moving as little as it takes (v2 scrollIntoView block: nearest).
    func reveal(_ stop: String) {
        guard let r = stopMap[stop], let rect = text.rect(for: NSRange(location: r.location, length: max(1, min(r.length, 1)))) else { return }
        let visible = scroll.contentView.bounds
        let margin: CGFloat = min(48, visible.height / 4)
        var y = visible.minY
        if rect.minY < visible.minY + margin { y = rect.minY - margin }
        else if rect.maxY > visible.maxY - margin { y = rect.maxY + margin - visible.height }
        y = max(0, min(y, max(0, text.frame.height - visible.height)))
        if y != visible.minY {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Scroll so a 1-based paragraph (a code view's line) sits a third down.
    func center(_ stop: String) {
        guard let r = stopMap[stop], let rect = text.rect(for: NSRange(location: r.location, length: 1)) else { return }
        let h = scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - h / 3)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The cursor row's rect relative to the pane's visible top-left (for the types popover).
    func visibleRect(of stop: String) -> CGRect? {
        guard let r = stopMap[stop], let rect = text.rect(for: NSRange(location: r.location, length: 1)) else { return nil }
        let v = scroll.contentView.bounds
        return CGRect(x: rect.minX, y: rect.minY - v.minY, width: rect.width, height: rect.height)
    }

    /// Every stop with a row on screen, top to bottom, as window rects (top-left origin).
    func visibleTargets() -> [(key: String, rect: CGRect)] {
        guard let lm = text.layoutManager, let tc = text.textContainer, let ts = text.textStorage, ts.length > 0, let win = text.window else { return [] }
        let v = scroll.contentView.bounds
        let origin = text.textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: NSRect(x: 0, y: v.minY - origin.y, width: v.width, height: v.height), in: tc)
        var out: [(String, CGRect)] = []
        var seen = Set<String>()
        let H = win.contentView?.bounds.height ?? 0
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
            let ci = lm.characterIndexForGlyph(at: gr.location)
            guard let inf = ts.attribute(.rvRow, at: ci, effectiveRange: nil) as? RowInfo, let s = inf.stop, seen.insert(s).inserted else { return }
            let local = NSRect(x: 0, y: frag.minY + origin.y, width: self.text.bounds.width, height: frag.height)
            guard local.maxY > v.minY, local.minY < v.maxY else { return }
            let w = self.text.convert(local, to: nil)
            out.append((s, CGRect(x: w.minX, y: H - w.maxY, width: w.width, height: w.height)))
        }
        return out
    }

    // ── hosted extras ──

    private func extrasRanges() -> [(ExtraSpec, NSRange)] {
        guard let ts = text.textStorage, ts.length > 0 else { return [] }
        var out: [(ExtraSpec, NSRange)] = []
        ts.enumerateAttribute(.rvRow, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if let inf = v as? RowInfo, let e = inf.extra { out.append((e, r)) }
        }
        return out
    }

    /// Give each extras paragraph the height its view last reported.
    private func applyHeights() {
        guard let ts = text.textStorage else { return }
        ts.beginEditing()
        for (e, r) in extrasRanges() { setHeight(e.id, heights[e.id] ?? 64, r, ts) }
        ts.endEditing()
    }

    private func setHeight(_ id: String, _ h: CGFloat, _ r: NSRange, _ ts: NSTextStorage) {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        ts.addAttribute(.paragraphStyle, value: p, range: r)
    }

    private func heightReported(_ id: String, _ h: CGFloat) {
        let h = ceil(max(8, h))
        guard abs((heights[id] ?? 0) - h) > 0.5 else { return }
        heights[id] = h
        guard let ts = text.textStorage, let r = extrasRanges().first(where: { $0.0.id == id })?.1 else { return }
        ts.beginEditing()
        setHeight(id, h, r, ts)
        ts.endEditing()
        scheduleLayoutExtras()
    }

    private func scheduleLayoutExtras() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutPending = false
            self?.layoutExtras()
        }
    }

    /// Put each hosted view over its paragraph (views for paragraphs gone are removed).
    func layoutExtras() {
        guard let app else { return }
        let extras = extrasRanges()
        let live = Set(extras.map(\.0.id))
        for (id, v) in hosted where !live.contains(id) { v.removeFromSuperview(); hosted[id] = nil }
        let indent = text.charWidth * 12 + 8
        let width = max(200, text.bounds.width - indent - 16)
        for (e, r) in extras {
            guard let rect = text.rect(for: NSRange(location: r.location, length: 1)) else { continue }
            let root = AnyView(
                e.view()
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { [weak self] in self?.heightReported(e.id, g.size.height + 8) }
                            .onChange(of: g.size.height) { _, h in self.heightReported(e.id, h + 8) }
                    })
                    .environment(\.theme, theme)
                    .environment(app))
            let v: NSHostingView<AnyView>
            if let have = hosted[e.id] {
                v = have
                v.rootView = root
            } else {
                v = NSHostingView(rootView: root)
                v.sizingOptions = []
                text.addSubview(v)
                hosted[e.id] = v
            }
            let f = NSRect(x: indent, y: rect.minY + 4, width: width, height: max(0, rect.height - 8))
            if v.frame != f { v.frame = f }
        }
    }

    /// Forget every cached segment (the theme or font changed).
    func invalidate() {
        built = [:]
        segments = []
        text.textStorage?.setAttributedString(NSAttributedString())
    }
}

/// The canvas in SwiftUI: segments in, marks in; clicks and the pointer out. The handle lets the
/// page's state ask it for label targets and rects.
struct CanvasView: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app
    let handle: CanvasHandle
    let segments: [Segment]
    let marks: CanvasMarks
    /// bumped to scroll to the cursor again even when it hasn't moved
    var scrollTick = 0
    /// center the stop before the first "|" once each time this changes (a code pane opening at a place)
    var centerOn: String?
    var onClick: ((String, Bool) -> Void)?
    var onPointer: ((RowInfo, Int, Bool) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let c = handle.canvas
        c.app = app
        return c.scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        let c = handle.canvas
        c.app = app
        if c.theme != theme {
            c.theme = theme
            c.invalidate()
        }
        c.text.colors = CanvasColors(theme)
        c.text.charWidth = DocFont.charWidth
        c.text.onClick = onClick
        c.text.onPointer = onPointer
        c.apply(segments)
        if let on = centerOn, handle.centered != on {
            handle.centered = on
            let stop = String(on.split(separator: "|").first ?? "")
            c.text.marks = marks
            c.text.needsDisplay = true
            DispatchQueue.main.async { c.center(stop) }
        } else {
            c.setMarks(marks, scrollTick: scrollTick)
        }
    }
}

/// A stable reference to one canvas, kept by whoever owns the pane (the page state; the Tutor's
/// code pane keeps its own and hands it to `CodePaneView`).
@MainActor
public final class CanvasHandle {
    let canvas = Canvas()
    var centered: String?
    public init() {}
}

/// The diff's type: Plex Mono at 12, with the column width the gutters are measured in.
enum DocFont {
    static let size: CGFloat = 12
    static var font: NSFont { Theme.nsMono(size) }
    static var bold: NSFont { Theme.nsMono(size, weight: .semibold) }
    static var small: NSFont { Theme.nsMono(11) }
    static var charWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
}
