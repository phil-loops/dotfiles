import CanopyCore
import Foundation

/// space a / space A: ask Claude about this change, in the change's one chat. The server (srv/asks.py)
/// owns the chat, the prompt and what is sent; this side only names the subject and the exact code on
/// screen — the tip and base the diff was read at. Both commands are in `actsOnDiff`, so the page's gate
/// holds them while an older read of the diff is showing: the tip they name is always the one on screen.
@MainActor
enum ReviewAsk {
    static func install(_ app: AppModel) {
        let r = app.registry
        let pg = ReviewPageState.of(app)

        /// The change and the code shown, or why there's nothing to ask about yet.
        func shown() throws -> JSONObject {
            guard let target = pg.target, pg.integration == nil else { throw Refusal("ask about a branch — this page is a forest") }
            guard pg.commitScope == nil else { throw Refusal("ask about the whole change — leave the commit view first") }
            guard pg.payload?.key == pg.keyOf, !pg.tip.isEmpty, !pg.baseSha.isEmpty else { throw Refusal("reading the diff — ask once it's in") }
            return ["branch": .string(target.name), "sha": .string(pg.tip), "base": .string(pg.baseSha)]
        }

        func asking(_ body: JSONObject) -> Write {
            Write(path: pg.repoPath("/ask"), body: .object(body), settled: { true },
                  saidFrom: said, failed: "couldn't ask Claude", alone: true)
        }

        r.register(Command(id: "review.ask", title: "Ask Claude about this change — what it's for and any concerns — in its chat",
                           scope: .review, verb: .ask, label: "ask", quiet: true,
                           write: { _, _ in
                               var body = try shown()
                               body["kind"] = "brief"
                               return asking(body)
                           }))
        r.register(Command(id: "review.ask.line", title: "Ask Claude about the line under the cursor, in the change's chat",
                           scope: .review, verb: .askLine, label: "ask line", quiet: true,
                           write: { _, _ in
                               var body = try shown()
                               guard let range = pg.range else { throw Refusal("put the cursor on a line of code") }
                               body.merge(["kind": "line", "path": .string(range.path), "side": .string(range.side.rawValue),
                                           "line": .number(Double(range.line)),
                                           "startLine": range.startLine.map { .number(Double($0)) } ?? .null]) { $1 }
                               return asking(body)
                           }))
        r.place(.branch, ["review.ask", "review.ask.line"])
    }

    /// The status line for the server's answer: what happened to the chat, and how to reach it.
    static func said(_ answer: JSONObject) -> String? {
        let kind = answer["kind"]?.string
        var out: String
        if answer["starting"]?.bool == true {
            out = "its chat is starting · space a again brings it forward"
        } else if kind == "line" {
            out = "typed into its chat · finish the question there"
        } else if answer["reused"]?.bool == true {
            out = answer["moved"]?.bool == true ? "its chat is in front · told it the branch moved" : "its chat is in front"
        } else {
            out = "asked · its chat is answering · space a again brings it forward"
        }
        if let err = answer["forwardErr"]?.string { out += " · couldn't bring it forward: \(err)" }
        return out
    }
}
