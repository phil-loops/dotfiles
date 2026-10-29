import Foundation

// The code-intelligence answers review/types.ts reads from srv/lsp.py (POST /lsp/hover,
// /lsp/definition, /lsp/type-definition, /lsp/implementation, /lsp/references, /lsp/symbols;
// GET /lsp/src). Every answer may be `{ok:false, state:"loading", message}` while tsgo starts —
// ask again every 500ms for up to 90s, as `asking()` does.

/// The body of an /lsp/* ask: the position plus where to read it — `sha` for a pinned commit, or
/// `branch` (+ `base` for the old side of a diff).
public struct LSPAsk: Encodable, Sendable {
    public var path: String
    public var line: Int?
    public var character: Int?
    /// "new" | "old"
    public var side: String
    public var sha: String?
    public var branch: String?
    public var base: String?
    public init(path: String, line: Int? = nil, character: Int? = nil, side: String = "new", sha: String? = nil, branch: String? = nil, base: String? = nil) {
        self.path = path; self.line = line; self.character = character; self.side = side; self.sha = sha; self.branch = branch; self.base = base
    }
}

public struct LSPHover: Decodable, Sendable {
    public var ok: Bool
    /// markdown
    public var contents: String?
    public var state: String?
    public var message: String?
}

public struct LSPLocation: Decodable, Sendable, Equatable {
    public var path: String
    public var line: Int
    public var character: Int?
    public var endLine: Int?
    public var span: [Int]?
}

public struct LSPLocations: Decodable, Sendable {
    public var ok: Bool
    public var sha: String?
    public var locations: [LSPLocation]?
    public var state: String?
    public var message: String?

    /// A namespace import answers with its whole module (line 1 to the end) — the member is what was meant.
    public var isWholeModule: Bool {
        guard ok, let l = locations, l.count == 1 else { return false }
        return l[0].line == 1 && (l[0].character ?? 0) == 0 && (l[0].endLine ?? 1) > 1
    }
}

public struct LSPSymbols: Decodable, Sendable {
    public struct Symbol: Decodable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var line: Int
        public var endLine: Int
        public var depth: Int
    }
    public var ok: Bool
    public var sha: String?
    public var symbols: [Symbol]?
    public var state: String?
    public var message: String?
}

/// GET /lsp/src?path=&sha= → {text}.
public struct LSPSource: Decodable, Sendable {
    public var text: String?
}

public enum LSPGoto: String, Sendable, CaseIterable {
    case definition, typeDefinition = "type-definition", implementation, references
    public var route: String { "/lsp/\(rawValue)" }
}
