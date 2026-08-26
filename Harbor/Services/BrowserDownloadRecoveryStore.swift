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
    let claimingManifest: CompletedDownloadHandoffManifest
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
            claimingManifest: manifest
        )
    }

    func publishRecordedCompletion(
        _ recorded: BrowserRecordedCompletion
    ) throws -> CompletedDownloadHandoff {
        let claiming = recorded.claimingManifest
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
            createdAt: claiming.createdAt
        )
        let handoff = try completedHandoffStore.publish(
            payloadAt: recorded.payloadURL,
            manifest: manifest
        )
        removeMetadataAfterPublication(at: recorded.metadataURL)
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

            var handoff = marker.handoff
            do {
                let values = try payloadURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
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

                if handoff.phase == .claiming {
                    handoff = try finalizedManifest(
                        handoff,
                        payloadURL: payloadURL,
                        metadataURL: metadataURL
                    )
                } else if try DurableFileSystem.sha256(at: payloadURL) != handoff.payloadSHA256 {
                    removeCompletedTemporaryFiles(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL
                    )
                    continue
                }
            } catch {
                // Failure to read file attributes is operational. The marker
                // and payload remain the only ownership journal, so retain
                // both and block a destructive retry.
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }

            do {
                _ = try completedHandoffStore.publish(
                    payloadAt: payloadURL,
                    manifest: handoff
                )
                removeCompletedTemporaryFiles(
                    payloadURL: nil,
                    metadataURL: metadataURL
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
        do {
            try fileManager.removeItem(at: url)
            try DurableFileSystem.synchronizeParentDirectory(of: url)
        } catch {
            // The payload has no durable completion marker and cannot be
            // published. Cleanup is best effort.
        }
    }

    private func finalizedManifest(
        _ claimingManifest: CompletedDownloadHandoffManifest,
        payloadURL: URL,
        metadataURL: URL
    ) throws -> CompletedDownloadHandoffManifest {
        let payloadSHA256 = try DurableFileSystem.sha256(at: payloadURL)
        if claimingManifest.payloadSHA256.isEmpty == false,
           claimingManifest.payloadSHA256 != payloadSHA256 {
            throw CompletedDownloadHandoffError.invalidPayload
        }
        let readyManifest = CompletedDownloadHandoffManifest(
            downloadID: claimingManifest.downloadID,
            attemptIdentifier: claimingManifest.attemptIdentifier,
            owner: claimingManifest.owner,
            sourceURL: claimingManifest.sourceURL,
            statusCode: claimingManifest.statusCode,
            mimeType: claimingManifest.mimeType,
            suggestedFilename: claimingManifest.suggestedFilename,
            actualBytes: claimingManifest.actualBytes,
            expectedBytes: claimingManifest.expectedBytes,
            payloadSHA256: payloadSHA256,
            createdAt: claimingManifest.createdAt
        )
        try JSONEncoder().encode(
            BrowserCompletedTemporaryManifest(handoff: readyManifest)
        ).write(to: metadataURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: metadataURL)
        try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        return readyManifest
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

    private func removeMetadataAfterPublication(at metadataURL: URL) {
        do {
            try fileManager.removeItem(at: metadataURL)
            try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        } catch {
            // The handoff is authoritative. Recovery safely prunes a stale
            // marker once it observes that the payload has moved.
        }
    }

    private func removeCompletedTemporaryFiles(
        payloadURL: URL?,
        metadataURL: URL
    ) {
        if let payloadURL {
            try? fileManager.removeItem(at: payloadURL)
        }
        do {
            try fileManager.removeItem(at: metadataURL)
            try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        } catch {
            // A malformed marker left behind cannot be published because each
            // recovery scan repeats the complete integrity validation.
        }
    }
}
