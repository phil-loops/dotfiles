import Foundation

/// One server-sent event: its `event:` name ("message" when unnamed) and its joined `data:`.
public struct SSEFrame: Equatable, Sendable {
    public var event: String
    public var data: String
    public init(event: String, data: String) { self.event = event; self.data = data }

    public var json: JSONObject? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)))?.object
    }
}

/// Incremental SSE parser, fed one line at a time (no trailing newline). A blank line ends a
/// frame; `:` lines are comments (the server's `: ping`); frames without data are dropped, as
/// EventSource drops them.
public struct SSEParser {
    private var event = ""
    private var data: [String] = []

    public init() {}

    public mutating func feed(line raw: String) -> SSEFrame? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { event = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEFrame(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value) = Self.split(line)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    private static func split(_ line: String) -> (String, String) {
        guard let i = line.firstIndex(of: ":") else { return (line, "") }
        var v = line[line.index(after: i)...]
        if v.hasPrefix(" ") { v = v.dropFirst() }
        return (String(line[..<i]), String(v))
    }

    /// Every complete frame in a block of text (tests, fixtures).
    public static func frames(in text: String) -> [SSEFrame] {
        var p = SSEParser()
        var out: [SSEFrame] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = p.feed(line: String(line)) { out.append(f) }
        }
        return out
    }
}

extension URLSession.AsyncBytes {
    /// The response body as SSE frames. Splits on raw bytes: `AsyncLineSequence` skips blank lines,
    /// which are exactly the frame boundaries.
    public func sseFrames() -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var parser = SSEParser()
                var buf: [UInt8] = []
                do {
                    for try await byte in self {
                        if byte == 0x0A {
                            if let f = parser.feed(line: String(decoding: buf, as: UTF8.self)) { cont.yield(f) }
                            buf.removeAll(keepingCapacity: true)
                        } else {
                            buf.append(byte)
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
