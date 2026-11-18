import AppKit
import CanopyCore

struct DiffSourceMark: Equatable {
    var side: Side
    var at: Range<Int>
}

struct DiffPiece {
    var side: Side
    var line: DiffLine
    var text: String
    var storage: Range<Int>
    var offsets: [Int]

    func source(at storageOffset: Int) -> Int? {
        guard storage.contains(storageOffset) else { return nil }
        return offsets[storageOffset - storage.lowerBound]
    }

    var sourceRange: Range<Int>? {
        guard let first = offsets.first, let last = offsets.last else { return nil }
        return first..<last + 1
    }

    func storage(for source: Range<Int>) -> Range<Int>? {
        func lowerBound(_ value: Int) -> Int {
            var low = 0, high = offsets.count
            while low < high {
                let middle = (low + high) / 2
                if offsets[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let first = lowerBound(source.lowerBound), end = lowerBound(source.upperBound)
        guard first < end else { return nil }
        return (storage.lowerBound + first)..<(storage.lowerBound + end)
    }
}

struct DiffDisplayRow {
    var text: String
    var pieces: [DiffPiece]
    var tabs: [Int]
    var divider: Int
    var continuation: Bool
    var stacked = false

    func source(at storageOffset: Int) -> DiffSourceMark? {
        for piece in pieces {
            if let at = piece.source(at: storageOffset) { return DiffSourceMark(side: piece.side, at: at..<at + 1) }
        }
        return nil
    }

    func storage(for mark: DiffSourceMark) -> [Range<Int>] {
        pieces.filter { $0.side == mark.side }.compactMap { $0.storage(for: mark.at) }
    }
}

@MainActor
enum DiffLayout {
    static let gutter = 6
    static let minimumSideColumns = 24
    private static let separator = 1
    private static let splitOverhead = gutter * 2 + separator
    private struct Unit {
        var text: String
        var offsets: [Int]
        var cells: Int
        var space: Bool
    }

    private struct Chunk {
        var text: String
        var offsets: [Int]
    }

    /// The hunks that render split: every hunk of a file that removes AND adds lines anywhere —
    /// a block moved from one hunk to another stays old-left/new-right, never one column mixing
    /// both numberings (2026-11-18). A wholly one-sided file (+N −0, or a deletion) has no other
    /// side to show, so none of its hunks split.
    static func pairedHunks(_ rows: [DiffRow]) -> Set<Int> {
        guard rows.contains(where: { $0.left?.kind == .del }), rows.contains(where: { $0.right?.kind == .add }) else { return [] }
        return Set(rows.map(\.hunk))
    }

    static func rows(_ row: DiffRow, columns: Int, paired: Bool) -> [DiffDisplayRow] {
        let columns = columns > 0 ? columns : 133
        let split = paired && columns >= minimumSideColumns * 2 + splitOverhead
        let width = split ? max(1, (columns - splitOverhead) / 2) : max(1, columns - gutter)
        let left = row.left.map { chunks($0.text, width: width) } ?? []
        let rightWidth = split ? max(1, columns - width - splitOverhead) : width
        let right = row.right.map { chunks($0.text, width: rightWidth) } ?? []
        if split {
            return (0..<max(left.count, right.count)).map { i in
                display(left: i < left.count ? (row.left!, left[i]) : nil,
                        right: i < right.count ? (row.right!, right[i]) : nil,
                        divider: width + gutter + separator, continuation: i > 0)
            }
        }
        if row.left?.kind == .del, row.right?.kind == .add {
            return left.enumerated().map { display(left: (row.left!, $0.element), right: nil, divider: 0, continuation: $0.offset > 0, stacked: true) }
                + right.enumerated().map { display(left: nil, right: (row.right!, $0.element), divider: 0, continuation: $0.offset > 0, stacked: true) }
        }
        if let line = row.right {
            return right.enumerated().map { display(left: nil, right: (line, $0.element), divider: 0, continuation: $0.offset > 0) }
        }
        return left.enumerated().map { display(left: (row.left!, $0.element), right: nil, divider: 0, continuation: $0.offset > 0) }
    }

    private static func display(left: (DiffLine, Chunk)?, right: (DiffLine, Chunk)?, divider: Int, continuation: Bool, stacked: Bool = false) -> DiffDisplayRow {
        var text = "", pieces: [DiffPiece] = []
        func put(_ pair: (DiffLine, Chunk)?, side: Side) {
            guard let (line, chunk) = pair else { return }
            let start = text.utf16.count
            text += chunk.text
            pieces.append(DiffPiece(side: side, line: line, text: chunk.text, storage: start..<text.utf16.count, offsets: chunk.offsets))
        }
        func number(_ n: Int?) -> String {
            let value = continuation ? "" : n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, gutter - 1 - value.count)) + value
        }
        if divider > 0 {
            text += number(left?.0.old) + "\t"
            put(left, side: .left)
            text += "\t" + number(right?.0.new) + "\t"
            put(right, side: .right)
            return DiffDisplayRow(text: text, pieces: pieces, tabs: [gutter, divider, divider + gutter], divider: divider, continuation: continuation)
        }
        text += number(right?.0.new ?? left?.0.old) + "\t"
        put(left, side: .left)
        put(right, side: .right)
        return DiffDisplayRow(text: text, pieces: pieces, tabs: [gutter], divider: 0, continuation: continuation, stacked: stacked)
    }

    private static func chunks(_ source: String, width: Int) -> [Chunk] {
        var units: [Unit] = [], offset = 0, column = 0
        for character in source {
            let text = String(character), count = text.utf16.count
            let rendered: String
            let cells: Int
            let offsets: [Int]
            if character == "\t" {
                cells = 4 - column % 4
                rendered = String(repeating: " ", count: cells)
                offsets = Array(repeating: offset, count: cells)
            } else {
                rendered = character.isNewline ? "␤" : text
                cells = text.utf8.count == 1 ? 1 : max(1, Int(ceil((rendered as NSString).size(withAttributes: [.font: DocFont.font]).width / DocFont.charWidth - 0.01)))
                offsets = rendered == text ? Array(offset..<offset + count) : [offset]
            }
            units.append(Unit(text: rendered, offsets: offsets, cells: cells, space: character.isWhitespace))
            offset += count
            column += cells
        }
        guard !units.isEmpty else { return [Chunk(text: "", offsets: [])] }
        var result: [Chunk] = [], start = 0
        while start < units.count {
            var end = start, cells = 0, space: Int?
            while end < units.count, cells + units[end].cells <= width || end == start {
                cells += units[end].cells
                if units[end].space, cells >= width / 2 { space = end + 1 }
                end += 1
            }
            if end < units.count, let space { end = space }
            result.append(Chunk(text: units[start..<end].map(\.text).joined(), offsets: units[start..<end].flatMap(\.offsets)))
            start = end
        }
        return result
    }
}
