import AppKit
import AVFoundation
import FluidAudio

actor Transcriber {
    private let manager = AsrManager(config: .default)

    func transcript(of url: URL) async throws -> String {
        try await load()
        var decoder = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(url, decoderState: &decoder).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcript(of samples: [Float]) async throws -> String {
        try await load()
        var decoder = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoder).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async throws {
        guard !(await manager.isAvailable) else { return }
        try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v2))
    }
}

/// One recording at a time: the menu-bar mic, the words heard so far beside it, and the finished transcript handed to `deliver`.
@MainActor
final class Voice: NSObject, AVAudioRecorderDelegate {
    private let transcriber = Transcriber()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let bubble = Bubble()
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var preview: Task<Void, Never>?
    private var heard = ""
    private var target = ""
    private var deliver: ((String) -> Void)?
    /// The folder of the spoken review this recording is for: its audio stays there, cut at pauses and transcribed piece by piece.
    private var reviewDir: URL?
    private var failure: String?
    private(set) var busy = false
    private var flashing: String?

    var active: Bool { deliver != nil }
    var failed: Bool { failure != nil }
    var onError: ((String) -> Void)?
    var idleMenu: (NSMenu) -> Void = { _ in }

    override init() {
        super.init()
        update()
    }

    /// Records a spoken review into `dir`: `recording.json` says when the audio began on the uptime clock Show stamps
    /// its trail with, and finishing writes `utterances.json` and hands the folder to `show-review-join`.
    func startReview(in dir: URL) {
        guard !active, !busy else { return }
        reviewDir = dir
        start(to: "a spoken review") { _ in }
    }

