import AppKit
import AVFoundation
import Carbon
import FluidAudio

actor LearnTranscriber {
    private let manager = AsrManager(config: .default)

    func transcript(of url: URL) async throws -> String {
        if !(await manager.isAvailable) {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            try await manager.loadModels(models)
        }
        var decoder = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(url, decoderState: &decoder).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@preconcurrency @MainActor
final class LearnVoice: NSObject, AVAudioRecorderDelegate {
    private let transcriber = LearnTranscriber()
    private var recording: AVAudioRecorder?
    private var url: URL?
    private var receive: ((String) -> Void)?
    private var status: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var busy = false
    private var failure: String?
    let button = NSButton()

    var active: Bool { receive != nil }
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        configureButton()
    }

    private func configureButton() {
        let symbol: String
        let label: String
        if recording != nil {
            symbol = "stop.circle.fill"
            label = "Finish and send when the answer is ready"
        } else if let failure {
            symbol = "arrow.clockwise.circle"
            label = "Retry transcription. " + failure
        } else if busy {
            symbol = "waveform"
            label = "Preparing dictation"
        } else {
            symbol = "mic"
            label = "Dictate to the selected answer or message"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.bezelStyle = .texturedRounded
        button.refusesFirstResponder = true
        button.isEnabled = !busy
    }

    func toggle(receive: @escaping (String) -> Void) {
        if recording != nil { finish(); return }
        guard !busy else { return }
        if failure != nil { transcribe(); return }
        self.receive = receive
        busy = true
        configureButton()
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                reset()
                onError?("Allow Show in System Settings → Privacy & Security → Microphone to dictate.")
                return
            }
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("show-learn-\(UUID().uuidString).wav")
                url = file
                let recorder = try AVAudioRecorder(url: file, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                ])
                recorder.delegate = self
                guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
                recording = recorder
                busy = false
                installShortcut()
                updateStatus()
                configureButton()
            } catch {
                reset()
                onError?("Couldn’t start the microphone. " + error.localizedDescription)
            }
        }
    }

    @objc private func finish() {
        guard let recorder = recording else { return }
        recorder.delegate = nil
        recorder.stop()
        recording = nil
        removeShortcut()
        transcribe()
    }

    @objc private func transcribe() {
        guard let url, !busy else { return }
        failure = nil
        busy = true
        configureButton()
        updateStatus()
        Task {
            do {
                let text = try await transcriber.transcript(of: url)
                let deliver = receive
                reset()
                if text.isEmpty { onError?("Parakeet didn’t detect speech in this recording.") }
                else { deliver?(text) }
            } catch {
                busy = false
                failure = error.localizedDescription
                configureButton()
                updateStatus()
                onError?("Transcription failed. Retry from the microphone menu. " + error.localizedDescription)
            }
        }
    }

    private func updateStatus() {
        let item = status ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status = item
        let menu = NSMenu()
        func action(_ title: String, _ selector: Selector?) {
            let entry = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            entry.target = self
        }
        let label: String
        if recording != nil {
            label = "Learn is listening"
            action(hotKey == nil ? "Finish dictation" : "Finish dictation  ⌃⌥↩", #selector(finish))
            action("Discard recording", #selector(reset))
        } else if failure != nil {
            label = "Learn transcription failed"
            action("Retry transcription", #selector(transcribe))
            action("Discard recording", #selector(reset))
        } else {
            label = "Transcribing with Parakeet…"
            action(label, nil)
        }
        let symbol = recording != nil ? "mic.fill" : "waveform"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.toolTip = label
        item.menu = menu
    }

    @objc func reset() {
        recording?.delegate = nil
        recording?.stop()
        recording = nil
        removeShortcut()
        if let status { NSStatusBar.system.removeStatusItem(status) }
        status = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        receive = nil
        failure = nil
        busy = false
        configureButton()
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard recording === recorder else { return }
            reset()
            onError?("Recording stopped. " + (error?.localizedDescription ?? "The audio input failed."))
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard recording === recorder else { return }
            recording = nil
            removeShortcut()
            if flag {
                failure = "The input stopped. Transcribe this recording or discard it."
                configureButton()
                updateStatus()
            } else {
                reset()
                onError?("Recording stopped before the audio file could be saved.")
            }
        }
    }

    private func installShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var key = EventHotKeyID()
            guard let event, let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == 0x534C726E, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            let voice = Unmanaged<LearnVoice>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { voice.finish() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return }
        let key = EventHotKeyID(signature: 0x534C726E, id: 1)
        if RegisterEventHotKey(UInt32(kVK_Return), UInt32(controlKey | optionKey), key,
                               GetApplicationEventTarget(), 0, &hotKey) != noErr {
            removeShortcut()
        }
    }

    private func removeShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
