import CanopyCore
import Foundation

struct CaptureFixture: Sendable {
    struct Key: Hashable, Sendable {
        let method: String
        let path: String
        let query: JSONValue
        let body: JSONValue?
    }
    struct Answer: Sendable {
        let status: Int
        let type: String
        let data: Data
        var stream = false
        var missing = false
    }
    private struct Entry: Decodable {
        let method: String
        let path: String
        let query: [String: String]?
        let request: JSONValue?
        let body: JSONValue?
        let text: String?
        let status: Int?

        private enum CodingKeys: String, CodingKey { case method, path, query, request, body, text, status }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            method = try values.decode(String.self, forKey: .method)
            path = try values.decode(String.self, forKey: .path)
            query = try values.decodeIfPresent([String: String].self, forKey: .query)
            if values.contains(.request) { request = try values.decode(JSONValue.self, forKey: .request) }
            else { request = nil }
            if values.contains(.body) { body = try values.decode(JSONValue.self, forKey: .body) }
            else { body = nil }
            text = try values.decodeIfPresent(String.self, forKey: .text)
            status = try values.decodeIfPresent(Int.self, forKey: .status)
        }
    }
    private let state: Data
    private let bootstrap: Data
    private let hello: Data
    private let answers: [Key: Answer]
    private static let streams: Set<String> = ["/events", "/v2/events"]
    private static let builtins: Set<String> = ["/state", "/v2", "/events", "/v2/events"]
    private static let asks: Set<String> = [
        "syntax/units", "lsp/hover", "lsp/definition", "lsp/type-definition", "lsp/implementation", "lsp/references",
        "lsp/symbols", "lsp/workspace-symbols", "lsp/prepare"
    ]

    init(directory: String?) throws {
        guard let directory, !directory.isEmpty else {
            throw Refusal("--shoot requires --shoot-fixture <directory>; live hydration can release queued replies")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        state = try LocalDocumentFile.read(root.appendingPathComponent("state.json")).data
        let snapshot = try Snapshot.decode(state)
        let raw = try JSONDecoder().decode(JSONValue.self, from: state)
        guard !snapshot.epoch.isEmpty, raw["entities"]?.object != nil else { throw Refusal("capture state needs an epoch and entities") }
        let repos = snapshot.entities.repo.values.keys.sorted()
        let encodedRepos = String(decoding: try JSONEncoder().encode(repos), as: UTF8.self)
        bootstrap = Data("<script>window.__VIEWER_REPOS__=\(encodedRepos);window.__CANOPY_KEYS__={\"keys\":{},\"errors\":[]};window.__CANOPY_ASSET__=\"capture-fixture\"</script>".utf8)
        let frame: JSONValue = ["epoch": .string(snapshot.epoch), "asset": "capture-fixture"]
        hello = Data("event: hello\ndata: \(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))\n\n".utf8)
        let manifest = root.appendingPathComponent("responses.json")
        var entries: [Entry] = []
        do { entries = try JSONDecoder().decode([Entry].self, from: LocalDocumentFile.read(manifest).data) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        var answers: [Key: Answer] = [:]
        for entry in entries {
            guard ["GET", "POST"].contains(entry.method), entry.path.hasPrefix("/"),
                  let url = URL(string: "http://127.0.0.1:1\(entry.path)"), url.path == entry.path, url.query == nil, url.fragment == nil,
                  !Self.builtins.contains(entry.path), (200...599).contains(entry.status ?? 200),
                  (entry.body == nil) != (entry.text == nil), entry.method != "GET" || entry.request == nil else {
                throw Refusal("invalid capture fixture response: \(entry.method) \(entry.path)")
            }
            let key = Key(method: entry.method, path: entry.path, query: .object((entry.query ?? [:]).mapValues(JSONValue.string)), body: entry.request)
            guard answers[key] == nil else { throw Refusal("duplicate capture fixture response: \(entry.method) \(entry.path)") }
            let data = try entry.body.map { try JSONEncoder().encode($0) } ?? Data((entry.text ?? "").utf8)
            answers[key] = Answer(status: entry.status ?? 200, type: entry.text == nil ? "application/json" : "text/plain", data: data)
        }
        self.answers = answers
    }

    func answer(_ request: URLRequest, body: Data? = nil) -> Answer {
        let missing = Answer(status: 403, type: "application/json", data: Data(#"{"ok":false,"err":"missing-capture-fixture"}"#.utf8), missing: true)
        guard let url = request.url, url.scheme == "http", url.host == "127.0.0.1",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return missing }
        let method = request.httpMethod ?? "GET"
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard query[item.name] == nil else { return missing }
            query[item.name] = item.value ?? ""
        }
        if method == "GET" {
            if url.path == "/state" { return Answer(status: 200, type: "application/json", data: state) }
            if url.path == "/v2" { return Answer(status: 200, type: "text/html", data: bootstrap) }
            if Self.streams.contains(url.path) { return Answer(status: 200, type: "text/event-stream", data: hello, stream: true) }
        } else {
            let segments = url.path.split(separator: "/").map(String.init)
            let candidates = [segments.joined(separator: "/"), segments.dropFirst().joined(separator: "/")]
            guard method == "POST", request.value(forHTTPHeaderField: "X-Stack-Write") == nil,
                  candidates.contains(where: Self.asks.contains) else {
                return Answer(status: 403, type: "application/json", data: Data(#"{"ok":false,"err":"capture-read-only"}"#.utf8))
            }
        }
        let data = body ?? request.httpBody
        let decoded: JSONValue?
        if let data {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return missing }
            decoded = value
        } else { decoded = nil }
        let key = Key(method: method, path: url.path, query: .object(query.mapValues(JSONValue.string)), body: decoded)
        return answers[key] ?? missing
    }
}

final class CaptureFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var fixtures: [Int: CaptureFixture] = [:]
    nonisolated(unsafe) private static var missing: [Int: Set<String>] = [:]
    private static let lock = NSLock()
    static func install(_ fixture: CaptureFixture, port: Int) { lock.withLock { fixtures[port] = fixture; missing[port] = [] } }
    static func requireComplete(port: Int) throws {
        let count = lock.withLock { missing[port]?.count ?? 0 }
        guard count == 0 else { throw Refusal("\(count) capture fixture responses missing; no further images written") }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.port ?? 0] }) else {
            client?.urlProtocol(self, didFailWithError: Refusal("capture fixture unavailable"))
            return
        }
        let body: Data?
        do { body = try request.httpBody ?? request.httpBodyStream.map(Self.drain) }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        let answer = fixture.answer(request, body: body)
        if answer.missing {
            let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
            let signature = "\(request.httpMethod ?? "GET") \(url.path)?\(query) \(body.map { String(decoding: $0, as: UTF8.self) } ?? "")"
            _ = Self.lock.withLock { Self.missing[url.port ?? 0, default: []].insert(signature) }
            FileHandle.standardError.write(Data("shoot: missing fixture for \(signature)\n".utf8))
        }
        let headers = ["Content-Type": answer.type]
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.data)
        if !answer.stream { client?.urlProtocolDidFinishLoading(self) }
    }

    private static func drain(_ stream: InputStream) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw Refusal("capture request body unavailable") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= LocalDocumentFile.limit else { throw Refusal("capture request body too large") }
        }
        return data
    }

    override func stopLoading() {}
}
