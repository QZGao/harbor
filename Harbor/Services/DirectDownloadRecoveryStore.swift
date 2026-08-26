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

enum DirectDownloadRecoveryLookup: Sendable {
    case available(DirectDownloadRecoverySnapshot)
    case absent
    case unavailable(String)
}

enum DirectDownloadRecoveryResetReason: Equatable, Sendable {
    case missingValidator
    case sourceChanged
    case invalidLength
    case serverRejectedRange
}

struct DirectDownloadRecoveryPreparation: Sendable {
    let snapshot: DirectDownloadRecoverySnapshot?
    let resetReason: DirectDownloadRecoveryResetReason?
}

final class DirectDownloadRecoveryStore: @unchecked Sendable {
    private enum IntegrityError: Error {
        case invalidMetadata
        case invalidPartial

        var resetReason: DirectDownloadRecoveryResetReason {
            switch self {
            case .invalidMetadata:
                .missingValidator
            case .invalidPartial:
                .invalidLength
            }
        }
    }

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
        try lock.withLock {
            do {
                let preparation = try recoveryPreparation(id: id, sourceURL: sourceURL)
                if preparation.snapshot == nil {
                    try discardLocked(id: id)
                }
                return preparation
            } catch let error as IntegrityError {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: error.resetReason
                )
            }
        }
    }

    func snapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        guard case let .available(snapshot) = lookup(id: id, sourceURL: sourceURL) else {
            return nil
        }
        return snapshot
    }

    func lookup(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoveryLookup {
        lock.withLock { () -> DirectDownloadRecoveryLookup in
            do {
                guard let snapshot = try recoveryPreparation(
                    id: id,
                    sourceURL: sourceURL
                ).snapshot else {
                    try discardLocked(id: id)
                    return .absent
                }
                return .available(snapshot)
            } catch is IntegrityError {
                do {
                    try discardLocked(id: id)
                    return .absent
                } catch {
                    return .unavailable(error.localizedDescription)
                }
            } catch {
                // Operational failures (for example, a temporarily
                // inaccessible volume) are not evidence that the recovery
                // data is invalid. Leave both files untouched so a later
                // lookup can recover them.
                return .unavailable(error.localizedDescription)
            }
        }
    }

    func openFreshFile(id: UUID) throws -> FileHandle {
        try lock.withLock {
            try DurableFileSystem.createDirectoryIfNeeded(
                at: directoryURL,
                fileManager: fileManager
            )
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
        try lock.withLock {
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
        try lock.withLock {
            try DurableFileSystem.createDirectoryIfNeeded(
                at: directoryURL,
                fileManager: fileManager
            )
            let data = try JSONEncoder().encode(metadata)
            let destinationURL = metadataURL(for: id)
            try data.write(to: destinationURL, options: .atomic)
            try DurableFileSystem.synchronizeFile(at: destinationURL)
            try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
        }
    }

    func recoveredByteCount(id: UUID) -> Int64? {
        lock.withLock {
            try? fileSizeIfPresent(at: partialURL(for: id))
        } ?? nil
    }

    func publishCompletedPayload<T>(
        id: UUID,
        expectedBytes: Int64,
        _ publish: (URL) throws -> T
    ) throws -> T {
        try lock.withLock {
            let url = partialURL(for: id)
            let actualBytes = try fileSizeIfPresent(at: url)
            guard let actualBytes,
                  actualBytes >= 0,
                  expectedBytes <= 0 || actualBytes == expectedBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }

            // Keep the recovery lease while the immutable completion store
            // claims the file. Otherwise cancellation or a same-ID restart can
            // replace/delete the path after validation but before publication.
            let result = try publish(url)
            try? discardLocked(id: id)
            return result
        }
    }

    func discard(id: UUID) {
        try? discardThrowing(id: id)
    }

    func discardThrowing(id: UUID) throws {
        try lock.withLock {
            try discardLocked(id: id)
        }
    }

    func discardOrphans(retaining retainedIDs: Set<UUID>) {
        lock.withLock {
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
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(
                DirectDownloadRecoveryMetadata.self,
                from: data
            )
        } catch {
            throw IntegrityError.invalidMetadata
        }
    }

    private func recoveryPreparation(
        id: UUID,
        sourceURL: URL
    ) throws -> DirectDownloadRecoveryPreparation {
        let bytesWritten = try fileSizeIfPresent(at: partialURL(for: id)) ?? 0
        guard bytesWritten > 0 else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: nil)
        }
        guard let metadata = try loadMetadata(id: id) else {
            return DirectDownloadRecoveryPreparation(
                snapshot: nil,
                resetReason: .missingValidator
            )
        }
        guard metadata.sourceURL == sourceURL else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .sourceChanged)
        }
        guard metadata.ifRangeValidator != nil else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .missingValidator)
        }
        guard metadata.expectedBytes <= 0 || bytesWritten <= metadata.expectedBytes else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .invalidLength)
        }
        return DirectDownloadRecoveryPreparation(
            snapshot: DirectDownloadRecoverySnapshot(
                bytesWritten: bytesWritten,
                metadata: metadata
            ),
            resetReason: nil
        )
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64? {
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }

        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw IntegrityError.invalidPartial
        }
        return Int64(fileSize)
    }

    private func discardLocked(id: UUID) throws {
        try removeItemIfPresent(at: partialURL(for: id))
        try removeItemIfPresent(at: metadataURL(for: id))
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard try DurableFileSystem.itemExists(at: url) else {
            return
        }
        try fileManager.removeItem(at: url)
        try DurableFileSystem.synchronizeParentDirectory(of: url)
    }

}
