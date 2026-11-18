import AppKit
import CanopyCore
import Darwin
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_EDITOR_E2E"] == "1"), arguments: [false, true])
    func aRealEditorSaveCommitsAndPaintsThroughHTTPAndTheQueue(_ prewarm: Bool) async throws {
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
        let page = ReviewPageState.of(app)
        if !prewarm {
            page.editorWarmRepos.insert("initial|loops")
            page.editorWarmRepos.insert("\(try #require(info["epoch"]?.string))|loops")
        }
        let size = NSSize(width: 1100, height: 800)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView().environment(app))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let loading = Date()
        app.start()
        defer { app.stream.stop() }
        try await wait("the real diff and history") { page.diffCurrent && BranchHistory.of(app).rows(page.id) != nil }
        host.layoutSubtreeIfNeeded()
        let reviewMs = Date().timeIntervalSince(loading) * 1000
        app.focus(pane: reviewDiffPane)
        page.setCursor("l|a.txt|R:1")
        var finalTip = page.tip
        for (index, text) in ["after edit transaction", "after the second edit"].enumerated() {
            let initial = page.tip
            app.focus(pane: reviewDiffPane)
            page.setCursor("l|a.txt|R:1")
            let opening = Date()
            app.keys.handle("o")
            try await wait("the actual terminal") { window.firstResponder is HelixTerminal && page.helix?.dir != nil }
            let terminal = try #require(window.firstResponder as? HelixTerminal)
            try await wait("Helix normal mode") {
                let t = terminal.getTerminal()
                return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true).contains("NOR") == true }
            }
            let openMs = Date().timeIntervalSince(opening) * 1000
            let entryToEditorMs = Date().timeIntervalSince(loading) * 1000
            terminal.send(source: terminal, data: Array("ggxc".utf8)[...])
            try await Task.sleep(nanoseconds: 100_000_000)
            terminal.send(source: terminal, data: Array("\u{1b}[200~\(text)\n\u{1b}[201~".utf8)[...])
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
                return page.diffCanvas.canvas.text.string.contains(text)
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let paintMs = Date().timeIntervalSince(saving) * 1000
            #expect(app.store.versions[Domain.git] == 1, "the receipt paints before the delayed state patch")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("after-\(index).png"))
            let result: JSONValue = try await app.transport.getJSON("/test/result")
            #expect(result["tip"]?.string == page.tip)
            #expect(result["text"]?.string == text)
            #expect(app.runner.runOf("review.helix.land", page.id)?.state == .done)
            let timing: JSONValue = ["prewarm": .bool(prewarm), "reviewMs": .number(reviewMs), "entryToEditorMs": .number(entryToEditorMs), "openMs": .number(openMs), "saveToPaintMs": .number(paintMs), "tip": .string(page.tip)]
            try JSONEncoder().encode(timing).write(to: root.appendingPathComponent("timings-\(index).json"))
            print("editor-flow prewarm=\(prewarm) \(index == 0 ? "first" : "repeat"): \(root.path) · review \(Int(reviewMs)) ms · open \(Int(openMs)) ms · entry to editor \(Int(entryToEditorMs)) ms · save to paint \(Int(paintMs)) ms")
            finalTip = page.tip
            if index == 0 {
                var parked = false
                for _ in 0..<100 {
                    let ready: JSONValue = try await app.transport.getJSON("/test/result")
                    if ready["parkedTip"]?.string == page.tip { parked = true; break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try #require(parked, "the completed checkout is available for an exclusive new lease")
            }
        }
        try await wait("the delayed stream acknowledgement") { app.store.asOf[Domain.git] == 2 }
        #expect(page.tip == finalTip && page.diffCurrent)
        #expect(page.diffCanvas.canvas.text.string.contains("after the second edit"))
        let interrupted: JSONValue? = await app.transport.ask("/test/recover-last", JSONObject())
        #expect(interrupted?["ok"] == true && interrupted?["sha"]?.string == finalTip)
        app.runner.dispatch("review.helix.recover", via: .key, target: page.id)
        await page.editorRecoveryTask?.value
        try #require(app.nav.picker?.title == "saved Helix edits")
        app.nav.choose(0)
        try await wait("the recovered operation through the real HTTP server") { app.runner.note == "recovered the saved Helix edit" }
        let recovered: JSONValue = try await app.transport.getJSON("/test/result")
        #expect(recovered["tip"]?.string == finalTip && recovered["count"]?.int == 3)
        #expect(page.tip == finalTip && page.diffCanvas.canvas.text.string.contains("after the second edit"))
        let requests = recovered["requests"]?.array ?? []
        #expect(requests.contains { $0["path"] == "/loops/edit-workspaces" })
        #expect(requests.contains { $0["path"] == "/loops/edit-recover" && $0["body"]?["operation"] == interrupted?["operation"] })
        app.focus(pane: reviewDiffPane)
        page.setCursor("l|a.txt|R:1")
        app.keys.handle("o")
        try await wait("the editor whose files will survive its crash") { page.helix?.dir != nil && window.firstResponder is HelixTerminal }
        let abandoned = try #require(page.helix)
        let dying = try #require(window.firstResponder as? HelixTerminal)
        defer { if dying.process.running { dying.terminate() } }
        try await wait("the attached editor's normal mode") {
            let t = dying.getTerminal()
            return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString(trimRight: true).contains("NOR") == true }
        }
        let savedText = "saved before the editor stopped"
        dying.send(source: dying, data: Array("ggxc".utf8)[...])
        try await Task.sleep(nanoseconds: 100_000_000)
        dying.send(source: dying, data: Array("\u{1b}[200~\(savedText)\n\u{1b}[201~".utf8)[...])
        dying.send(source: dying, data: [0x1b][...])
        try await Task.sleep(nanoseconds: 150_000_000)
        dying.send(source: dying, data: Array(":w\r".utf8)[...])
        let lease = try #require(abandoned.lease)
        var workspace: JSONValue = .null
        for _ in 0..<100 {
            workspace = try await app.transport.getJSON("/test/workspace?session=\(lease)")
            if workspace["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == savedText { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(workspace["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == savedText)
        #expect(Darwin.kill(dying.process.shellPid, SIGKILL) == 0)
        try await wait("the stopped editor") { page.helix == nil }
        #expect(page.tip == finalTip)
        let resuming = Date()
        app.runner.dispatch("review.helix.resume", via: .key, target: page.id)
        await page.editorRecoveryTask?.value
        try #require(app.nav.picker?.title == "Helix workspaces")
        app.nav.choose(0)
        try await wait("the resumed editor") { page.helix?.dir != nil && window.firstResponder is HelixTerminal && window.firstResponder !== dying }
        let resumed = try #require(page.helix)
        let terminal = try #require(window.firstResponder as? HelixTerminal)
        defer { if terminal.process.running { terminal.terminate() } }
        try await wait("the saved contents in the resumed editor") {
            let t = terminal.getTerminal()
            let lines = (0..<t.rows).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
            return lines.contains { $0.contains("NOR") } && lines.contains { $0.contains(savedText) }
        }
        let resumeMs = Date().timeIntervalSince(resuming) * 1000
        #expect(resumed.lease == lease && resumed.dir == abandoned.dir && resumed.session != abandoned.session)
        #expect(resumed.attachment?.token != abandoned.attachment?.token)
        let unchanged: JSONValue = try await app.transport.getJSON("/test/workspace?session=\(lease)")
        #expect(unchanged["inode"] == workspace["inode"] && unchanged["text"] == workspace["text"])
        terminal.send(source: terminal, data: Array(":wq".utf8)[...])
        try await Task.sleep(nanoseconds: 100_000_000)
        let saving = Date()
        terminal.send(source: terminal, data: [13][...])
        try await wait("the resumed workspace's commit") { page.helix == nil && page.tip != finalTip && page.diffCurrent }
        try await wait("the resumed edit's diff and history") {
            host.layoutSubtreeIfNeeded()
            return page.diffCanvas.canvas.text.string.contains(savedText)
                && BranchHistory.of(app).rows(page.id)?.first.map { page.tip.hasPrefix($0.sha) } == true
        }
        let saveMs = Date().timeIntervalSince(saving) * 1000
        let result: JSONValue = try await app.transport.getJSON("/test/result")
        #expect(result["text"]?.string == savedText && result["count"]?.int == 4)
        let timing: JSONValue = ["resumeMs": .number(resumeMs), "saveToPaintMs": .number(saveMs)]
        try JSONEncoder().encode(timing).write(to: root.appendingPathComponent("timings-resume.json"))
        print("editor-resume prewarm=\(prewarm): \(root.path) · resume \(Int(resumeMs)) ms · save to paint \(Int(saveMs)) ms")
    }
}
