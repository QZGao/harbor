import Foundation

nonisolated struct TorrentSubmissionReservation: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let ownerDownloadID: UUID
    let gid: String
    let sourceURL: URL
    let sourceKind: DownloadSourceKind?
    let destinationFolderPath: String
    let shouldSeedAfterDownload: Bool?
    let createdAt: Date

    init(
        ownerDownloadID: UUID,
        gid: String,
        sourceURL: URL,
        destinationFolderPath: String,
        sourceKind: DownloadSourceKind? = nil,
        shouldSeedAfterDownload: Bool? = nil,
        createdAt: Date = .now
    ) {
        self.version = Self.currentVersion
        self.ownerDownloadID = ownerDownloadID
        self.gid = gid
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.destinationFolderPath = destinationFolderPath
        self.shouldSeedAfterDownload = shouldSeedAfterDownload
        self.createdAt = createdAt
    }
}

/// Durable ownership written before an aria2 add request. The reservation
/// makes an ambiguous RPC result retryable by exact GID instead of by another
/// non-idempotent add operation.
nonisolated final class TorrentSubmissionReservationStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let lock = NSLock()

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("TorrentSubmissionReservations", isDirectory: true)
    }

    func reserve(
        ownerDownloadID: UUID,
        sourceURL: URL,
        destinationFolderPath: String,
        sourceKind: DownloadSourceKind? = nil,
        shouldSeedAfterDownload: Bool? = nil
    ) throws -> TorrentSubmissionReservation {
        try withLock {
            try createDirectoryIfNeeded()
            let url = reservationURL(for: ownerDownloadID)
            if try itemExists(at: url) {
                let existing = try validatedReservation(at: url)
                guard existing.sourceURL == sourceURL,
                      existing.destinationFolderPath == destinationFolderPath,
                      existing.sourceKind == nil || existing.sourceKind == sourceKind,
                      existing.shouldSeedAfterDownload == nil
                        || existing.shouldSeedAfterDownload == shouldSeedAfterDownload else {
                    throw CocoaError(.fileWriteFileExists)
                }
                return existing
            }

            let reservation = TorrentSubmissionReservation(
                ownerDownloadID: ownerDownloadID,
                gid: Self.makeGID(),
                sourceURL: sourceURL,
                destinationFolderPath: destinationFolderPath,
                sourceKind: sourceKind,
                shouldSeedAfterDownload: shouldSeedAfterDownload
            )
            try JSONEncoder().encode(reservation).write(to: url, options: .atomic)
            try DurableFileSystem.synchronizeFile(at: url)
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            return reservation
        }
    }

    func reservation(ownerDownloadID: UUID) throws -> TorrentSubmissionReservation? {
        try withLock {
            let url = reservationURL(for: ownerDownloadID)
            guard try itemExists(at: url) else {
                return nil
            }
            return try validatedReservation(at: url)
        }
    }

    func reservations() throws -> [TorrentSubmissionReservation] {
        try withLock {
            guard try itemExists(at: directoryURL) else {
                return []
            }
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            let reservations = try urls
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { try validatedReservation(at: $0) }
            guard Set(reservations.map(\.gid)).count == reservations.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return reservations
        }
    }

    func acknowledge(ownerDownloadID: UUID, gid: String) throws {
        try withLock {
            let url = reservationURL(for: ownerDownloadID)
            guard try itemExists(at: url) else {
                return
            }
            let reservation = try validatedReservation(at: url)
            guard reservation.gid == gid else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try fileManager.removeItem(at: url)
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
        }
    }

    private func validatedReservation(at url: URL) throws -> TorrentSubmissionReservation {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let filenameID = UUID(
                  uuidString: url.deletingPathExtension().lastPathComponent
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reservation = try JSONDecoder().decode(
            TorrentSubmissionReservation.self,
            from: Data(contentsOf: url)
        )
        guard reservation.version == TorrentSubmissionReservation.currentVersion,
              reservation.ownerDownloadID == filenameID,
              reservation.gid.range(
                  of: "^[0-9a-f]{16}$",
                  options: .regularExpression
              ) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return reservation
    }

    private func reservationURL(for id: UUID) -> URL {
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

    private static func makeGID() -> String {
        String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(16)
        )
    }

    private func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
