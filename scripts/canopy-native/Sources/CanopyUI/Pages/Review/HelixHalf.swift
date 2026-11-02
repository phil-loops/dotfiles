import AppKit
import CanopyCore
import SwiftTerm
import SwiftUI

/// Helix in the diff (`i` over the new half, `o` over the whole of it): the branch's diff-view
/// checkout, whose files are the tip and whose gutter marks the branch's changes, opened at the
/// cursor's line and name. `:w` saves there as Helix always does; quitting commits what changed.
public struct HelixOpen: Equatable {
    public var path: String
    public var line: Int
    public var col: Int
    /// the checkout, once the server has made it
    public var dir: String?
    /// the tip Helix opened at; the commit is refused if the branch moved since
    public var sha: String
    /// over the whole diff (`o`), not just its new half (`i`)
    public var whole = false
}

private struct HelixWhere: Decodable { var ok: Bool; var dir: String?; var sha: String?; var err: String? }
private struct HelixLanded: Decodable { var ok: Bool; var nothing: Bool?; var message: String?; var err: String? }

extension ReviewPageState {
    func openHelix(_ app: AppModel, branch: String, path: String, line: Int, col: Int, whole: Bool = false) {
        let warm = helixDirs["\(branch)@\(tip)"]
        helix = HelixOpen(path: path, line: line, col: col, dir: warm, sha: tip, whole: whole)
        if warm != nil { return app.runner.say("Helix on \(branch) · :w saves · quitting commits it") }
        app.runner.say("checking \(branch) out for Helix…")
        Task { @MainActor in
            let r = await askHelixDir(app, branch: branch)
            guard helix?.path == path, helix?.dir == nil else { return }
            guard let r, r.ok, let dir = r.dir else {
                helix = nil
                return app.runner.say(r?.err ?? "couldn't check \(branch) out for Helix")
            }
            helix?.dir = dir
            helix?.sha = r.sha ?? tip
            app.runner.say("Helix on \(branch) · :w saves · quitting commits it")
        }
    }

    /// Make the branch's checkout before anyone asks, so `i` and `o` open Helix at once.
    func warmHelix(_ app: AppModel) {
        guard let t = target, integration == nil, !tip.isEmpty, helixDirs["\(t.name)@\(tip)"] == nil else { return }
        Task { @MainActor in _ = await askHelixDir(app, branch: t.name) }
    }

    private func askHelixDir(_ app: AppModel, branch: String) async -> HelixWhere? {
        let at = tip
        let r = await app.transport.ask(repoPath("/review-helix"), ["branch": branch, "op": "where"], as: HelixWhere.self)
        if let r, r.ok, let dir = r.dir, (r.sha ?? at) == at { helixDirs["\(branch)@\(at)"] = dir }
        return r
    }

    /// Helix quit: commit what it changed, and the diff is back.
    func landHelix(_ app: AppModel) {
        guard let h = helix, let dir = h.dir, let t = target else { helix = nil; return }
        helix = nil
        app.focus(pane: reviewDiffPane)
        Task { @MainActor in
            let body = ["branch": t.name, "op": "land", "dir": dir, "sha": h.sha]
            let r = await app.transport.ask(repoPath("/review-helix"), body, as: HelixLanded.self)
            guard let r, r.ok else { return app.runner.say(r?.err ?? "the edit didn't commit — it's saved in \(dir)") }
            app.runner.say(r.nothing == true ? "nothing changed" : "committed “\(r.message ?? "the edit")” to \(t.name)")
        }
    }
}

/// The terminal Helix runs in, laid over the new half. It takes the keyboard while it's open.
struct HelixHalf: NSViewRepresentable {
    let open: HelixOpen
    let dir: String
    let colors: CanvasColors
    let quit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(quit: quit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // starts at a real size, so Helix lays out once before SwiftUI sizes it
        let t = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        t.processDelegate = context.coordinator
        for v in t.subviews where v is NSScroller { v.isHidden = true }   // Helix scrolls itself
        t.font = .monospacedSystemFont(ofSize: DocFont.size, weight: .regular)
        t.nativeBackgroundColor = colors.bg
        t.nativeForegroundColor = colors.ink
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        t.startProcess(executable: Zsh.path, args: Zsh.arguments("exec hx \"$0\"", ["\(open.path):\(open.line):\(open.col)"]),
                       environment: env.map { "\($0)=\($1)" }, currentDirectory: dir)
        DispatchQueue.main.async { t.window?.makeFirstResponder(t) }
        return t
    }

    func updateNSView(_ t: LocalProcessTerminalView, context: Context) {
        context.coordinator.quit = quit
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var quit: () -> Void
        init(quit: @escaping () -> Void) { self.quit = quit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [quit] in quit() }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
