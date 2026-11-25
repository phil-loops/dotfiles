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
    private var failure: String?
    private(set) var busy = false

    var active: Bool { deliver != nil }
    var onError: ((String) -> Void)?
    var idleMenu: (NSMenu) -> Void = { _ in }

    override init() {
        super.init()
        update()
    }

    func start(to target: String, deliver: @escaping (String) -> Void) {
        guard !active, !busy else { return }
        self.target = target
        self.deliver = deliver
        busy = true
        update()
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                reset()
                onError?("Allow Dictate in System Settings → Privacy & Security → Microphone")
                return
            }
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(UUID().uuidString).wav")
                let recorder = try AVAudioRecorder(url: file, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                ])
                recorder.delegate = self
                guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
                NSSound(named: "Tink")?.play()
                self.file = file
                self.recorder = recorder
                busy = false
                startPreview(of: file)
                update()
            } catch {
                reset()
                onError?("Couldn’t start the microphone. " + error.localizedDescription)
            }
        }
    }

    @objc func finish() {
        guard let recorder else { return }
        NSSound(named: "Pop")?.play()
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        transcribe()
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
                if text.isEmpty { onError?("Parakeet didn’t hear any speech") } else { deliver?(text) }
            } catch {
                busy = false
                failure = error.localizedDescription
                update()
                onError?("Transcription failed; retry from the menu-bar mic. " + error.localizedDescription)
            }
        }
    }

    @objc func reset() {
        preview?.cancel()
        preview = nil
        heard = ""
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
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
        if recorder != nil {
            bubble.show(heard.isEmpty ? "Listening to \(target)…" : heard, dim: heard.isEmpty)
        } else if busy && deliver != nil && file != nil {
            bubble.show(heard.isEmpty ? "Transcribing…" : heard, dim: true)
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
