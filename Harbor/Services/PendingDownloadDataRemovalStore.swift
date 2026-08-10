import Foundation

nonisolated enum PendingDownloadRemovalPhase: String, Codable, Sendable {
    /// No payload mutation has started. Replay may safely begin deletion.
    case payloadPending
    /// Deletion may have started before a crash. Replay must never delete a
    /// pathname that now exists because it may be a replacement file.
    case payloadDeletionStarted
    /// Payload handling is complete; only record/backend cleanup may replay.
    case backendCleanup
}

nonisolated struct PendingDownloadDataRemovalManifest: Codable, Sendable {
    static let currentVersion = 3

    let version: Int
    let createdAt: Date
    let record: DownloadRecord
    let removesPayload: Bool
    let phase: PendingDownloadRemovalPhase

    init(
        record: DownloadRecord,
        removingData: Bool = true,
        phase: PendingDownloadRemovalPhase? = nil,
        createdAt: Date = .now
    ) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.record = record
        self.removesPayload = removingData
        self.phase = phase ?? (removingData ? .payloadPending : .backendCleanup)
    }
}

nonisolated final class PendingDownloadDataRemovalStore: @unchecked Sendable {
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
                .appendingPathComponent("PendingDownloadDataRemovals", isDirectory: true)
    }

    @discardableResult
    func publish(
        record: DownloadRecord,
        removingData: Bool = true
    ) throws -> PendingDownloadDataRemovalManifest {
        try withLock {
            try createDirectoryIfNeeded()
            let url = manifestURL(for: record.id)
            if try itemExists(at: url) {
                return try validatedManifest(at: url)
            }

            let manifest = PendingDownloadDataRemovalManifest(
                record: record,
                removingData: removingData
            )
            try write(manifest, to: url)
            return manifest
        }
    }

    func markPayloadDeletionStarted(
        downloadID: UUID
    ) throws -> PendingDownloadDataRemovalManifest {
        try transition(downloadID: downloadID, to: .payloadDeletionStarted)
    }

    func markBackendCleanup(
        downloadID: UUID
    ) throws -> PendingDownloadDataRemovalManifest {
        try transition(downloadID: downloadID, to: .backendCleanup)
    }

    func entries() throws -> [PendingDownloadDataRemovalManifest] {
        try withLock {
            guard try itemExists(at: directoryURL) else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            .filter { $0.pathExtension == "json" }
            .map(validatedManifest(at:))
        }
    }

    func acknowledge(downloadID: UUID) {
        try? acknowledgeOrThrow(downloadID: downloadID)
    }

    func acknowledgeOrThrow(downloadID: UUID) throws {
        try withLock {
            let url = manifestURL(for: downloadID)
            guard try itemExists(at: url) else {
                return
            }
            try fileManager.removeItem(at: url)
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
        }
    }

    private func transition(
        downloadID: UUID,
        to phase: PendingDownloadRemovalPhase
    ) throws -> PendingDownloadDataRemovalManifest {
        try withLock {
            let url = manifestURL(for: downloadID)
            let current = try validatedManifest(at: url)
            if current.phase == phase || current.phase == .backendCleanup {
                return current
            }
            guard current.phase == .payloadPending
                    || (current.phase == .payloadDeletionStarted
                        && phase == .backendCleanup) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let updated = PendingDownloadDataRemovalManifest(
                record: current.record,
                removingData: current.removesPayload,
                phase: phase,
                createdAt: current.createdAt
            )
            try write(updated, to: url)
            return updated
        }
    }

    private func write(
        _ manifest: PendingDownloadDataRemovalManifest,
        to url: URL
    ) throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: url)
        try DurableFileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func validatedManifest(
        at url: URL
    ) throws -> PendingDownloadDataRemovalManifest {
        guard url.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              url.pathExtension == "json",
              let filenameID = UUID(
                uuidString: url.deletingPathExtension().lastPathComponent
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(
            PendingDownloadDataRemovalManifest.self,
            from: Data(contentsOf: url)
        )
        guard manifest.version == PendingDownloadDataRemovalManifest.currentVersion,
              manifest.record.id == filenameID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private func manifestURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }

    private func createDirectoryIfNeeded() throws {
        let existed = try itemExists(at: directoryURL)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if existed == false {
            try DurableFileSystem.synchronizeParentDirectory(of: directoryURL)
        }
    }

    private func itemExists(at url: URL) throws -> Bool {
        do {
            _ = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        }
    }

    private func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
