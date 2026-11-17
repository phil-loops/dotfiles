import Foundation
import Testing
@testable import Show

/// ThreadDelivery's reply lifecycle against a stub `canopy-work` (SHOW_CANOPY_WORK) and scratch prefs: no app, window,
/// session or real work journal is touched.
@MainActor
final class DeliveryFixture {
    let dir: URL
    let deck: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("show-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        deck = dir.appendingPathComponent("deck.json").path
        let deckJSON: [String: Any] = ["title": "T", "work": "item", "sections": [["id": "s", "title": "S"]],
                                       "agent": ["session": "11111111-2222-3333-4444-555555555555"]]
        try JSONSerialization.data(withJSONObject: deckJSON).write(to: URL(fileURLWithPath: deck))
        let stub = dir.appendingPathComponent("canopy-work").path
        try Self.stub.write(toFile: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        setenv("SHOW_CANOPY_WORK", stub, 1)
        setenv("STUB_DIR", dir.path, 1)
        prefs = UserDefaults(suiteName: "show-delivery-\(UUID().uuidString)")!
        ThreadDelivery.turnPoll = 0.05
        ThreadDelivery.queuePoll = 0.05
    }

    func set(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }

    func log() -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func submission(_ text: String, revision: Int) -> ThreadDelivery.Submission {
        .init(id: UUID().uuidString.lowercased(), section: "s", text: text, workId: "w_1", generation: 1,
              sentAt: ISO8601DateFormatter().string(from: Date()), draftRevision: revision)
    }

    /// Answers each subcommand the way the journal would; files in STUB_DIR choose turn states and recovery's delay.
    static let stub = """
    #!/usr/bin/env python3
    import json, os, sys, time
    d = os.environ["STUB_DIR"]
    args = sys.argv[1:]
    cmd = args[0]
    def read(name, default=None):
        p = os.path.join(d, name)
        return open(p).read().strip() if os.path.exists(p) else default
    def bump(name):
        n = int(read(name, "0")) + 1
        open(os.path.join(d, name), "w").write(str(n))
        return n
    def log(line):
        open(os.path.join(d, "log"), "a").write(line + "\\n")
    if cmd == "show-bind":
        print(json.dumps({"work_id": "w_1", "generation": 1, "replaced": False}))
    elif cmd == "show-submit":
        env = json.loads(sys.stdin.read())
        n = bump("outbox")
        log("submit " + env["text"])
        print(json.dumps({"seq": n, "outbox_id": n, "message_id": "m%d" % n}))
    elif cmd == "show-deliver":
        n = args[args.index("--outbox") + 1]
        log("deliver " + n)
        print(json.dumps({"delivery": {"outbox_id": int(n), "state": "delivered", "receipt_id": "r" + n}}))
    elif cmd == "show-recover":
        log("recover started")
        time.sleep(float(read("recover-delay", "0")))
        print(read("recover.json", '{"sections": {}}'))
        log("recover done")
    elif cmd == "turn":
        r = args[args.index("--receipt") + 1]
        log("turn " + r)
        print(json.dumps({"state": read("turn-" + r, "running"), "detail": "stub " + r}))
    """
}

@MainActor
@Suite(.serialized) struct ThreadDeliveryTests {
    func failed(_ d: ThreadDelivery) -> String? {
        if case .failed(let detail) = d.status["s"] { return detail }
        return nil
    }

    @Test func anOlderRepliesTurnCannotOverwriteTheNewerOnesStatus() async throws {
        let fx = try DeliveryFixture()
        let d = ThreadDelivery(deckPath: fx.deck)
        d.open(sections: [(key: "s", todo: "item", replyTo: nil)])
        #expect(await fx.until { d.bindings["s"] != nil })
        d.submit(fx.submission("A", revision: 1), replyTo: nil)
        #expect(await fx.until { fx.log().contains("turn r1") })
        d.submit(fx.submission("B", revision: 2), replyTo: nil)
        #expect(await fx.until { fx.log().contains("turn r2") })
        try fx.set("turn-r1", "failed")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(failed(d) == nil, "A's failed turn must not land on B's delivery")
        #expect(d.status["s"] == nil)
        try fx.set("turn-r2", "failed")
        #expect(await fx.until { failed(d) != nil })
        #expect(failed(d)?.contains("stub r2") == true, "the current reply's own failure stays visible")
    }

    @Test func slowRecoveryNeitherDelaysCaptureNorOverwritesANewerReply() async throws {
        let fx = try DeliveryFixture()
        try fx.set("recover-delay", "1.5")
        try fx.set("recover.json", #"{"sections": {"s": {"outbox_id": 99, "state": "uncertain", "error": "old hand-off"}}}"#)
        let d = ThreadDelivery(deckPath: fx.deck)
        var captured: [String] = []
        d.onCaptured = { submission, _ in captured.append(submission.text) }
        d.open(sections: [(key: "s", todo: "item", replyTo: nil)])
        #expect(await fx.until { d.bindings["s"] != nil && fx.log().contains("recover started") })
        d.submit(fx.submission("B", revision: 1), replyTo: nil)
        #expect(await fx.until(1.0) { captured == ["B"] }, "capture doesn't wait behind recovery's dispatch")
        #expect(!fx.log().contains("recover done"))
        #expect(await fx.until { fx.log().contains("recover done") && fx.log().contains("deliver 1") })
        try? await Task.sleep(nanoseconds: 200_000_000)
        if case .uncertain = d.status["s"] { Issue.record("recovery's older row overwrote the newer reply's state") }
    }

    @Test func quickRepliesAreAllKeptAndCapturedInOrder() async throws {
        let fx = try DeliveryFixture()
        let d = ThreadDelivery(deckPath: fx.deck)
        d.open(sections: [(key: "s", todo: "item", replyTo: nil)])
        #expect(await fx.until { d.bindings["s"] != nil })
        let a = fx.submission("A", revision: 1), b = fx.submission("B", revision: 2), c = fx.submission("C", revision: 3)
        d.submit(a, replyTo: nil)
        d.submit(b, replyTo: nil)
        d.submit(c, replyTo: nil)
        #expect(Set(d.pendingSubmissions().keys) == [a.id, b.id, c.id], "every reply is kept by id before any is captured")
        #expect(await fx.until { fx.log().filter { $0.hasPrefix("submit") } == ["submit A", "submit B", "submit C"] })
        #expect(await fx.until { d.pendingSubmissions().isEmpty }, "each submission is kept until the journal holds it")
    }

    @Test func submissionsSurviveARelaunchAndAreResubmitted() async throws {
        let fx = try DeliveryFixture()
        let a = fx.submission("A", revision: 1)
        prefs.set(try JSONEncoder().encode([a.id: a]), forKey: "thread.submit.\(fx.deck)")
        let relaunched = ThreadDelivery(deckPath: fx.deck)
        relaunched.open(sections: [(key: "s", todo: "item", replyTo: nil)])
        #expect(await fx.until { fx.log().contains("submit A") && relaunched.pendingSubmissions().isEmpty })
    }
}
