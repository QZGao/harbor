import CryptoKit
import Foundation

nonisolated struct BrowserCompletedTemporaryManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let handoff: CompletedDownloadHandoffManifest

    init(handoff: CompletedDownloadHandoffManifest) {
        self.version = Self.currentVersion
        self.handoff = handoff
    }
}

nonisolated struct BrowserRecordedCompletion: Sendable {
    let payloadURL: URL
    let metadataURL: URL
    let manifest: CompletedDownloadHandoffManifest
}

/// Owns WebKit's temporary payload and completion journal. WebKit lifecycle
/// state stays in `BrowserDownloadCoordinator`; durable filesystem ownership
/// and crash reconciliation stay here.
nonisolated final class BrowserDownloadRecoveryStore: @unchecked Sendable {
    private static let completedManifestExtension = "completion"

    private let fileManager: FileManager
    private let directoryURL: URL
    private let completedHandoffStore: CompletedDownloadHandoffStore

    init(
        fileManager: FileManager = .default,
        directoryURL: URL,
        completedHandoffStore: CompletedDownloadHandoffStore
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.completedHandoffStore = completedHandoffStore
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func freshPayloadURL(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = payloadURL(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier
        )

        // WebKit requires every proposed destination, including a resumed one,
        // to be absent when the delegate supplies it.
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return url
    }

    func recordCompletedPayload(
        _ manifest: CompletedDownloadHandoffManifest,
        at payloadURL: URL
    ) throws -> BrowserRecordedCompletion {
        // The payload must reach stable storage before the ownership marker.
        // A crash after the marker is committed can then safely finish hashing
        // and publication from this deterministic Application Support path.
        try DurableFileSystem.synchronizeFile(at: payloadURL)
        try DurableFileSystem.synchronizeParentDirectory(of: payloadURL)
        let metadataURL = completedManifestURL(
            downloadID: manifest.downloadID,
            attemptIdentifier: manifest.attemptIdentifier
        )
        try JSONEncoder().encode(
            BrowserCompletedTemporaryManifest(handoff: manifest)
        ).write(to: metadataURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: metadataURL)
        try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        return BrowserRecordedCompletion(
            payloadURL: payloadURL,
            metadataURL: metadataURL,
            manifest: manifest
        )
    }

    func publishRecordedCompletion(
        _ recorded: BrowserRecordedCompletion
    ) throws -> CompletedDownloadHandoff {
        let claiming = recorded.manifest
        let manifest = CompletedDownloadHandoffManifest(
            downloadID: claiming.downloadID,
            attemptIdentifier: claiming.attemptIdentifier,
            owner: claiming.owner,
            sourceURL: claiming.sourceURL,
            statusCode: claiming.statusCode,
            mimeType: claiming.mimeType,
            suggestedFilename: claiming.suggestedFilename,
            actualBytes: claiming.actualBytes,
            expectedBytes: claiming.expectedBytes,
            payloadSHA256: claiming.payloadSHA256,
            createdAt: claiming.createdAt
        )
        let handoff = try completedHandoffStore.publish(
            payloadAt: recorded.payloadURL,
            manifest: manifest
        )
        removeMetadata(at: recorded.metadataURL)
        return handoff
    }

    func recoverCompletedPayloads(
        downloadID requestedDownloadID: UUID?
    ) throws -> [UUID: String] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch let error as POSIXError where error.code == .ENOENT {
            return [:]
        }

        var failures: [UUID: String] = [:]
        for metadataURL in contents
        where metadataURL.pathExtension == Self.completedManifestExtension {
            guard let identifiers = Self.temporaryIdentifiers(from: metadataURL),
                  requestedDownloadID == nil
                    || identifiers.downloadID == requestedDownloadID else {
                continue
            }
            let payloadURL = payloadURL(
                downloadID: identifiers.downloadID,
                attemptIdentifier: identifiers.attemptIdentifier
            )
            let payloadExists: Bool
            do {
                payloadExists = try DurableFileSystem.itemExists(at: payloadURL)
            } catch {
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }
            guard payloadExists else {
                removeCompletedTemporaryFiles(
                    payloadURL: nil,
                    metadataURL: metadataURL
                )
                continue
            }

            let marker: BrowserCompletedTemporaryManifest
            do {
                let markerData = try Data(contentsOf: metadataURL)
                do {
                    marker = try JSONDecoder().decode(
                        BrowserCompletedTemporaryManifest.self,
                        from: markerData
                    )
                } catch {
                    removeCompletedTemporaryFiles(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL
                    )
                    continue
                }
            } catch {
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }

            let handoff = marker.handoff
            let values: URLResourceValues
            do {
                values = try payloadURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                // Failure to read file attributes is operational. The marker
                // and payload remain the only ownership journal, so retain
                // both and block a destructive retry.
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }
            guard marker.version == BrowserCompletedTemporaryManifest.currentVersion,
                  handoff.version == CompletedDownloadHandoffManifest.currentVersion,
                  handoff.downloadID == identifiers.downloadID,
                  handoff.attemptIdentifier == identifiers.attemptIdentifier,
                  handoff.owner == .browser,
                  handoff.phase == .claiming || handoff.phase == .ready,
                  handoff.destinationPath == nil,
                  handoff.placementStagingPath == nil,
                  handoff.actualBytes >= 0,
                  handoff.expectedBytes == handoff.actualBytes,
                  (handoff.phase == .claiming && handoff.payloadSHA256.isEmpty)
                    || (handoff.phase == .ready
                        && handoff.payloadSHA256.count == SHA256.byteCount * 2),
                  handoff.statusCode.map({ (200 ... 299).contains($0) }) != false,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == handoff.actualBytes else {
                removeCompletedTemporaryFiles(
                    payloadURL: payloadURL,
                    metadataURL: metadataURL
                )
                continue
            }

            do {
                _ = try publishRecordedCompletion(
                    BrowserRecordedCompletion(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL,
                        manifest: handoff
                    )
                )
            } catch {
                // These bytes passed their own integrity checks. A publish
                // failure describes the destination store, not corruption.
                failures[identifiers.downloadID] = error.localizedDescription
            }
        }
        return failures
    }

    func discardRecoveryData(downloadID: UUID) throws {
        try discardPartialFiles(downloadID: downloadID)
        try completedHandoffStore.discardThrowing(downloadID: downloadID)
    }

    func discardPartialFiles(downloadID: UUID) throws {
        let legacyURL = directoryURL
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")
        var removedEntry = false
        if try DurableFileSystem.itemExists(at: legacyURL) {
            try fileManager.removeItem(at: legacyURL)
            removedEntry = true
        }

        guard try DurableFileSystem.itemExists(at: directoryURL) else {
            return
        }
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for url in contents where (url.pathExtension == "part"
            || url.pathExtension == Self.completedManifestExtension)
            && Self.temporaryIdentifiers(from: url)?.downloadID == downloadID {
            try fileManager.removeItem(at: url)
            removedEntry = true
        }
        if removedEntry {
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
        }
    }

    func discardOrphans(retaining retainedIDs: Set<UUID>) {
        completedHandoffStore.discardLegacyUnvalidatedFiles(in: directoryURL)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.pathExtension == "part"
            || url.pathExtension == Self.completedManifestExtension {
            guard let identifiers = Self.temporaryIdentifiers(from: url),
                  retainedIDs.contains(identifiers.downloadID) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            if url.pathExtension == "part" {
                let metadataURL = completedManifestURL(
                    downloadID: identifiers.downloadID,
                    attemptIdentifier: identifiers.attemptIdentifier
                )
                let metadataExists: Bool
                do {
                    metadataExists = try DurableFileSystem.itemExists(at: metadataURL)
                } catch {
                    // An operational lookup failure is not proof that the
                    // completion marker is absent. Preserve the only payload.
                    continue
                }
                if metadataExists == false {
                    // A WebKit destination without a completed marker is an
                    // interrupted transfer, not a publishable file.
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    func discardUnrecoverablePayload(at url: URL) {
        guard (try? fileManager.removeItem(at: url)) != nil else { return }
        try? DurableFileSystem.synchronizeParentDirectory(of: url)
    }

    private func payloadURL(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> URL {
        directoryURL
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
            )
            .appendingPathExtension("part")
    }

    private func completedManifestURL(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> URL {
        directoryURL
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
            )
            .appendingPathExtension(Self.completedManifestExtension)
    }

    private static func temporaryIdentifiers(
        from url: URL
    ) -> (downloadID: UUID, attemptIdentifier: UUID)? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 73,
              name[name.index(name.startIndex, offsetBy: 36)] == "-" else {
            return nil
        }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard let downloadID = UUID(uuidString: String(name[..<separator])),
              let attemptIdentifier = UUID(
                  uuidString: String(name[name.index(after: separator)...])
              ) else {
            return nil
        }
        return (downloadID, attemptIdentifier)
    }

    private func removeMetadata(at url: URL) {
        guard (try? fileManager.removeItem(at: url)) != nil else { return }
        try? DurableFileSystem.synchronizeParentDirectory(of: url)
    }

    private func removeCompletedTemporaryFiles(
        payloadURL: URL?,
        metadataURL: URL
    ) {
        if let payloadURL {
            try? fileManager.removeItem(at: payloadURL)
        }
        removeMetadata(at: metadataURL)
    }
}
