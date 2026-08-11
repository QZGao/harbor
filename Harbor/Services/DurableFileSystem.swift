import Darwin
import Foundation

enum DurableFileSystem {
    nonisolated static func writeAtomicallyWithoutReplacing(
        _ data: Data,
        to destinationURL: URL
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".harbor-\(UUID().uuidString).tmp"
        )
        let descriptor = temporaryURL.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw posixError()
        }

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if temporaryFileExists {
                temporaryURL.path.withCString { path in
                    _ = Darwin.unlink(path)
                }
            }
        }

        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else {
                return
            }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw posixError()
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw posixError()
        }
        descriptorIsOpen = false

        let renameResult = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw CocoaError(.fileWriteFileExists)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        temporaryFileExists = false
        try synchronizeDirectory(at: directoryURL)
    }

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
