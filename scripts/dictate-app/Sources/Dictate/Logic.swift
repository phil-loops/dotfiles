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

    /// Every sample of a 16 kHz mono 16-bit WAV, whole or cut off mid-recording.
    static func samples(of data: Data) -> [Float] { tail(of: data, seconds: Double(data.count)) }

    /// The end of the words heard so far, at most `width` characters, starting on a word.
    static func heard(_ text: String, width: Int = 40) -> String {
        guard text.count > width else { return text }
        return "…" + text.suffix(width - 1).drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
    }

    /// A spoken review Show starts and finishes: `dictate://review/start?dir=<path>` or `dictate://review/finish?dir=<path>`.
    static func review(of link: URL) -> (start: Bool, dir: URL)? {
        guard link.scheme == "dictate", link.host == "review",
              let dir = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dir" })?.value,
              dir.hasPrefix("/") else { return nil }
        switch link.lastPathComponent {
        case "start": return (true, URL(fileURLWithPath: dir))
        case "finish": return (false, URL(fileURLWithPath: dir))
        default: return nil
        }
    }

    /// The stretches of 16 kHz speech between pauses, as sample ranges: a run of quiet `pause` seconds long ends one, and
    /// one longer than `longest` is cut at its quietest moment, so a review's words can follow the page they were said on.
    static func utterances(of samples: [Float], pause: Double = 0.6, longest: Double = 15) -> [Range<Int>] {
        let frame = 480
        let frames = samples.count / frame
        guard frames > 0 else { return [] }
        let loudness = (0..<frames).map { f -> Float in
            let slice = samples[f * frame..<(f + 1) * frame]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
        }
        let sorted = loudness.sorted()
        let threshold = max(min(sorted[frames / 10] * 3, sorted[frames * 98 / 100] * 0.3), 0.006)
        let gap = Int(pause * 16_000) / frame
        var runs: [Range<Int>] = []
        var start: Int?, quiet = 0
        for (f, level) in loudness.enumerated() {
            if level > threshold {
                if start == nil { start = f }
                quiet = 0
            } else if let s = start {
                quiet += 1
                if quiet >= gap { runs.append(s..<(f - quiet + 1)); start = nil; quiet = 0 }
            }
        }
        if let s = start { runs.append(s..<(frames - quiet)) }
        let most = Int(longest * 16_000) / frame
        var cut: [Range<Int>] = []
        for run in runs where run.count >= 8 {
            var rest = run
            while rest.count > most {
                let window = (rest.lowerBound + most / 2)..<(rest.lowerBound + most)
                let quietest = window.min { loudness[$0] < loudness[$1] } ?? window.lowerBound
                cut.append(rest.lowerBound..<quietest)
                rest = quietest..<rest.upperBound
            }
            cut.append(rest)
        }
        let pad = 5
        return cut.map { max(0, ($0.lowerBound - pad) * frame)..<min(samples.count, ($0.upperBound + pad) * frame) }
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
    check("a cut-off recording is read whole", Logic.samples(of: wav) == [0, 0.5, -0.5, Float(32_767) / 32_768])
    check("the menu bar keeps the end of what it heard", Logic.heard("short") == "short"
          && Logic.heard("one two three four", width: 12) == "…three four")

    let started = Logic.review(of: URL(string: "dictate://review/start?dir=/tmp/r%201")!)
    check("a review link starts a recording into its folder", started?.start == true && started?.dir.path == "/tmp/r 1")
    check("a review link finishes one", Logic.review(of: URL(string: "dictate://review/finish?dir=/tmp/r")!)?.start == false
          && Logic.review(of: URL(string: "dictate://review/finish?dir=relative")!) == nil)
    func speech(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.2) } }
    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.001, count: Int(seconds * 16_000)) }
    let said = Logic.utterances(of: silence(1) + speech(1) + silence(1) + speech(0.5) + silence(0.3) + speech(0.5) + silence(1))
    check("a long pause ends an utterance and a short one doesn't", said.count == 2
          && abs(said[0].lowerBound - 13_600) < 1_000 && abs(said[1].upperBound - 71_200) < 1_000)
    check("a click is not an utterance", Logic.utterances(of: silence(1) + speech(0.1) + silence(1)).isEmpty)
    let long = Logic.utterances(of: silence(1) + speech(40) + silence(1))
    check("a long stretch without a pause is cut", long.count >= 3 && long.allSatisfy { $0.count <= 15 * 16_000 + 10 * 480 })

    print(failed == 0 ? "selftest: all passed" : "selftest: \(failed) failed")
    return failed == 0 ? 0 : 1
}
