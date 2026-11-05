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
    /// opened from the open file: quitting puts that pane back where Helix left off
    public var fromSide = false
}

private struct HelixWhere: Decodable { var ok: Bool; var dir: String?; var sha: String?; var err: String? }
private struct HelixLanded: Decodable { var ok: Bool; var nothing: Bool?; var message: String?; var err: String? }

extension ReviewPageState {
    func openHelix(_ app: AppModel, branch: String, path: String, line: Int, col: Int, whole: Bool = false, fromSide: Bool = false) {
        let warm = helixDirs["\(branch)@\(tip)"]
        helix = HelixOpen(path: path, line: line, col: col, dir: warm, sha: tip, whole: whole, fromSide: fromSide)
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

    /// The repo's GitHub page, read from origin in the branch's checkout (gh-open's rule) and kept per repo.
    func githubPage(_ app: AppModel) async -> String? {
        guard let t = target else { return nil }
        if let w = githubWebs[t.repo] { return w }
        let web: String?
        if let stub = githubWeb {
            web = await stub(app)
        } else {
            var dir = helixDirs["\(t.name)@\(tip)"]
            if dir == nil { dir = await askHelixDir(app, branch: t.name)?.dir }
            guard let dir else { return nil }
            web = await Self.originWeb(dir)
        }
        if let web { githubWebs[t.repo] = web }
        return web
    }

    /// origin's URL as a github.com page: `git@github.com:o/r.git` and `https://github.com/o/r.git` → `https://github.com/o/r`.
    nonisolated static func originWeb(_ dir: String) async -> String? {
        await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            let p = Zsh.process("exec git -C \"$0\" remote get-url origin", [dir])
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let raw = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                k.resume(returning: githubPage(remote: raw))
            }
            do { try p.run() } catch { k.resume(returning: nil) }
        }
    }

    nonisolated static func githubPage(remote raw: String) -> String? {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasSuffix(".git") { u.removeLast(4) }
        if u.hasPrefix("git@github.com:") { u = "https://github.com/" + u.dropFirst("git@github.com:".count) }
        if u.hasPrefix("ssh://git@github.com/") { u = "https://github.com/" + u.dropFirst("ssh://git@github.com/".count) }
        return u.hasPrefix("https://github.com/") ? u : nil
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
        let at = helixAt ?? (h.path, h.line)
        helixAt = nil
        let k = stopNear(path: at.path, line: at.line)
        if h.fromSide, k == nil {
            // a file the diff doesn't show: back in the window, at the tip Helix edited
            show(Loc(repo: t.repo, sha: h.sha, path: at.path, line: at.line))
        } else {
            pendingNear = (id, at.path, at.line)
            if let k { setCursor(k) }
            app.focus(pane: reviewDiffPane)
        }
        Task { @MainActor in
            let body = ["branch": t.name, "op": "land", "dir": dir, "sha": h.sha]
            let r = await app.transport.ask(repoPath("/review-helix"), body, as: HelixLanded.self)
            if r?.ok != true || r?.nothing == true { pendingNear = nil }
            guard let r, r.ok else { return app.runner.say(r?.err ?? "the edit didn't commit — it's saved in \(dir)") }
            app.runner.say(r.nothing == true ? "nothing changed" : "committed “\(r.message ?? "the edit")” to \(t.name)")
        }
    }
}

/// Helix's position from its status line ("NOR   pages/x.tsx [+]   1 sel  12:4"): the file and the line.
func helixStatus(_ line: String) -> (path: String, line: Int)? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 3, ["NOR", "INS", "SEL"].contains(parts[0]),
          let pos = parts.last, let colon = pos.firstIndex(of: ":"), let n = Int(pos[..<colon]), Int(pos[pos.index(after: colon)...]) != nil
    else { return nil }
    return (parts[1], n)
}

/// A terminal that reads Helix's status line as the screen updates, so quitting knows where the cursor was.
final class HelixTerminal: LocalProcessTerminalView {
    var onPosition: ((String, Int) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let term = getTerminal()
        for row in stride(from: term.rows - 1, through: max(0, term.rows - 3), by: -1) {
            if let text = term.getLine(row: row)?.translateToString(trimRight: true), let at = helixStatus(text) {
                onPosition?(at.path, at.line)
                return
            }
        }
    }
}

/// The terminal Helix runs in, over the new half or the whole page. It takes the keyboard while it's open.
struct HelixHalf: NSViewRepresentable {
    let open: HelixOpen
    let dir: String
    let colors: CanvasColors
    var moved: (String, Int) -> Void = { _, _ in }
    let quit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(quit: quit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // starts at a real size, so Helix lays out once before SwiftUI sizes it
        let t = HelixTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        t.onPosition = moved
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
