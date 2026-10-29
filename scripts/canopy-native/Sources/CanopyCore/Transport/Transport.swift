import Foundation

/// The gesture that sent a write (sync.ts `via`). The server refuses GitHub writes without a key
/// or a click (srv/ghreview.py refusal()).
public enum Via: String, Sendable { case key, click, palette, menu, drag }

/// A write's answer — sync.ts `Sent`.
public struct Sent: Sendable {
    public enum Outcome: String, Sendable { case ok, refused, failed }
    public var ok: Bool
    public var outcome: Outcome
    public var err: String?
    public var rid: String
    public var body: JSONObject?
}

public struct HTTPError: Error, CustomStringConvertible {
    public var path: String
    public var status: Int
    public var description: String { "\(path) → \(status)" }
}

/// The app's only door to the server — a port of v2/sync.ts's request half. Every request carries
/// X-Stack-Actor and X-Request-Id (the server writes the rid into its request log, so a client
/// timing joins the server's); writes add X-Stack-Via.
public final class Transport: @unchecked Sendable {
    /// The server's actor enum (srv/actor.py ACTORS) has no native value; an unknown header falls
    /// through to User-Agent sniffing and lands as "unknown". "browser" is the actor that means
    /// "Phil's own hand": telemetry counts only it, and GitHub writes require it. See API.md.
    public static let actor = "browser"
    public static let userAgent = "canopy-native/0.1"

    public let base: URL
    /// This launch's id, the prefix of every X-Request-Id (sync.ts PAGE_LOAD).
    public let pageLoad: String
    /// Repos the server serves (`window.__VIEWER_REPOS__`), for `atRepo`. Set from the bootstrap.
    public var repos: [String] {
        get { lock.withLock { _repos } }
        set { lock.withLock { _repos = newValue } }
    }
    /// High-frequency facts (a post, an ask) for the page-load aggregate; Telemetry installs it.
    public var count: (@Sendable (String, Double?) -> Void)?

    let session: URLSession
    let streaming: URLSession
    private let lock = NSLock()
    private var seq = 0
    private var _repos: [String] = []

    /// `protocolClasses` lets tests answer requests with a URLProtocol stub.
    public init(base: URL, protocolClasses: [AnyClass]? = nil) {
        self.base = base
        self.pageLoad = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        c.timeoutIntervalForRequest = 120
        if let protocolClasses { c.protocolClasses = protocolClasses }
        session = URLSession(configuration: c)
        let s = URLSessionConfiguration.ephemeral
        s.requestCachePolicy = .reloadIgnoringLocalCacheData
        s.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        s.timeoutIntervalForRequest = 60 * 60 * 24
        s.timeoutIntervalForResource = 60 * 60 * 24 * 7
        if let protocolClasses { s.protocolClasses = protocolClasses }
        streaming = URLSession(configuration: s)
    }

    public convenience init(port: Int) {
        self.init(base: URL(string: "http://127.0.0.1:\(port)")!)
    }

    public func nextRid() -> String {
        lock.withLock { seq += 1; return "\(pageLoad)-\(seq)" }
    }

    /// `path` is the server path with its query ("/node?branch=x").
    public func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    /// A repo-pinned server path: the server reads the repo from the leading segment (model.ts atRepo).
    public func atRepo(_ repo: String, _ path: String) -> String {
        guard repos.contains(repo) else { return path }
        return "/\(repo.uriComponent)\(path)"
    }

    func request(_ path: String, method: String = "GET", rid: String, json: Data? = nil, via: Via? = nil) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.setValue(Self.actor, forHTTPHeaderField: "X-Stack-Actor")
        r.setValue(rid, forHTTPHeaderField: "X-Request-Id")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = json
        }
        if let via { r.setValue(via.rawValue, forHTTPHeaderField: "X-Stack-Via") }
        return r
    }

    // ── reads ──

    public func getData(_ path: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request(path, rid: nextRid()))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(path: path, status: status) }
        return data
    }

    public func getJSON<T: Decodable>(_ path: String, as _: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await getData(path))
    }

    /// GET a text body (a file at a commit), or nil.
    public func getText(_ path: String) async -> String? {
        guard let d = try? await getData(path) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// A read the server takes as a POST (/lsp/hover, /lsp/definition, …). Never a write.
    public func ask<T: Decodable>(_ path: String, _ body: some Encodable, as _: T.Type = T.self) async -> T? {
        let t0 = Date()
        guard let json = try? JSONEncoder().encode(body),
              let (data, resp) = try? await session.data(for: request(path, method: "POST", rid: nextRid(), json: json))
        else { return nil }
        count?("ask", Date().timeIntervalSince(t0) * 1000)
        guard let status = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // ── writes ──

    /// POST a write. A 200 `{ok:false}` is a refusal (the server's reason rides in X-Stack-Refused);
    /// a 4xx is a refusal too, a 5xx or no answer a failure.
    public func post(_ path: String, _ body: some Encodable, via: Via? = nil) async -> Sent {
        let rid = nextRid()
        let t0 = Date()
        guard let json = try? JSONEncoder().encode(body) else {
            return Sent(ok: false, outcome: .failed, err: "encode", rid: rid)
        }
        do {
            let (data, resp) = try await session.data(for: request(path, method: "POST", rid: rid, json: json, via: via))
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let obj = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object ?? [:]
            count?("post", Date().timeIntervalSince(t0) * 1000)
            let httpOK = (200..<300).contains(status)
            if httpOK && obj["ok"] != .bool(false) { return Sent(ok: true, outcome: .ok, rid: rid, body: obj) }
            let refused = http?.value(forHTTPHeaderField: "X-Stack-Refused").flatMap { $0.isEmpty ? nil : $0 }
            let err = refused ?? (httpOK ? "refused" : "http-\(status)")
            return Sent(ok: false, outcome: httpOK || status < 500 ? .refused : .failed, err: err, rid: rid, body: obj)
        } catch {
            return Sent(ok: false, outcome: .failed, err: "network", rid: rid)
        }
    }

    /// POST, then read the answer as server-sent events (a tutor turn, a chat turn): each frame
    /// goes to `on`, which returns true at the stream's last frame — the server holds the
    /// connection open after it. Throws when the server won't stream.
    public func streamPost(_ path: String, _ body: some Encodable, on: (SSEFrame) -> Bool) async throws {
        let t0 = Date()
        defer { count?("stream", Date().timeIntervalSince(t0) * 1000) }
        let json = try JSONEncoder().encode(body)
        let (bytes, resp) = try await streaming.bytes(for: request(path, method: "POST", rid: nextRid(), json: json))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(path: path, status: status) }
        for try await f in bytes.sseFrames() where on(f) { return }
    }

    /// Open a GET server-sent-event stream (/v2/events, /events).
    public func events(_ path: String) async throws -> AsyncThrowingStream<SSEFrame, Error> {
        var r = request(path, rid: nextRid())
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await streaming.bytes(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(path: path, status: status) }
        return bytes.sseFrames()
    }
}

public extension String {
    /// encodeURIComponent: a query value or a single path segment.
    var uriComponent: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")) ?? self
    }
}
