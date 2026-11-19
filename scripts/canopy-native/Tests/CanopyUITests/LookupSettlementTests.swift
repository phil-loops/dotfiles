import CanopyTestSupport
import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

final class LookupNetworkFailureStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var ports: Set<Int> = []

    static func fail(_ port: Int) { lock.withLock { _ = ports.insert(port) } }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let port = url.port, url.path.contains("/lsp/") else { return false }
        return lock.withLock { ports.contains(port) }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

@MainActor @Suite(.serialized) struct LookupSettlementTests {
    let subject = LookupTests()
    let module = #"{"ok":true,"sha":"abc","locations":[{"path":"lib/module.ts","line":1,"character":0,"endLine":30}]}"#

    func start(_ kind: String, _ app: AppModel) -> Task<Void, Never>? {
        let lookup = CodeLookup.of(app)
        switch kind {
        case "hover": return lookup.hover(subject.position, subject.location)
        case "definition": return lookup.goto(.definition, subject.position, subject.location)
        case "symbols": return lookup.symbols(path: "a.ts", subject.location)
        case "workspace-symbols": return lookup.workspaceSymbols(query: "name", path: "a.ts", subject.location)
        case "rename":
            RenameOwnershipTests().begin(app)
            #expect(app.nav.choose())
            return lookup.renameTask
        default: return Task { @MainActor in _ = await lookup.symbolList(path: "a.ts", subject.location) }
        }
    }

