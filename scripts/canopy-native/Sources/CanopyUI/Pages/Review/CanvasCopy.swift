import AppKit
import CanopyCore

/// What a selection on the canvas copies: the code it covers as source text — never a gutter or a
/// line number, a wrapped line whole, and in a split row only the half the selection started on.
@MainActor
enum CanvasCopy {
    /// One run of code the selection covers: where it sits on the canvas, and its source text.
    struct Part: Equatable {
        var range: NSRange
        var path: String
        /// the source line the run is part of — runs of one line join without a break
        var line: String?
        var text: String
    }

    /// The selection's code as one string, nil when it covers none.
    static func text(_ storage: NSAttributedString, _ selection: NSRange) -> String? {
        let parts = parts(storage, selection)
        guard !parts.isEmpty else { return nil }
        let files = Set(parts.map(\.path)).count > 1
        var out: [String] = []
        var path: String?, line: String?
        for part in parts {
            if files, part.path != path {
                if path != nil { out.append("") }
                out.append(part.path)
            }
            if let l = part.line, l == line, part.path == path, !out.isEmpty {
                out[out.count - 1] += part.text
            } else {
                out.append(part.text)
            }
            path = part.path
            line = part.line
        }
        return out.joined(separator: "\n")
    }

    /// The code runs `selection` covers, in order. Only paragraphs touching `clip` are read (the
    /// highlight asks per drawn range); the half is still the one the whole selection started on.
    static func parts(_ storage: NSAttributedString, _ selection: NSRange, clip: NSRange? = nil) -> [Part] {
        let s = storage.string as NSString
        let end = min(NSMaxRange(selection), s.length)
        guard selection.length > 0, selection.location < end else { return [] }
        let side = startSide(storage, selection)
        var at = max(selection.location, clip?.location ?? 0)
        let stop = min(end, clip.map(NSMaxRange) ?? end)
        var out: [Part] = []
        while at < stop {
            let para = s.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(para)
            guard let info = storage.attribute(.rvRow, at: para.location, effectiveRange: nil) as? RowInfo else { continue }
            let lo = max(selection.location, para.location) - para.location
            let hi = min(end, NSMaxRange(para)) - para.location
            let body = s.substring(with: para).trimmingCharacters(in: .newlines) as NSString
            out += rowParts(info, body: body, base: para.location, lo: lo, hi: min(hi, body.length), side: side)
        }
        return out
    }

    private static func rowParts(_ info: RowInfo, body: NSString, base: Int, lo: Int, hi: Int, side: Side) -> [Part] {
        switch info.kind {
        case .line:
            if let layout = info.layout {
                let piece = layout.pieces.first { $0.side == side }
                    ?? layout.pieces.first { layout.divider == 0 && $0.line.kind == .ctx }
                guard let piece else { return [] }
                let line = "\(piece.side)|\(piece.line.old ?? -1)|\(piece.line.new ?? -1)"
                if piece.storage.isEmpty {
                    // a blank line: copied whenever the selection runs through it
                    guard lo <= piece.storage.lowerBound, hi >= piece.storage.lowerBound else { return [] }
                    return [Part(range: NSRange(location: base + piece.storage.lowerBound, length: 0), path: info.path, line: line, text: "")]
                }
                let from = max(lo, piece.storage.lowerBound), to = min(hi, piece.storage.upperBound)
                guard from < to else { return [] }
                let text = piece.line.text as NSString
                let first = piece.offsets[from - piece.storage.lowerBound]
                let last = piece.offsets[to - 1 - piece.storage.lowerBound]
                let upper = NSMaxRange(text.rangeOfComposedCharacterSequence(at: last))
                guard first < upper else { return [] }
                return [Part(range: NSRange(location: base + from, length: to - from), path: info.path, line: line,
                             text: text.substring(with: NSRange(location: first, length: upper - first)))]
            }
            let has = side == .right ? info.right != nil : info.left != nil
            guard has else { return [] }
            return code(info, body: body, base: base, lo: lo, hi: hi)
        case .code:
            return code(info, body: body, base: base, lo: lo, hi: hi)
        case .gap, .file, .extras, .note:
            return []
        }
    }

    /// A row whose code is the paragraph from `codeStart` on (unified rows, a whole file's rows).
    private static func code(_ info: RowInfo, body: NSString, base: Int, lo: Int, hi: Int) -> [Part] {
        let from = max(lo, info.codeStart), to = hi
        guard from <= to, info.codeStart <= body.length else { return [] }
        return [Part(range: NSRange(location: base + from, length: to - from), path: info.path, line: nil,
                     text: body.substring(with: NSRange(location: from, length: to - from)))]
    }

    /// The half the selection started on: a split row's by column, any other row's by what it shows.
    private static func startSide(_ storage: NSAttributedString, _ selection: NSRange) -> Side {
        let s = storage.string as NSString
        var at = selection.location
        while at < min(NSMaxRange(selection), s.length) {
            let para = s.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(para)
            guard let info = storage.attribute(.rvRow, at: para.location, effectiveRange: nil) as? RowInfo, info.kind == .line else { continue }
            let lo = max(selection.location, para.location) - para.location
            if let layout = info.layout {
                if layout.divider > 0 {
                    // the row's text runs on tab stops, so its halves part where the left code ends, not at the divider column
                    let leftEnd = layout.pieces.first { $0.side == .left }?.storage.upperBound ?? -1
                    return layout.pieces.contains { $0.side == .right } && lo > leftEnd ? .right : .left
                }
                return (layout.pieces.first { $0.storage.upperBound > lo } ?? layout.pieces.last)?.side == .left ? .left : .right
            }
            return info.right != nil ? .right : .left
        }
        return .right
    }
}

/// The canvas's layout: its selection is drawn over the code a copy takes (`CanvasCopy`), never over
/// a gutter or the other half. The canvas sets no background attributes, so every fill is the selection.
final class CanvasLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let clipped: [(NSRange, [NSRect])]? = MainActor.assumeIsolated {
            guard let view = firstTextView, let storage = textStorage, let container = view.textContainer else { return nil }
            let selection = view.selectedRange()
            guard selection.length > 0 else { return nil }
            let origin = view.textContainerOrigin
            return CanvasCopy.parts(storage, selection, clip: charRange).compactMap { part in
                let range = NSIntersectionRange(part.range, charRange)
                guard range.length > 0 else { return nil }
                var rects: [NSRect] = []
                enumerateEnclosingRects(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
                }
                return (range, rects)
            }
        }
        guard let clipped else { return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color) }
        for (range, rects) in clipped where !rects.isEmpty {
            rects.withUnsafeBufferPointer { super.fillBackgroundRectArray($0.baseAddress!, count: rects.count, forCharacterRange: range, color: color) }
        }
    }
}
