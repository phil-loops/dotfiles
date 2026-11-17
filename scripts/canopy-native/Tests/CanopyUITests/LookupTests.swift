import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

final class HeldLookupStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var enabled: Set<String> = []
    nonisolated(unsafe) static var pending: [String: [HeldLookupStub]] = [:]
    private var stopped = false

    static func key(_ port: Int, _ path: String) -> String { "\(port) \(path)" }
    var key: String { Self.key(request.url!.port!, request.url!.path) }

    static func hold(_ port: Int, _ path: String) {
        lock.withLock { _ = enabled.insert(key(port, path)) }
    }

    static func waiting(_ port: Int, _ path: String, query: String? = nil) -> Bool {
        lock.withLock { (pending[key(port, path)] ?? []).contains { request in query.map { request.request.url?.query?.contains($0) == true } ?? true } }
    }

    static func release(_ port: Int, _ path: String, _ body: String, query: String? = nil) {
        let request = lock.withLock { () -> HeldLookupStub? in
            let k = key(port, path)
            guard let i = pending[k]?.firstIndex(where: { request in query.map { request.request.url?.query?.contains($0) == true } ?? true }) else { return nil }
            return pending[k]?.remove(at: i)
        }
        request?.respond(body)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let port = url.port else { return false }
        return lock.withLock { enabled.contains(key(port, url.path)) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.pending[key, default: []].append(self) } }
    override func stopLoading() { Self.lock.withLock { stopped = true } }

    private func respond(_ body: String) {
        guard Self.lock.withLock({ !stopped }) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite(.serialized) struct LookupTests {
    let position = CodeLookup.Position(path: "a.ts", line: 2, character: 0)
    let location = CodeLookup.Where.branch(repo: "loops", name: "add-hankles-limited-label", base: nil)
    let definition = #"{"ok":true,"sha":"abc","locations":[{"path":"lib/old-result.ts","line":2,"character":0}]}"#

    func app() async throws -> (AppModel, Int) {
        try await ReviewPageTests().app(protocolClasses: [HeldLookupStub.self, ShipStub.self])
    }

    func leave(_ app: AppModel) {
        app.router.navigate(.review(repo: "loops", branch: "hankles-next"))
    }

    @Test func navigationBeforeTheLookupTaskStartsCancelsIt() async throws {
        let (a, port) = try await app()
        ShipStub.answer(port, "POST", "/loops/lsp/definition", definition)
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.goto(.definition, position, location))
        leave(a)
        await task.value
        #expect(lookup.pop == nil && a.nav.picker == nil && ReviewPageState.of(a).side == nil)
        #expect(!ShipStub.posts(port).contains { $0.path == "/loops/lsp/definition" })
    }

    @Test func aDefinitionReplyCannotOpenIntoAnotherBranch() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.goto(.definition, position, location))
        await until("the definition request") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        leave(a)
        HeldLookupStub.release(port, "/loops/lsp/definition", definition)
        await task.value
        #expect(a.router.route == .review(repo: "loops", branch: "hankles-next"))
        #expect(lookup.pop == nil && a.nav.picker == nil && ReviewPageState.of(a).side == nil)
    }

    @Test func returningToTheSamePageDoesNotReviveAnOldRequest() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.goto(.definition, position, location))
        await until("the definition request") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        leave(a)
        a.router.navigate(.review(repo: "loops", branch: "add-hankles-limited-label"))
        HeldLookupStub.release(port, "/loops/lsp/definition", definition)
        await task.value
        #expect(lookup.pop == nil && ReviewPageState.of(a).side == nil)
    }

    @Test func aSymbolsReplyCannotReplaceANewerPicker() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/symbols")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.symbols(path: "a.ts", location))
        await until("the symbols request") { HeldLookupStub.waiting(port, "/loops/lsp/symbols") }
        a.nav.pick("the newer picker", [PickItem(label: "keep this")])
        HeldLookupStub.release(port, "/loops/lsp/symbols", #"{"ok":true,"sha":"abc","symbols":[{"name":"oldSymbol","kind":"function","line":2,"endLine":4,"depth":0}]}"#)
        await task.value
        #expect(a.nav.picker?.title == "the newer picker")
        #expect(a.nav.picker?.items.map(\.label) == ["keep this"])
    }

    @Test func cancellingTheMemberFallbackAlsoDiscardsTheFirstAnswer() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        var member = position
        member.member = 8
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.goto(.definition, member, location))
        await until("the module request") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        HeldLookupStub.release(port, "/loops/lsp/definition", #"{"ok":true,"sha":"abc","locations":[{"path":"lib/module.ts","line":1,"character":0,"endLine":30}]}"#)
        await until("the member request") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        lookup.dismiss()
        HeldLookupStub.release(port, "/loops/lsp/definition", definition)
        await task.value
        #expect(lookup.pop == nil && a.nav.picker == nil && ReviewPageState.of(a).side == nil)
    }

    @Test func aHoverReplyIsDiscardedWhenTheReaderChangesWindows() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.hover(position, location))
        await until("the hover request") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        a.focus(pane: ShipSeam.wordsPane)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"old hover"}"#)
        await task.value
        #expect(lookup.pop == nil)
    }

    @Test func returningToTheSameWindowDoesNotReviveTheHover() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.hover(position, location))
        await until("the hover request") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        a.focus(pane: ShipSeam.wordsPane)
        a.focus(pane: reviewDiffPane)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"old hover"}"#)
        await task.value
        #expect(lookup.pop == nil)
    }

    @Test func movingToAnotherWordOnTheSameLineDiscardsTheDefinition() async throws {
        let (a, port) = try await app()
        let page = ReviewPageState.of(a)
        a.keys.handle("g")
        a.keys.handle("h")
        let row = page.here?.key
        let word = page.hereWord
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.goto(.definition, position, location))
        await until("the definition request") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        a.keys.handle("w")
        #expect(page.here?.key == row && page.hereWord != word)
        HeldLookupStub.release(port, "/loops/lsp/definition", definition)
        await task.value
        #expect(lookup.pop == nil && page.side == nil)
    }

    @Test func returningToTheSameWordDoesNotReviveTheHover() async throws {
        let (a, port) = try await app()
        let page = ReviewPageState.of(a)
        a.keys.handle("g")
        a.keys.handle("h")
        let word = page.hereWord
        HeldLookupStub.hold(port, "/loops/lsp/hover")
        let lookup = CodeLookup.of(a)
        let task = try #require(lookup.hover(position, location))
        await until("the hover request") { HeldLookupStub.waiting(port, "/loops/lsp/hover") }
        a.keys.handle("w")
        a.keys.handle("b")
        #expect(page.hereWord == word)
        HeldLookupStub.release(port, "/loops/lsp/hover", #"{"ok":true,"contents":"old hover"}"#)
        await task.value
        #expect(lookup.pop == nil)
    }

    @Test func sourceCursorIncludesTheSplitSideAndFileWord() async throws {
        let (a, _) = try await app()
        let page = ReviewPageState.of(a)
        let before = ReaderContext(a)
        page.column = .left
        #expect(!before.isCurrent(a))
        page.column = .right
        #expect(!before.isCurrent(a))
        page.show(Loc(repo: "loops", sha: "abc", path: "a.ts", line: 2, asFile: true), in: page.windows[0])
        let file = ReaderContext(a)
        page.sideWord = (2, 1..<2)
        #expect(!file.isCurrent(a))
        page.sideWord = nil
        #expect(!file.isCurrent(a))
    }

    @Test func renamePreviewSurvivesItsOwnConfirmationPicker() async throws {
        let (a, port) = try await app()
        HeldLookupStub.hold(port, "/loops/lsp/rename")
        let lookup = CodeLookup.of(a)
        lookup.rename(position, branch: "add-hankles-limited-label", repo: "loops")
        a.nav.typed("renamed")
        #expect(a.nav.choose())
        await until("the rename preview request") { HeldLookupStub.waiting(port, "/loops/lsp/rename") }
        HeldLookupStub.release(port, "/loops/lsp/rename", #"{"ok":true,"sha":"abc","old":"before","files":[{"path":"a.ts","edits":2}],"diff":"-before\n+renamed"}"#)
        await until("the rename confirmation") { a.nav.picker?.title == "rename before to renamed?" }
        #expect(lookup.pop == .hover("```diff\n-before\n+renamed\n```"))
    }
}
