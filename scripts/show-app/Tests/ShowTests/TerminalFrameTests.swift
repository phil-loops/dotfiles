import AppKit
import Testing
@testable import Show

/// The tmux switch's mark on a canopy link, and which window's frame Show takes for it.
struct TerminalFrameTests {
    @Test func theMarkComesOffTheLinkAndOnlyTheSwitchCarriesIt() throws {
        let marked = TerminalFrame.unmarked(try #require(URL(string: "canopy://v2/b/loops/feat/x?beside=terminal")))
        #expect(marked.beside && marked.link.absoluteString == "canopy://v2/b/loops/feat/x")
        #expect(Target(canopyLink: marked.link) == .canopy("/v2/b/loops/feat/x"))
        let bare = TerminalFrame.unmarked(try #require(URL(string: "canopy://?beside=terminal")))
        #expect(bare.beside && Target(canopyLink: bare.link) == .canopy(""), "no branch: canopy as it stands")
        let kept = TerminalFrame.unmarked(try #require(URL(string: "canopy://v2/tutor?concept=x&beside=terminal")))
        #expect(kept.beside && kept.link.absoluteString == "canopy://v2/tutor?concept=x")
        let plain = try #require(URL(string: "canopy://v2/b/loops/feat"))
        #expect(TerminalFrame.unmarked(plain) == (plain, false))
    }

    @Test func showTakesTerminalsFrontWindowInAppKitsCoordinates() {
        func window(_ owner: String, layer: Int = 0, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation as NSDictionary]
        }
        let windows = [window("Show", 0, 0, 800, 600), window("Terminal", layer: 25, 0, 0, 1728, 24), window("Terminal", 10, 10, 120, 40),
                       window("Terminal", 100, 50, 1400, 900), window("Terminal", 0, 0, 800, 600)]
        #expect(TerminalFrame.frame(in: windows, mainScreenHeight: 1117) == NSRect(x: 100, y: 167, width: 1400, height: 900),
                "the frontmost ordinary Terminal window; a menu-bar layer and a sliver are passed over")
        #expect(TerminalFrame.frame(in: [window("Show", 0, 0, 800, 600)], mainScreenHeight: 1117) == nil)
    }
}
