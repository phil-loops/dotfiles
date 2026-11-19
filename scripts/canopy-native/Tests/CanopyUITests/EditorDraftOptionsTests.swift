import AppKit
import CanopyCore
import Foundation
import SwiftTerm
import Testing
@testable import CanopyUI

@MainActor @Suite(.serialized) struct EditorDraftOptionsTests {
    func command(_ arguments: [String]) async throws -> JSONValue {
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "exec python3 \"$@\"", "draft-lab", scripts.appendingPathComponent("testing/bench_editor_drafts.py").path] + arguments
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(with: Result { try JSONDecoder().decode(JSONValue.self, from: data) })
                } else {
                    let why = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: NSError(domain: "EditorDraftLab", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: why]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    func wait(_ what: String, _ ready: () -> Bool) async throws {
        let until = Date().addingTimeInterval(20)
        while !ready(), Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(ready(), "timed out waiting for \(what)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_DRAFT_OPTIONS"] == "1"))
    func realHelixRoundTripsEachStorageOption() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-draft-helix-\(UUID())")
        var fixture = ["fixture", root.path, "--files", "1000"]
        if let source = ProcessInfo.processInfo.environment["CANOPY_DRAFT_SOURCE"] { fixture += ["--source", source] }
        _ = try await command(fixture)
        let config = root.appendingPathComponent("helix.toml")
        try "[editor]\ninsert-final-newline = false\n[editor.lsp]\nenable = false\n".write(to: config, atomically: true, encoding: .utf8)
        var timings: [JSONValue] = []
        let orders = [["workspace", "hybrid", "objects"], ["objects", "workspace", "hybrid"], ["hybrid", "objects", "workspace"],
                      ["workspace", "objects", "hybrid"], ["hybrid", "workspace", "objects"], ["objects", "hybrid", "workspace"]]
        for (iteration, backends) in orders.enumerated() {
            for backend in backends {
                let trial = root.appendingPathComponent(UUID().uuidString.lowercased())
                let opening = Date()
                let prepared = try await command(["open", trial.path, backend])
                let dir = try #require(prepared["dir"]?.string)
                let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
                let exit = DraftEditorExit()
                terminal.processDelegate = exit
                let window = NSWindow(contentRect: terminal.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.contentView = terminal
                defer {
                    if terminal.process.running { terminal.terminate() }
                    window.contentView = nil
                    window.close()
                }
                var environment = ProcessInfo.processInfo.environment
                environment["TERM"] = "xterm-256color"
                terminal.startProcess(executable: "/bin/zsh", args: ["-c", "exec hx -c \"$1\" --log \"$2\" -- edit.txt", "draft-lab",
                    config.path, trial.appendingPathComponent("helix.log").path], environment: environment.map { "\($0)=\($1)" }, currentDirectory: dir)
                try await wait("the real editor's first frame") {
                    let screen = terminal.getTerminal()
                    return (0..<screen.rows).contains { screen.getLine(row: $0)?.translateToString(trimRight: true).contains("NOR") == true }
                }
                let openMs = Date().timeIntervalSince(opening) * 1000
                let changed = "edited using \(backend) trial \(iteration)\n"
                terminal.send(source: terminal, data: Array("%c".utf8)[...])
                try await Task.sleep(nanoseconds: 60_000_000)
                terminal.send(source: terminal, data: Array("\u{1b}[200~\(changed.dropLast())\u{1b}[201~".utf8)[...])
                terminal.send(source: terminal, data: [0x1b][...])
                try await Task.sleep(nanoseconds: 60_000_000)
                terminal.send(source: terminal, data: Array(":wq".utf8)[...])
                try await Task.sleep(nanoseconds: 60_000_000)
                let saving = Date()
                terminal.send(source: terminal, data: [13][...])
                try await wait("the editor's acknowledged exit") { exit.stopped }
                #expect(exit.code == 0)
                let saved = try await command(["save", trial.path])
                let saveMs = Date().timeIntervalSince(saving) * 1000
                #expect(saved["text"]?.string == changed && saved["count"]?.int == 1)
                let replay = try await command(["save", trial.path])
                #expect(replay["commit_oid"] == saved["commit_oid"] && replay["count"]?.int == 1)
                timings.append(["backend": .string(backend), "iteration": .number(Double(iteration)), "openMs": .number(openMs),
                    "saveToStoreMs": .number(saveMs), "prepareCoreMs": prepared["prepareMs"] ?? .null, "saveCoreMs": saved["saveCoreMs"] ?? .null])
            }
        }
        try JSONEncoder().encode(timings).write(to: root.appendingPathComponent("timings.json"))
        print("editor draft option timings: \(root.path)")
    }
}

private final class DraftEditorExit: NSObject, LocalProcessTerminalViewDelegate {
    var stopped = false
    var code: Int32?
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.code = exitCode
            self.stopped = true
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
