import Foundation

struct DirectDownloadRecoveryMetadata: Codable, Equatable, Sendable {
    let sourceURL: URL
    let entityTag: String?
    let lastModified: String?
    let expectedBytes: Int64
    let suggestedFilename: String?
    let mimeType: String?

    nonisolated var ifRangeValidator: String? {
        let trimmedEntityTag = entityTag?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedEntityTag.isEmpty == false,
           trimmedEntityTag.uppercased().hasPrefix("W/") == false,
           trimmedEntityTag.first == "\"",
           trimmedEntityTag.last == "\"" {
            return trimmedEntityTag
        }

        let trimmedLastModified = lastModified?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLastModified.isEmpty ? nil : trimmedLastModified
    }
}

struct DirectDownloadRecoverySnapshot: Equatable, Sendable {
    let bytesWritten: Int64
    let metadata: DirectDownloadRecoveryMetadata
}

enum DirectDownloadRecoveryResetReason: Equatable, Sendable {
    case missingValidator
    case sourceChanged
    case serverRejectedRange
}

struct DirectDownloadRecoveryPreparation: Sendable {
    let snapshot: DirectDownloadRecoverySnapshot?
    let resetReason: DirectDownloadRecoveryResetReason?
}

final class DirectDownloadRecoveryStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("DirectDownloadRecovery", isDirectory: true)
    }

    func prepareStart(
        id: UUID,
        sourceURL: URL
    ) throws -> DirectDownloadRecoveryPreparation {
        try withLock {
            let partialURL = partialURL(for: id)
            let bytesWritten = try fileSizeIfPresent(at: partialURL) ?? 0
            guard bytesWritten > 0 else {
                try removeItemIfPresent(at: metadataURL(for: id))
                return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: nil)
            }

            let metadata: DirectDownloadRecoveryMetadata?
            do {
                metadata = try loadMetadata(id: id)
            } catch {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: .missingValidator
                )
            }

            guard let metadata else {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: .missingValidator
                )
            }

            guard metadata.sourceURL == sourceURL else {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: .sourceChanged
                )
            }

            guard metadata.ifRangeValidator != nil else {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: .missingValidator
                )
            }

            return DirectDownloadRecoveryPreparation(
                snapshot: DirectDownloadRecoverySnapshot(
                    bytesWritten: bytesWritten,
                    metadata: metadata
                ),
                resetReason: nil
            )
        }
    }

    func snapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        withLock { () -> DirectDownloadRecoverySnapshot? in
            guard let bytesWritten = try? fileSizeIfPresent(at: partialURL(for: id)),
                  bytesWritten > 0 else {
                try? discardLocked(id: id)
                return nil
            }

            guard let metadata = try? loadMetadata(id: id),
                  metadata.sourceURL == sourceURL,
                  metadata.ifRangeValidator != nil else {
                try? discardLocked(id: id)
                return nil
            }

            return DirectDownloadRecoverySnapshot(
                bytesWritten: bytesWritten,
                metadata: metadata
            )
        }
    }

    func openFreshFile(id: UUID) throws -> FileHandle {
        try withLock {
            try createDirectoryIfNeeded()
            let partialURL = partialURL(for: id)
            try removeItemIfPresent(at: partialURL)
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forWritingTo: partialURL)
        }
    }

    func openFileForAppending(
        id: UUID,
        expectedOffset: Int64
    ) throws -> FileHandle {
        try withLock {
            let partialURL = partialURL(for: id)
            let actualOffset = try fileSizeIfPresent(at: partialURL) ?? 0
            guard actualOffset == expectedOffset else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The partial download changed while Harbor was preparing to resume it."
                    ]
                )
            }

            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            return handle
        }
    }

    func saveMetadata(
        _ metadata: DirectDownloadRecoveryMetadata,
        id: UUID
    ) throws {
        try withLock {
            try createDirectoryIfNeeded()
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL(for: id), options: .atomic)
        }
    }

    func recoveredByteCount(id: UUID) -> Int64? {
        withLock {
            try? fileSizeIfPresent(at: partialURL(for: id))
        } ?? nil
    }

    func takeCompletedFile(
        id: UUID,
        destinationURL: URL
    ) throws {
        try withLock {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try removeItemIfPresent(at: destinationURL)
            try fileManager.moveItem(at: partialURL(for: id), to: destinationURL)
            try? removeItemIfPresent(at: metadataURL(for: id))
        }
    }

    func discard(id: UUID) {
        withLock {
            try? discardLocked(id: id)
        }
    }

    func discardOrphans(retaining retainedIDs: Set<UUID>) {
        withLock {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else {
                return
            }

            let ids = Set(contents.compactMap { url -> UUID? in
                UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            })
            for id in ids.subtracting(retainedIDs) {
                try? discardLocked(id: id)
            }
        }
    }

    private func partialURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("part")
    }

    private func metadataURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }

    private func loadMetadata(id: UUID) throws -> DirectDownloadRecoveryMetadata? {
        let url = metadataURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        return try JSONDecoder().decode(
            DirectDownloadRecoveryMetadata.self,
            from: Data(contentsOf: url)
        )
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func discardLocked(id: UUID) throws {
        try removeItemIfPresent(at: partialURL(for: id))
        try removeItemIfPresent(at: metadataURL(for: id))
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
