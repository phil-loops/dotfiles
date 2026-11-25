import Foundation

/// Taps of the 🌐 key: a press and release with nothing typed between. A second soon after the first makes a double.
struct GlobeTaps {
    enum Tap: Equatable { case none, single, double }

    var tap: TimeInterval = 0.35
    var gap: TimeInterval = 0.5
    private var down: TimeInterval?
    private var last: TimeInterval?

    mutating func press(at time: TimeInterval) { down = time }

    /// What this release completes: nothing (held too long, or no press), a first tap, or a double.
    mutating func release(at time: TimeInterval) -> Tap {
        guard let pressed = down, time - pressed < tap else { down = nil; last = nil; return .none }
        down = nil
        if let first = last, time - first < gap { last = nil; return .double }
        last = time
        return .single
    }

    mutating func interrupt() { down = nil; last = nil }

    var pending: Bool { down != nil || last != nil }
}

struct Session: Decodable, Equatable {
    let session_id: String
    let pane: String
    let topic: String
}

enum Logic {
    /// Terminal apps: with one in front, Dictate looks for a Claude session in tmux before pasting.
    static let terminals: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
                                         "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable", "com.github.wez.wezterm"]

    /// The pane of the tmux client used last, from `tmux list-clients -F '#{client_activity}\t#{pane_id}'`.
    static func activePane(clients: String) -> String? {
        clients.split(separator: "\n").compactMap { line -> (Int, String)? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let activity = Int(fields[0]) else { return nil }
            return (activity, String(fields[1]))
        }.max { $0.0 < $1.0 }?.1
    }

    /// The pane a `dictate://pane/<id>` link names ("%12").
    static func pane(of link: URL) -> String? {
        guard link.scheme == "dictate", link.host == "pane", let id = Int(link.lastPathComponent) else { return nil }
        return "%\(id)"
    }

    /// The Claude session `claude-say --json` places in `pane`.
    static func session(in pane: String, listing: Data) -> Session? {
        (try? JSONDecoder().decode([Session].self, from: listing))?.first { $0.pane == pane }
    }

    /// The last `seconds` of a 16 kHz mono 16-bit WAV that may still be recording, whose header doesn't yet say how long it is.
    static func tail(of data: Data, seconds: Double) -> [Float] {
        guard let marker = data.range(of: Data("data".utf8)) else { return [] }
        let start = marker.upperBound + 4
        guard data.count > start else { return [] }
        var from = max(start, data.count - Int(seconds * 16_000) * 2)
        from += (from - start) % 2
        return data[from...].withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32_768
            }
        }
    }

    /// The end of the words heard so far, at most `width` characters, starting on a word.
    static func heard(_ text: String, width: Int = 40) -> String {
        guard text.count > width else { return text }
        return "…" + text.suffix(width - 1).drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
    }
}

/// `Dictate --selftest`: the pure pieces, checked without a microphone, a keyboard or tmux.
func selfTest() -> Int32 {
    var failed = 0
    func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "✓" : "✗") \(name)")
        if !ok { failed += 1 }
    }
    var taps = GlobeTaps()
    taps.press(at: 0); let one = taps.release(at: 0.1)
    taps.press(at: 0.2); let two = taps.release(at: 0.3)
    check("two quick 🌐 taps make a single then a double", one == .single && two == .double)
    taps.press(at: 1); _ = taps.release(at: 1.1); taps.interrupt(); taps.press(at: 1.2)
    check("a key typed between taps cancels the double", taps.release(at: 1.3) == .single)
    taps.press(at: 2); let held = taps.release(at: 2.8)
    check("holding 🌐 is not a tap", held == .none)
    taps.press(at: 4); _ = taps.release(at: 4.1); taps.press(at: 4.9)
    check("taps too far apart are two singles", taps.release(at: 5.0) == .single)

    check("the last-used tmux client names the pane", Logic.activePane(clients: "100\t%3\n250\t%12\n90\t%7\n") == "%12")
    check("no tmux clients, no pane", Logic.activePane(clients: "") == nil)
    check("a dictate link names its pane", Logic.pane(of: URL(string: "dictate://pane/12")!) == "%12"
          && Logic.pane(of: URL(string: "canopy://pane/12")!) == nil)

    let listing = Data(#"[{"session_id":"aaa","pane":"%3","topic":"x"},{"session_id":"bbb","pane":"%12","topic":"y"}]"#.utf8)
    check("the target is the Claude session in that pane", Logic.session(in: "%12", listing: listing)?.session_id == "bbb")
    check("a pane with no Claude has no target", Logic.session(in: "%7", listing: listing) == nil)

    var wav = Data("RIFF\0\0\0\0WAVEfmt ".utf8) + Data(count: 20) + Data("data\0\0\0\0".utf8)
    for sample: Int16 in [0, 16_384, -16_384, 32_767] { wav += withUnsafeBytes(of: sample.littleEndian) { Data($0) } }
    check("the preview reads a WAV still being written", Logic.tail(of: wav, seconds: 10) == [0, 0.5, -0.5, Float(32_767) / 32_768])
    check("the preview keeps only the window's end", Logic.tail(of: wav, seconds: 2.0 / 16_000) == [-0.5, Float(32_767) / 32_768])
    check("the menu bar keeps the end of what it heard", Logic.heard("short") == "short"
          && Logic.heard("one two three four", width: 12) == "…three four")

    print(failed == 0 ? "selftest: all passed" : "selftest: \(failed) failed")
    return failed == 0 ? 0 : 1
}
