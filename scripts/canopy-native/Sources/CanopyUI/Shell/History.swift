import CanopyCore
import Foundation

/// The app-wide jumplist, wired (NAV.md §4.4): what records, and putting a place back exactly.
extension AppModel {
    /// A command flagged `recordsJump` is about to run.
    public func willJump(_ id: String) { recordJump() }

    /// Put a remembered place back — page, pane, cursor, code place, then the surface's tab and
    /// scroll — without recording anything.
    public func restore(_ p: Place) {
        jumpDepth += 1
        defer { jumpDepth -= 1 }
        if p.route != router.route { router.navigate(p.route) }
        if let id = p.pane { focus(pane: id) }
        if let k = p.cursorKey { setCursor(k) }
        if let l = p.loc { nav.open(l) }
        provider?.restore(p, self)
    }

    /// `C-o`.
    @discardableResult
    public func jumpBack() -> Bool {
        guard let to = jumps.goBack(from: here()) else { return false }
        restore(to)
        return true
    }

    /// `C-i`.
    @discardableResult
    public func jumpForward() -> Bool {
        guard let to = jumps.goForward(from: here()) else { return false }
        restore(to)
        return true
    }

    /// `g a`: where the last jump left from — and pressing it again comes back.
    @discardableResult
    public func jumpAlternate() -> Bool {
        let now = here()
        guard let to = jumps.alternate, !to.sameSpot(now) else { return false }
        jumps.record(now)
        restore(to)
        return true
    }

    /// The usage log the server keeps beside the repo (`.git/stack-usage.jsonl`), read once in the
    /// background so `space b` ranks by frecency from the first launch.
    func seedFrecency() {
        let repo = NSString(string: config.repo ?? "~/coding/loops").expandingTildeInPath
        Task.detached(priority: .utility) {
            guard let dir = Self.gitCommonDir(repo),
                  let text = try? String(contentsOfFile: "\(dir)/stack-usage.jsonl", encoding: .utf8) else { return }
            var f = Frecency()
            f.seed(jsonl: text)
            let seeded = f
            await MainActor.run { [weak self] in
                guard let self else { return }
                var merged = seeded
                for (id, e) in self.frecency.entries { for _ in 0..<Int(e.rank) { merged.visit(id, at: e.last) } }
                self.frecency = merged
                Log.line("frecency seeded: \(merged.entries.count) branches")
            }
        }
    }

    nonisolated static func gitCommonDir(_ repo: String) -> String? {
        let dotgit = "\(repo)/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotgit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotgit }
        guard let s = try? String(contentsOfFile: dotgit, encoding: .utf8), let r = s.range(of: "gitdir: ") else { return nil }
        let gitdir = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = try? String(contentsOfFile: "\(gitdir)/commondir", encoding: .utf8) {
            let common = c.trimmingCharacters(in: .whitespacesAndNewlines)
            return common.hasPrefix("/") ? common : (gitdir as NSString).appendingPathComponent(common)
        }
        return gitdir
    }
}
