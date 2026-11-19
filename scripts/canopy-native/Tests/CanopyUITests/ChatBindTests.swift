import CanopyTestSupport
import CanopyCore
import Testing
@testable import CanopyUI

/// Binding a chat by click (DESIGN.md round 27, P7): the write names the chat by its full id and carries the
/// binding generation the view showed, so the server can refuse a decision made from a stale view.
@MainActor @Suite struct ChatBindTests {
    @Test func aClickPostsTheChatTheBranchAndTheGenerationItSaw() async throws {
        let (app, port) = try ShipTests().app { _ in }
        ShipStub.answer(port, "POST", "/loops/chat-bind", #"{"ok":true,"work":"w_x","generation":4}"#)
        let session = "aaaaaaaa-0000-4000-8000-000000000001"
        app.runner.dispatch("chat.bind.to", via: .key, target: ShipTests.branch, arg: ChatBindArg(session: session, generation: 3))
        await until("the bind request") { !ShipStub.posts(port).isEmpty }
        let post = try #require(ShipStub.posts(port).first)
        #expect(post.path == "/loops/chat-bind")
        #expect(post.body["session"] == .string(session))
        #expect(post.body["branch"] == "add-hankles-limited-label")
        #expect(post.body["generation"] == 3)
    }

    @Test func dismissPostsTheChatAndTheBranchId() async throws {
        let (app, port) = try ShipTests().app { _ in }
        ShipStub.answer(port, "POST", "/loops/chat-dismiss", #"{"ok":true}"#)
        let session = "aaaaaaaa-0000-4000-8000-000000000001"
        app.runner.dispatch("chat.dismiss", via: .key, target: ShipTests.branch, arg: session)
        await until("the dismiss request") { !ShipStub.posts(port).isEmpty }
        let post = try #require(ShipStub.posts(port).first)
        #expect(post.path == "/loops/chat-dismiss")
        #expect(post.body["session"] == .string(session))
        #expect(post.body["branch"] == .string(ShipTests.branch))
    }
}
