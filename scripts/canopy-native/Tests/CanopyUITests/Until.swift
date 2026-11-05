import Foundation
import Testing

/// Waits until `ok` holds, polling. The timeout only catches a hang: it's set to what the full suite
/// needs under load, never to what a test takes alone, so a slow run passes and a stuck one fails.
@MainActor @discardableResult
func until(_ what: String, timeout: Double = 30, _ ok: () -> Bool) async -> Bool {
    let t0 = Date()
    while !ok() {
        if Date().timeIntervalSince(t0) > timeout { Issue.record("timed out waiting for \(what)"); return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
