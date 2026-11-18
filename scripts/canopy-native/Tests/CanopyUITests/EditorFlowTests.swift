import AppKit
import CanopyCore
import Foundation
import SwiftTerm
import SwiftUI
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct EditorFlowTests {
    func wait(_ what: String, seconds: Double = 20, _ ready: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !ready(), Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(ready(), "timed out waiting for \(what)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_EDITOR_E2E"] == "1"))
    func aRealEditorSaveCommitsAndPaintsThroughHTTPAndTheQueue() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        Fonts.register()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-editor-flow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/zsh")
        server.arguments = ["-c", "exec python3 \"$@\"", "editor-flow", scripts.appendingPathComponent("testing/editor-flow-server.py").path,
                            root.path, "--refresh-delay", "5"]
        if let source = ProcessInfo.processInfo.environment["CANOPY_EDITOR_FIXTURE_REPO"] {
            server.arguments?.append(contentsOf: ["--source-repo", source])
        }
        let log = root.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        server.standardOutput = output
        server.standardError = output
        try server.run()
        defer { if server.isRunning { server.terminate() }; try? output.close() }
        let configFile = root.appendingPathComponent("server.json")
        try await wait("the disposable HTTP server", seconds: 60) { FileManager.default.fileExists(atPath: configFile.path) || !server.isRunning }
        let serverLog = try String(contentsOf: log, encoding: .utf8)
        try #require(server.isRunning, "\(serverLog)")
        let info = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: configFile))
        let port = try #require(info["port"]?.int)
        var config = AppConfig()
        config.repo = try #require(info["repo"]?.string)
        config.route = .review(repo: "loops", branch: "editor-flow")
        let app = AppModel(config: config, port: port, telemetry: false)
        app.nativeKeysPath = root.appendingPathComponent("no-key-overrides.toml").path
        app.start()
        defer { app.stream.stop() }
        let page = ReviewPageState.of(app)
        try await wait("the real diff and history") { page.diffCurrent && BranchHistory.of(app).rows(page.id) != nil }
        app.focus(pane: reviewDiffPane)
        page.setCursor("l|a.txt|R:1")
        let initial = page.tip
        let size = NSSize(width: 1100, height: 800)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView().environment(app))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let opening = Date()
        app.keys.handle("o")
        try await wait("the actual terminal") { window.firstResponder is HelixTerminal && page.helix?.dir != nil }
        let terminal = try #require(window.firstResponder as? HelixTerminal)
        try await wait("Helix normal mode") {
            let t = terminal.getTerminal()
            return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true).contains("NOR") == true }
        }
        let openMs = Date().timeIntervalSince(opening) * 1000
        terminal.send(source: terminal, data: Array("ggxc".utf8)[...])
        try await Task.sleep(nanoseconds: 100_000_000)
        terminal.send(source: terminal, data: Array("\u{1b}[200~after edit transaction\n\u{1b}[201~".utf8)[...])
        terminal.send(source: terminal, data: [0x1b][...])
        try await Task.sleep(nanoseconds: 300_000_000)
        terminal.send(source: terminal, data: Array(":wq".utf8)[...])
        try await Task.sleep(nanoseconds: 200_000_000)
        let saving = Date()
        terminal.send(source: terminal, data: [13][...])
        try await wait("the committed revision") { page.helix == nil && page.tip != initial && page.diffCurrent }
        try await wait("the committed history row") { BranchHistory.of(app).rows(page.id)?.first.map { page.tip.hasPrefix($0.sha) } == true }
        try await wait("the rendered edit") {
            host.layoutSubtreeIfNeeded()
            return page.diffCanvas.canvas.text.string.contains("after edit transaction")
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let paintMs = Date().timeIntervalSince(saving) * 1000
        #expect(app.store.versions[Domain.git] == 1, "the receipt paints before the delayed state patch")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("after.png"))
        let result: JSONValue = try await app.transport.getJSON("/test/result")
        #expect(result["tip"]?.string == page.tip)
        #expect(result["text"]?.string == "after edit transaction")
        #expect(app.runner.runOf("review.helix.land", page.id)?.state == .done)
        let timing: JSONValue = ["openMs": .number(openMs), "saveToPaintMs": .number(paintMs), "tip": .string(page.tip)]
        try JSONEncoder().encode(timing).write(to: root.appendingPathComponent("timings.json"))
        print("editor-flow: \(root.path) · open \(Int(openMs)) ms · save to paint \(Int(paintMs)) ms")
        try await wait("the delayed stream acknowledgement") { app.store.asOf[Domain.git] == 1 }
        #expect(page.tip == result["tip"]?.string && page.diffCurrent)
        #expect(page.diffCanvas.canvas.text.string.contains("after edit transaction"))
    }
}
