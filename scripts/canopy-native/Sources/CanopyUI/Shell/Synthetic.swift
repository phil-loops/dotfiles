import CanopyCore
import Foundation

/// `canopy --bench --synthetic <n>`: a store and a review generated at a size, so the bench shows work
/// that rebuilds everything on each change — which today's data is too small to show (bench-at-scale).
/// n branches across n/25 forests, stacked five deep, every third with an open PR, six forests in the
/// focus lane; and a review diff of n/10 files, 30 lines removed and 30 added in each. Nothing reaches
/// a server: GETs are answered here (`SyntheticServer`), writes too.
enum Synthetic {
    static let repo = "loops"

    static func snapshot(_ n: Int) -> Data {
        let forests = max(1, n / 25)
        var projects: [String: Any] = [:], branches: [String: Any] = [:], prs: [String: Any] = [:]
        for f in 0..<forests {
            let p = "forest-\(f)"
            projects["\(repo):\(p)"] = ["id": "\(repo):\(p)", "repo": repo, "name": p, "state": f < 6 ? "focus" : "workbench",
                                        "rank": f < 6 ? (f + 1) as Any : NSNull() as Any, "ticket": NSNull(), "summary": "a synthetic forest of the bench",
                                        "size": 25]
        }
        for i in 0..<n {
            let f = i % forests, inForest = i / forests
            let p = "forest-\(f)", name = "f\(f)-branch-\(inForest)"
            let parent = inForest % 5 == 0 ? "main" : "f\(f)-branch-\(inForest - 1)"
            let id = "\(repo):\(name)"
            let sha = String(format: "%040x", i + 1)
            branches[id] = ["id": id, "repo": repo, "name": name, "project": "\(repo):\(p)", "parent": parent,
                            "parentId": parent == "main" ? NSNull() as Any : "\(repo):\(parent)" as Any,
                            "description": "branch \(i) of the synthetic bench", "subject": "feat: step \(i)", "commits": 2,
                            "outline": ["feat: step \(i)", "follow up"], "tip": sha, "tree": sha, "pushed": i % 3 == 0 ? "synced" : "local",
                            "ahead": 0, "gates": ["green", "red", "stale", "none"][i % 4], "redGates": i % 4 == 1 ? ["typecheck"] : [],
                            "order": inForest + 1, "holdUntil": NSNull(), "behind": i % 7, "drifted": false, "upstream": "",
                            "upstreamBad": false, "diverged": false]
            if i % 3 == 0 {
                prs[id] = ["id": id, "repo": repo, "branch": name, "project": "\(repo):\(p)", "number": 10_000 + i,
                           "url": "https://github.invalid/pull/\(10_000 + i)", "state": "OPEN", "review": i % 2 == 0 ? "APPROVED" : "REVIEW_REQUIRED",
                           "draft": false, "base": "main", "approvals": i % 2, "mergeState": "CLEAN", "mergeable": "MERGEABLE",
                           "approvedAt": NSNull(), "title": NSNull()]
            }
        }
        let snap: [String: Any] = [
            "epoch": "synthetic", "versions": ["git": 1, "remote": 1, "review": 1, "todo": 1], "ms": 0,
            "entities": ["repo": [repo: ["id": repo, "name": repo, "main": "main", "trunk": String(repeating: "0", count: 40)]],
                         "project": projects, "branch": branches, "pr": prs, "warm": [repo: ["id": repo, "prs": true]]],
        ]
        return try! JSONSerialization.data(withJSONObject: snap)
    }

    /// The review page's diff: n/10 files, each one hunk of 30 removed and 30 added lines in context.
    static func node(_ n: Int, branch: String) -> Data {
        var files: [[String: Any]] = []
        for f in 0..<max(1, n / 10) {
            var patch = "@@ -1,66 +1,66 @@ export function f\(f)() {\n"
            for k in 0..<3 { patch += "   const ctx\(k) = \(k);\n" }
            for k in 0..<30 { patch += "-  const old\(k) = compute(\(k), \"before\");\n" }
            for k in 0..<30 { patch += "+  const value\(k) = compute(\(k), \"after\", options);\n" }
            for k in 0..<3 { patch += "   return ctx\(k);\n" }
            files.append(["path": "lib/synthetic/file-\(f).ts", "add": 30, "del": 30, "patch": patch])
        }
        return try! JSONSerialization.data(withJSONObject: ["branch": branch, "baseSha": "base", "files": files])
    }
}

/// Answers every request of a `--synthetic` bench: the review diff on /node, empty lists and objects
/// elsewhere, and every write `ok` — nothing leaves the process.
final class SyntheticServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var size = 300
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let path = url.path
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body: Data
        if (request.httpMethod ?? "GET") != "GET" {
            body = Data(#"{"ok":true}"#.utf8)
        } else if path.hasSuffix("/node") {
            body = Synthetic.node(Self.size, branch: q.first { $0.name == "branch" }?.value ?? "")
        } else if path.hasSuffix("/commits") || path.hasSuffix("/review-requests") {
            body = Data("[]".utf8)
        } else {
            body = Data("{}".utf8)
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
