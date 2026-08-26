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

nonisolated enum PendingDownloadDataRemovalEntry: Sendable {
    case valid(PendingDownloadDataRemovalManifest)
    case invalid(downloadID: UUID?, message: String)
    case unavailable(downloadID: UUID?, message: String)

    var downloadID: UUID? {
        switch self {
        case let .valid(manifest):
            manifest.record.id
        case let .invalid(downloadID, _),
             let .unavailable(downloadID, _):
            downloadID
        }
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
        try lock.withLock {
            try createDirectoryIfNeeded()
            let url = manifestURL(for: record.id)
            if try DurableFileSystem.itemExists(at: url) {
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
        try recoveryEntries().map { entry in
            switch entry {
            case let .valid(manifest):
                manifest
            case .invalid:
                throw CocoaError(.fileReadCorruptFile)
            case let .unavailable(_, message):
                throw PendingDownloadDataRemovalStoreError.unavailable(message)
            }
        }
    }

    func recoveryEntries() throws -> [PendingDownloadDataRemovalEntry] {
        try lock.withLock {
            guard try DurableFileSystem.itemExists(at: directoryURL) else {
                return []
            }
            try validateDirectory()
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            .filter { $0.pathExtension == "json" }
            .map(recoveryEntry(at:))
        }
    }

    func acknowledge(downloadID: UUID) {
        try? acknowledgeOrThrow(downloadID: downloadID)
    }

    func acknowledgeOrThrow(downloadID: UUID) throws {
        try lock.withLock {
            let url = manifestURL(for: downloadID)
            guard try DurableFileSystem.itemExists(at: url) else {
                return
            }
            try validateDirectory()
            try fileManager.removeItem(at: url)
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
        }
    }

    private func transition(
        downloadID: UUID,
        to phase: PendingDownloadRemovalPhase
    ) throws -> PendingDownloadDataRemovalManifest {
        try lock.withLock {
            try validateDirectory()
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

    private func recoveryEntry(
        at url: URL
    ) -> PendingDownloadDataRemovalEntry {
        let filenameID = UUID(
            uuidString: url.deletingPathExtension().lastPathComponent
        )
        guard url.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              url.pathExtension == "json",
              filenameID != nil else {
            return .invalid(
                downloadID: filenameID,
                message: "A pending download cleanup journal has an invalid filename."
            )
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            return .unavailable(
                downloadID: filenameID,
                message: error.localizedDescription
            )
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return .invalid(
                downloadID: filenameID,
                message: "A pending download cleanup journal is not a regular file."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unavailable(
                downloadID: filenameID,
                message: error.localizedDescription
            )
        }

        let manifest: PendingDownloadDataRemovalManifest
        do {
            manifest = try JSONDecoder().decode(
                PendingDownloadDataRemovalManifest.self,
                from: data
            )
        } catch {
            return .invalid(
                downloadID: filenameID,
                message: "A pending download cleanup journal is malformed."
            )
        }
        guard manifest.version == PendingDownloadDataRemovalManifest.currentVersion,
              manifest.record.id == filenameID else {
            return .invalid(
                downloadID: filenameID,
                message: "A pending download cleanup journal has invalid ownership metadata."
            )
        }
        return .valid(manifest)
    }

    private func manifestURL(for id: UUID) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }

    private func createDirectoryIfNeeded() throws {
        let existed = try DurableFileSystem.itemExists(at: directoryURL)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try validateDirectory()
        if existed == false {
            try DurableFileSystem.synchronizeParentDirectory(of: directoryURL)
        }
    }

    private func validateDirectory() throws {
        let values = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw PendingDownloadDataRemovalStoreError.unavailable(
                "Harbor’s pending download cleanup directory is not a safe owned directory."
            )
        }
    }

}

private enum PendingDownloadDataRemovalStoreError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        }
    }
}
