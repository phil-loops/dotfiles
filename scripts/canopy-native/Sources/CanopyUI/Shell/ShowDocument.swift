import AppKit
import CanopyCore

@MainActor
enum ShowDocument {
    static func open(_ document: URL) async throws {
        guard let show = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.philbrockman.show") else {
            throw Refusal("Show isn't installed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([document], withApplicationAt: show, configuration: .init()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