    @Test func currentHTTPAndMalformedRepliesSettleEveryLookupAndCanBeRetried() async throws {
        for status in [200, 503] {
            for kind in ["hover", "definition", "symbols", "workspace-symbols", "rename", "symbol-list"] {
                let (app, port) = try await subject.app()
                let route = kind == "symbol-list" ? "symbols" : kind
                ShipStub.answer(port, "POST", "/loops/lsp/\(route)", "not json", status: status)
                let task = try #require(start(kind, app))
                await task.value
                let lookup = CodeLookup.of(app)
                #expect(lookup.pop?.isWait == false)
                #expect(lookup.pop?.text.contains("try again") == true)
                #expect(app.nav.picker == nil)
                ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"retried type"}"#)
                await lookup.hover(subject.position, subject.location)?.value
                #expect(lookup.pop == .hover("retried type"))
            }
        }
    }

    @Test func aNetworkFailureAlsoSettlesTheOwningLookup() async throws {
        let (app, port) = try await ReviewPageTests().app(protocolClasses: [LookupNetworkFailureStub.self, ShipStub.self])
        LookupNetworkFailureStub.fail(port)
        let lookup = CodeLookup.of(app)
        await lookup.hover(subject.position, subject.location)?.value
        #expect(lookup.pop?.isWait == false)
        #expect(lookup.pop?.text.contains("try again") == true)
    }

    @Test func anObsoleteFailureCannotReplaceANewerTypeOrPicker() async throws {
        for newer in ["type", "picker"] {
            let (app, port) = try await subject.app()
            HeldLookupStub.hold(port, "/loops/lsp/definition")
            let lookup = CodeLookup.of(app)
            let task = try #require(lookup.goto(.definition, subject.position, subject.location))
            await until("the old lookup") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
            if newer == "type" {
                ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"new type"}"#)
                await lookup.hover(subject.position, subject.location)?.value
            } else { app.nav.pick("new picker", [PickItem(label: "keep this")]) { _ in } }
            HeldLookupStub.release(port, "/loops/lsp/definition", "not json")
            await task.value
            if newer == "type" { #expect(lookup.pop == .hover("new type")) }
            else { #expect(app.nav.picker?.title == "new picker" && lookup.pop == nil) }
        }
    }

    @Test func cancelingBeforeTheTaskStartsNeverSends() async throws {
        let (app, port) = try await subject.app()
        let lookup = CodeLookup.of(app)
        let task = try #require(lookup.goto(.definition, subject.position, subject.location))
        task.cancel()
        await task.value
        #expect(lookup.pop == nil && app.nav.picker == nil && ReviewPageState.of(app).side == nil)
        #expect(!ShipStub.posts(port).contains { $0.path == "/loops/lsp/definition" })
    }

    @Test func cancelingTheMemberTaskNeverRevivesTheWholeModule() async throws {
        let (app, port) = try await subject.app()
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        var position = subject.position
        position.member = 8
        let lookup = CodeLookup.of(app)
        let task = try #require(lookup.goto(.definition, position, subject.location))
        await until("the whole-module answer") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        HeldLookupStub.release(port, "/loops/lsp/definition", module)
        await until("the member answer") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        task.cancel()
        await task.value
        HeldLookupStub.release(port, "/loops/lsp/definition", subject.definition)
        #expect(lookup.pop == nil && app.nav.picker == nil && ReviewPageState.of(app).side == nil)
    }

    @Test func memberFailureAndEmptyAnswersCannotOpenTheWholeModule() async throws {
        for answer in ["not json", #"{"ok":false,"message":"member unavailable"}"#, #"{"ok":true,"sha":"abc","locations":[]}"#] {
            let (app, port) = try await subject.app()
            HeldLookupStub.hold(port, "/loops/lsp/definition")
            var position = subject.position
            position.member = 8
            let lookup = CodeLookup.of(app)
            let task = try #require(lookup.goto(.definition, position, subject.location))
            await until("the whole-module answer") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
            HeldLookupStub.release(port, "/loops/lsp/definition", module)
            await until("the member answer") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
            HeldLookupStub.release(port, "/loops/lsp/definition", answer)
            await task.value
            #expect(lookup.pop?.isWait == false)
            #expect(app.nav.picker == nil && ReviewPageState.of(app).side == nil)
        }
    }

    @Test func cancelingAnOldTaskCannotDismissANewerLookup() async throws {
        let (app, port) = try await subject.app()
        HeldLookupStub.hold(port, "/loops/lsp/definition")
        let lookup = CodeLookup.of(app)
        let old = try #require(lookup.goto(.definition, subject.position, subject.location))
        await until("the old definition") { HeldLookupStub.waiting(port, "/loops/lsp/definition") }
        ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"new type"}"#)
        await lookup.hover(subject.position, subject.location)?.value
        old.cancel()
        await old.value
        HeldLookupStub.release(port, "/loops/lsp/definition", subject.definition)
        #expect(lookup.pop == .hover("new type"))
    }

    @Test func anAlreadyCanceledSymbolListCannotReplaceANewerLookup() async throws {
        let (app, port) = try await subject.app()
        let lookup = CodeLookup.of(app)
        let task = Task { @MainActor in _ = await lookup.symbolList(path: "a.ts", subject.location) }
        task.cancel()
        ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":true,"contents":"new type"}"#)
        await lookup.hover(subject.position, subject.location)?.value
        await task.value
        #expect(lookup.pop == .hover("new type"))
        #expect(!ShipStub.posts(port).contains { $0.path == "/loops/lsp/symbols" })
    }

    @Test func cancelingDuringLoadingStopsRetriesAndClearsItsWait() async throws {
        let (app, port) = try await subject.app()
        ShipStub.answer(port, "POST", "/loops/lsp/hover", #"{"ok":false,"state":"loading","message":"preparing project"}"#)
        let lookup = CodeLookup.of(app)
        lookup.retry = 60
        let task = try #require(lookup.hover(subject.position, subject.location))
        await until("the loading answer") { lookup.pop?.text.contains("preparing project") == true }
        task.cancel()
        await task.value
        #expect(lookup.pop == nil)
        #expect(ShipStub.posts(port).filter { $0.path == "/loops/lsp/hover" }.count == 1)
    }

    @Test func sourceChangesStopRenamePollingBeforeTheNextRequest() async throws {
        let (app, port) = try await subject.app()
        ShipStub.answer(port, "POST", "/loops/lsp/rename", #"{"ok":false,"state":"loading","message":"preparing project"}"#)
        let lookup = CodeLookup.of(app)
        lookup.retry = 0.25
        RenameOwnershipTests().begin(app)
        #expect(app.nav.choose())
        let task = try #require(lookup.renameTask)
        await until("the loading rename answer") { lookup.pop?.text.contains("preparing project") == true }
        #expect(app.store.applyPatch(try Patch.make(domain: Domain.remote, version: (app.store.versions[Domain.remote] ?? 0) + 1)) == .ok)
        await task.value
        #expect(lookup.pop == nil && app.nav.picker == nil)
        #expect(ShipStub.posts(port).filter { $0.path == "/loops/lsp/rename" }.count == 1)
    }
}
