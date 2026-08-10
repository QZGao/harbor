import Darwin
import Foundation

enum DurableFileSystem {
    nonisolated static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    nonisolated static func synchronizeDirectory(at directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
    }

    nonisolated static func synchronizeParentDirectory(of url: URL) throws {
        try synchronizeDirectory(at: url.deletingLastPathComponent())
    }

    private nonisolated static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
