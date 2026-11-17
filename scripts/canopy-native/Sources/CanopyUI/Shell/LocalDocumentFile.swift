import Darwin
import Foundation

struct LocalDocumentFile: Sendable {
    static let limit = 8_388_608
    let data: Data
    let modified: Date?

    static func read(_ url: URL) throws -> LocalDocumentFile {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw CocoaError(errno == ENOENT ? .fileReadNoSuchFile : .fileReadUnknown) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        guard before.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: min(65_536, limit + 1 - data.count)), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadUnknown) }
        let time = after.st_mtimespec
        return LocalDocumentFile(data: data, modified: Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000))
    }
}