    func start(to target: String, deliver: @escaping (String) -> Void) {
        guard !active, !busy else { return }
        self.target = target
        self.deliver = deliver
        busy = true
        update()
        Voice.chime(Settings.startSound)
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                reset()
                onError?("Allow Dictate in System Settings → Privacy & Security → Microphone")
                return
            }
            do {
                let file = reviewDir?.appendingPathComponent("audio.wav")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(UUID().uuidString).wav")
                let recorder = try AVAudioRecorder(url: file, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                ])
                recorder.delegate = self
                guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
                if let reviewDir {
                    let began = ["startUptimeNs": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)]
                    try JSONSerialization.data(withJSONObject: began).write(to: reviewDir.appendingPathComponent("recording.json"), options: .atomic)
                }
                self.file = file
                self.recorder = recorder
                busy = false
                if Settings.preview { startPreview(of: file) }
                update()
            } catch {
                reset()
                onError?("Couldn’t start the microphone. " + error.localizedDescription)
            }
        }
    }

    /// Names who the words go to once that's known, which for a tmux pane is after the recording has started.
    func retarget(_ target: String) {
        self.target = target
        update()
    }

    static func chime(_ name: String) {
        if !name.isEmpty { NSSound(named: name)?.play() }
    }

    /// A short message in the preview box, shown whether or not the live preview is on.
    /// The words in a recording left behind when a Dictate before this one stopped mid-sentence.
    func recover(_ file: URL) async -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let samples = Logic.samples(of: data)
        guard samples.count >= 8_000 else { return nil }
        return try? await transcriber.transcript(of: samples)
    }

    func flash(_ message: String) {
        flashing = message
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.flashing == message else { return }
            self.flashing = nil
            self.update()
        }
    }

    @objc func finish() {
        guard let recorder else { return }
        Voice.chime(Settings.finishSound)
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        if reviewDir != nil { transcribeReview() } else { transcribe() }
    }

    func retry() { if reviewDir != nil { transcribeReview() } else { transcribe() } }

    /// Each stretch between pauses transcribed on its own and timed from the recording's start, then the folder handed on.
    private func transcribeReview() {
        guard let file, let reviewDir, !busy else { return }
        failure = nil
        busy = true
        update()
        Task {
            preview?.cancel()
            await preview?.value
            do {
                let said = try await Voice.transcribeReview(file, into: reviewDir, with: transcriber)
                rememberDictation(said.compactMap { $0["text"] as? String }.joined(separator: " "))
                self.file = nil
                reset()
                Task.detached { _ = run([showReviewJoin, reviewDir.path]) }
                flash(said.isEmpty ? "Parakeet didn’t hear any speech in the review" : "Review sent to Show’s Inbox")
            } catch {
                busy = false
                failure = error.localizedDescription
                update()
                onError?("Transcribing the review failed; retry from the menu-bar mic. The audio stays in \(reviewDir.path). " + error.localizedDescription)
            }
        }
    }

    @objc private func transcribe() {
        guard let file, !busy else { return }
        failure = nil
        busy = true
        update()
        Task {
            preview?.cancel()
            await preview?.value
            do {
                let text = try await transcriber.transcript(of: file)
                let deliver = self.deliver
                reset()
                if text.isEmpty { onError?("Parakeet didn’t hear any speech") } else { rememberDictation(text); deliver?(text) }
            } catch ASRError.invalidAudioData {
                reset()
                flash("Too short to transcribe; nothing sent")
            } catch {
                busy = false
                failure = error.localizedDescription
                update()
                onError?("Transcription failed; retry from the menu-bar mic. " + error.localizedDescription)
            }
        }
    }

    /// Cuts a review's audio at pauses, transcribes each stretch timed from the audio's start, and writes `utterances.json`.
    nonisolated static func transcribeReview(_ file: URL, into dir: URL, with transcriber: Transcriber) async throws -> [[String: Any]] {
        let samples = Logic.samples(of: try Data(contentsOf: file))
        var said: [[String: Any]] = []
        for range in Logic.utterances(of: samples) {
            var slice = Array(samples[range])
            if slice.count < 16_000 { slice += [Float](repeating: 0, count: 16_000 - slice.count) }
            let text = try await transcriber.transcript(of: slice)
            if !text.isEmpty { said.append(["start": Double(range.lowerBound) / 16_000, "end": Double(range.upperBound) / 16_000, "text": text]) }
        }
        try JSONSerialization.data(withJSONObject: ["utterances": said], options: .prettyPrinted)
            .write(to: dir.appendingPathComponent("utterances.json"), options: .atomic)
        return said
    }

    @objc func reset() {
        preview?.cancel()
        preview = nil
        heard = ""
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let file, reviewDir == nil { try? FileManager.default.removeItem(at: file) }
        file = nil
        reviewDir = nil
        deliver = nil
        failure = nil
        busy = false
        update()
    }

    private func startPreview(of file: URL) {
        preview = Task { [weak self, transcriber] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let data = try? Data(contentsOf: file) else { return }
                let samples = Logic.tail(of: data, seconds: 8)
                guard samples.count >= 8_000, let text = try? await transcriber.transcript(of: samples), !Task.isCancelled else { continue }
                await MainActor.run {
                    guard let self, self.recorder != nil else { return }
                    self.heard = Logic.heard(text, width: 180)
                    self.update()
                }
            }
        }
    }

    private func update() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector?) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let symbol: String
        let label: String
        if recorder != nil {
            symbol = "mic.fill"
            label = "Dictating to \(target)"
            item(label, nil)
            item("Finish  (🌐 🌐)", #selector(finish))
            item("Discard recording", #selector(reset))
        } else if failure != nil {
            symbol = "exclamationmark.triangle"
            label = "Transcription failed"
            item("Retry transcription", #selector(transcribe))
            item("Discard recording", #selector(reset))
        } else if busy {
            symbol = "waveform"
            label = "Transcribing…"
            item(label, nil)
        } else {
            symbol = "mic"
            label = "Dictate"
            idleMenu(menu)
        }
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        status.button?.toolTip = label
        if !Settings.preview, flashing == nil {
            bubble.hide()
        } else if recorder != nil {
            bubble.show(heard.isEmpty ? "Listening for \(target)…" : heard, dim: heard.isEmpty)
        } else if busy && deliver != nil && file != nil {
            bubble.show(heard.isEmpty ? "Transcribing…" : heard, dim: true)
        } else if let flashing {
            bubble.show(flashing, dim: true)
        } else {
            bubble.hide()
        }
        status.menu = menu
        status.isVisible = recorder == nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.recorder = nil
            preview?.cancel()
            if flag {
                failure = "The microphone stopped"
                update()
                onError?("The microphone stopped; transcribe or discard from the menu-bar mic")
            } else {
                reset()
                onError?("Recording stopped before the audio could be saved")
            }
        }
    }
}
