import AppKit
import Testing
@testable import Show

/// The tmux switch's mark on a canopy link, and which window's frame Show takes for it.
struct TerminalFrameTests {
    @Test func theMarkComesOffTheLinkAndOnlyTheSwitchCarriesIt() throws {
        let marked = TerminalFrame.unmarked(try #require(URL(string: "canopy://v2/b/loops/feat/x?beside=terminal")))
        #expect(marked.beside && marked.link.absoluteString == "canopy://v2/b/loops/feat/x")
        #expect(Target(canopyLink: marked.link) == .canopy("/v2/b/loops/feat/x"))
        let bare = TerminalFrame.unmarked(try #require(URL(string: "canopy://?beside=terminal&pane=346")))
        #expect(bare.beside && bare.pane == "%346" && Target(canopyLink: bare.link) == .canopy(""), "canopy as it stands, then the pane's branch")
        #expect(TerminalFrame.unmarked(try #require(URL(string: "canopy://?beside=terminal&pane=x;rm"))).pane == nil, "a pane is a number")
        #expect(TerminalFrame.unmarked(try #require(URL(string: "canopy://v2?pane=3"))).pane == nil, "only the switch names a pane")
        let kept = TerminalFrame.unmarked(try #require(URL(string: "canopy://v2/tutor?concept=x&beside=terminal")))
        #expect(kept.beside && kept.link.absoluteString == "canopy://v2/tutor?concept=x")
        let plain = try #require(URL(string: "canopy://v2/b/loops/feat"))
        #expect(TerminalFrame.unmarked(plain) == (plain, false, nil))
    }

    /// `show --shoot-live` asks through an inbox file: only a file there, naming an absolute .png, is such a request.
    @Test func aLivePictureIsAskedForOnlyFromTheInbox() throws {
        let fm = FileManager.default
        let inbox = (NSTemporaryDirectory() as NSString).appendingPathComponent("show-inbox-\(UUID().uuidString)")
        try fm.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: inbox) }
        func file(_ dir: String, _ body: String) throws -> String {
            let path = (dir as NSString).appendingPathComponent("shoot-test-\(UUID().uuidString).json")
            try Data(body.utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
        let asked = try file(inbox, #"{"shoot": "/tmp/x/out.png"}"#)
        #expect(takeShootRequest(asked, inbox: inbox) == "/tmp/x/out.png" && !fm.fileExists(atPath: asked), "taken, and used up")
        for body in [#"{"shoot": "out.png"}"#, #"{"shoot": "/etc/hosts"}"#, #"{"target": {"api": true}}"#] {
            let other = try file(inbox, body)
            #expect(takeShootRequest(other, inbox: inbox) == nil && fm.fileExists(atPath: other), "not a picture request: left for the next reader")
            try fm.removeItem(atPath: other)
        }
        let outside = try file(NSTemporaryDirectory(), #"{"shoot": "/tmp/x/out.png"}"#)
        #expect(takeShootRequest(outside, inbox: inbox) == nil, "a file outside the inbox asks for nothing")
        try fm.removeItem(atPath: outside)
    }

    @Test func showTakesTheTerminalAppsFrontWindowInAppKitsCoordinates() {
        func window(_ owner: pid_t, layer: Int = 0, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [String: Any] {
            [kCGWindowOwnerPID as String: owner, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation as NSDictionary]
        }
        let windows = [window(7, 0, 0, 800, 600), window(42, layer: 25, 0, 0, 1728, 24), window(42, 10, 10, 120, 40),
                       window(42, 100, 50, 1400, 900), window(42, 0, 0, 800, 600)]
        #expect(TerminalFrame.frame(in: windows, owner: 42, mainScreenHeight: 1117) == NSRect(x: 100, y: 167, width: 1400, height: 900),
                "the frontmost ordinary window of the app the tmux client runs in; a menu-bar layer and a sliver are passed over")
        #expect(TerminalFrame.frame(in: [window(7, 0, 0, 800, 600)], owner: 42, mainScreenHeight: 1117) == nil)
    }
}
