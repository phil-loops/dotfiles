import Darwin
import Foundation
import Testing
@testable import CanopyUI

struct LocalDocumentFileTests {
    @Test func aPipeOrDeviceIsRefusedBeforeReading() throws {
        let pipe = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(mkfifo(pipe.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: pipe) }
        #expect(throws: CocoaError.self) { try LocalDocumentFile.read(pipe) }
        #expect(throws: CocoaError.self) { try LocalDocumentFile.read(URL(fileURLWithPath: "/dev/zero")) }
    }

    @Test func oversizedDocumentsAreUnavailableRatherThanReadWithoutABound() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(repeating: 0, count: LocalDocumentFile.limit + 1).write(to: path)
        #expect(throws: CocoaError(.fileReadTooLarge)) { try LocalDocumentFile.read(path) }
    }
}
