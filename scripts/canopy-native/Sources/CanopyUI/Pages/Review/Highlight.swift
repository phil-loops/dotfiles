import AppKit
import Foundation

// A small one-line highlighter for diff lines (review/highlight.ts): comments, strings, numbers,
// keywords and types in TS/JS-shaped code (Python and shell get their comments). A hand-written
// scanner with the web regex's exact semantics, over UTF-16 so a token's range is an NSRange in the
// line — what NSAttributedString wants, with no HTML in between. Pure.

public enum Lang: String, Sendable { case ts, py, sh, plain }

public enum TokenKind: String, Sendable { case comment = "c", string = "s", number = "n", keyword = "k", type = "t" }

public struct Token: Equatable, Sendable {
    public var kind: TokenKind
    /// UTF-16 offsets in the line
    public var location: Int
    public var length: Int
}

private let KW: Set<String> = Set(
    ("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends " +
     "false finally for from function get if implements import in instanceof interface is keyof let new null of private " +
     "protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield " +
     "def elif lambda pass None True False not and or self").split(separator: " ").map(String.init))

@inline(__always) private func isWordUnit(_ c: UInt16) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
}
@inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isIdentStart(_ c: UInt16) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
}
@inline(__always) private func isIdent(_ c: UInt16) -> Bool { isWordUnit(c) || c == 0x24 }
@inline(__always) private func isSpace(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C || c == 0xA0 || c == 0xFEFF || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
        c == 0x202F || c == 0x205F || c == 0x3000 || c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
}

/// The tokens of one line, in order (highlight.ts highlight, minus the HTML).
public func tokens(_ text: String, _ lang: Lang) -> [Token] {
    if lang == .plain { return [] }
    return tokens(Array(text.utf16), lang)
}

public func tokens(_ u: [UInt16], _ lang: Lang) -> [Token] {
    if lang == .plain { return [] }
    let hashComments = lang == .py || lang == .sh
    let n = u.count
    var out: [Token] = []
    var i = 0
    // `.` in the regex stops at line terminators; a diff line has none but \r can ride in
    func toEnd(_ from: Int) -> Int { var j = from; while j < n, u[j] != 0x0D, u[j] != 0x2028, u[j] != 0x2029 { j += 1 }; return j }
    while i < n {
        let c = u[i]
        // ── the comment group ──
        if c == 0x2F, i + 1 < n, u[i + 1] == 0x2F {                       // //.*$
            let e = toEnd(i)
            if e == n { out.append(Token(kind: .comment, location: i, length: e - i)); i = e; continue }
        }
        if c == 0x2F, i + 1 < n, u[i + 1] == 0x2A {                       // /\*.*?(?:\*/|$)
            var j = i + 2
            var end = -1
            while j < n {
                if u[j] == 0x2A, j + 1 < n, u[j + 1] == 0x2F { end = j + 2; break }
                if u[j] == 0x0D || u[j] == 0x2028 || u[j] == 0x2029 { break }
                j += 1
            }
            if end < 0, j == n { end = n }
            if end >= 0 { out.append(Token(kind: .comment, location: i, length: end - i)); i = end; continue }
        }
        if i == 0 {                                                        // ^\s*\*.*$
            var j = 0
            while j < n, isSpace(u[j]) { j += 1 }
            if j < n, u[j] == 0x2A, toEnd(j) == n {
                out.append(Token(kind: .comment, location: 0, length: n)); i = n; continue
            }
        }
        if c == 0x23, !(i + 1 < n && (u[i + 1] == 0x7B || u[i + 1] == 0x5B)) { // #(?![{[]).*$
            let e = toEnd(i)
            if e == n {
                if hashComments { out.append(Token(kind: .comment, location: i, length: n - i)) }
                i = n
                continue
            }
        }
        // ── strings: "…", '…', `…` with escapes, the close optional ──
        if c == 0x22 || c == 0x27 || c == 0x60 {
            var j = i + 1
            while j < n {
                if u[j] == c { j += 1; break }
                if u[j] == 0x5C {
                    if j + 1 < n, u[j + 1] != 0x0A, u[j + 1] != 0x0D, u[j + 1] != 0x2028, u[j + 1] != 0x2029 { j += 2; continue }
                    break
                }
                // [^"\\] matches anything else, terminators included
                j += 1
            }
            out.append(Token(kind: .string, location: i, length: j - i))
            i = j
            continue
        }
        // ── numbers: \b\d[\d_]*(?:\.\d+)?\b ──
        if isDigit(c), i == 0 || !isWordUnit(u[i - 1]) {
            var j = i + 1
            while j < n, isDigit(u[j]) || u[j] == 0x5F { j += 1 }
            let intEnd = j
            var matched = -1
            if j + 1 < n, u[j] == 0x2E, isDigit(u[j + 1]) {
                var k = j + 1
                while k < n, isDigit(u[k]) { k += 1 }
                if k == n || !isWordUnit(u[k]) { matched = k }
            }
            if matched < 0, intEnd == n || !isWordUnit(u[intEnd]) { matched = intEnd }
            if matched >= 0 { out.append(Token(kind: .number, location: i, length: matched - i)); i = matched; continue }
        }
        // ── words ──
        if isIdentStart(c) {
            var j = i + 1
            while j < n, isIdent(u[j]) { j += 1 }
            let word = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
            if KW.contains(word) { out.append(Token(kind: .keyword, location: i, length: j - i)) }
            else if c >= 0x41 && c <= 0x5A { out.append(Token(kind: .type, location: i, length: j - i)) }
            i = j
            continue
        }
        i += 1
    }
    return out
}

public func langOf(_ path: String) -> Lang {
    let ext = (path.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased()
    if ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "json", "css", "go", "rs", "java", "c", "h", "swift", "kt", "prisma", "sql"].contains(ext) { return .ts }
    if ext == "py" { return .py }
    if ["sh", "zsh", "bash", "toml", "yml", "yaml"].contains(ext) || !path.contains(".") { return .sh }
    return .plain
}

/// The highlight palette (v2.css .hl-*), as AppKit colors for the diff's attributed text.
public struct CodeColors {
    public var ink: NSColor
    public var inkDim: NSColor
    public var inkFaint: NSColor
    public var keyword = NSColor(srgbRed: 0xD9 / 255, green: 0xA3 / 255, blue: 0x5B / 255, alpha: 1)
    public var string = NSColor(srgbRed: 0xA9 / 255, green: 0xC0 / 255, blue: 0x8A / 255, alpha: 1)
    public var number = NSColor(srgbRed: 0xC9 / 255, green: 0xA3 / 255, blue: 0xD6 / 255, alpha: 1)
    public var type = NSColor(srgbRed: 0x8F / 255, green: 0xB8 / 255, blue: 0xC9 / 255, alpha: 1)

    public func color(_ k: TokenKind) -> NSColor {
        switch k {
        case .comment: inkFaint
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        }
    }
}
