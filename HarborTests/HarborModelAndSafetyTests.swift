import Foundation
import XCTest
@testable import Harbor

@MainActor
final class HarborModelAndSafetyTests: XCTestCase {
    struct ChildMediaAttemptReceipt: Encodable {
        let version: Int
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let destinationFolderPath: String
        let isCollection: Bool
        let preexistingDestinationFiles: [
            String: MediaDownloadService.RegularFileIdentity
        ]
        let createdAt: Date
    }

    func writeChildOwnedMediaCompletionEvidence(
        recoveryFolder: URL,
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        completedURLs: [URL],
        isCollection: Bool = false,
        includeSuccessMarker: Bool = true,
        preexistingDestinationFiles: [
            String: MediaDownloadService.RegularFileIdentity
        ] = [:]
    ) throws {
        let receipt = ChildMediaAttemptReceipt(
            version: 1,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolderPath: destinationFolder.standardizedFileURL.path,
            isCollection: isCollection,
            preexistingDestinationFiles: preexistingDestinationFiles,
            createdAt: .now
        )
        try JSONEncoder().encode(receipt).write(
            to: recoveryFolder.appendingPathComponent(".harbor-attempt.json"),
            options: .atomic
        )
        let pathLines = try completedURLs.map { url in
            let encodedPath = try XCTUnwrap(
                String(data: JSONEncoder().encode(url.path), encoding: .utf8)
            )
            return "harbor-file:\(encodedPath)"
        }.joined(separator: "\n") + "\n"
        try Data(pathLines.utf8).write(
            to: recoveryFolder.appendingPathComponent(".harbor-final-paths.jsonl"),
            options: .atomic
        )
        if includeSuccessMarker {
            try Data("\(attemptIdentifier.uuidString)\n".utf8).write(
                to: recoveryFolder.appendingPathComponent(".harbor-process-succeeded"),
                options: .atomic
            )
        }
    }

    func makeCompletedHandoff(
        payloadURL: URL,
        handoffDirectoryURL: URL,
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        owner: CompletedDownloadHandoffOwner = .direct,
        suggestedFilename: String? = nil,
        statusCode: Int? = 200,
        mimeType: String? = "application/octet-stream"
    ) throws -> CompletedDownloadHandoff {
        let byteCount = Int64(try Data(contentsOf: payloadURL).count)
        return try CompletedDownloadHandoffStore(directoryURL: handoffDirectoryURL).publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier,
                owner: owner,
                sourceURL: sourceURL,
                statusCode: statusCode,
                mimeType: mimeType,
                suggestedFilename: suggestedFilename,
                actualBytes: byteCount,
                expectedBytes: byteCount
            )
        )
    }


    func legacyTorrentRecord(status: DownloadStatus) throws -> DownloadRecord {
        let record = DownloadRecord(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/legacy.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            fileLocationPath: nil,
            status: status,
            progress: 0,
            bytesWritten: 0,
            expectedBytes: 0,
            createdAt: .now,
            startedAt: nil,
            finishedAt: nil,
            updatedAt: .now,
            lastError: nil,
            resumeData: nil,
            backendIdentifier: nil,
            metadataName: nil
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        [
            "downloadLimitOverride",
            "uploadLimitOverride",
            "requiresMediaRecoveryReset",
            "torrentFingerprint",
            "torrentSourceFingerprint",
            "managedTorrentSourcePath",
            "torrentPayloadPaths",
            "uploadedBytes",
            "shouldSeedAfterDownload",
            "removeOriginalTorrentAfterImport",
            "completionNotificationDelivered"
        ].forEach { object.removeValue(forKey: $0) }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
    }

    func makeTorrentItem(
        sourceURL: URL,
        sourceKind: DownloadSourceKind,
        status: DownloadStatus = .completed,
        metadataName: String? = nil,
        fileLocationPath: String? = nil
    ) -> DownloadItem {
        DownloadItem(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            fileLocationPath: fileLocationPath,
            status: status,
            metadataName: metadataName
        )
    }
}
