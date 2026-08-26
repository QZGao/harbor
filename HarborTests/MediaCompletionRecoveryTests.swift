import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testChildOwnedMediaReceiptRestoresCompletionAfterParentCrash() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborChildMediaReceipt-\(UUID().uuidString)")
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/video"))
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let completedURL = destinationRoot.appendingPathComponent("video.mp4")
        let payload = Data("completed-before-parent-crash".utf8)
        try payload.write(to: completedURL)

        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolder: destinationRoot,
            completedURLs: [completedURL]
        )

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        let entry = try await service.completedDownloadEntry(id: downloadID)
        guard case let .valid(manifest)? = entry else {
            return XCTFail("Expected the child-owned completion receipt to be promoted")
        }
        XCTAssertEqual(manifest.downloadID, downloadID)
        XCTAssertEqual(manifest.attemptIdentifier, attemptIdentifier)
        XCTAssertEqual(manifest.sourceURL, sourceURL)
        XCTAssertEqual(manifest.destinationFolderPath, destinationRoot.standardizedFileURL.path)
        XCTAssertEqual(manifest.fileLocationPath, completedURL.standardizedFileURL.path)
        XCTAssertEqual(manifest.actualBytes, Int64(payload.count))
        XCTAssertEqual(manifest.payloads.map(\.path), [completedURL.standardizedFileURL.path])
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: recoveryFolder.appendingPathComponent(".harbor-completion.json").path
            )
        )
    }

    func testChildOwnedMediaReceiptRejectsUnchangedPreexistingOutput() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborChildMediaPreexisting-\(UUID().uuidString)")
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/preexisting"))
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let completedURL = destinationRoot.appendingPathComponent("video.mp4")
        let originalPayload = Data("output-that-predated-the-attempt".utf8)
        try originalPayload.write(to: completedURL)

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        let preexistingIdentity = try await service.regularFileIdentity(at: completedURL)
        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolder: destinationRoot,
            completedURLs: [completedURL],
            preexistingDestinationFiles: [
                completedURL.standardizedFileURL.resolvingSymlinksInPath().path:
                    preexistingIdentity
            ]
        )

        let entry = try await service.completedDownloadEntry(id: downloadID)
        guard case let .invalid(rejectedID, message)? = entry else {
            return XCTFail("Expected unchanged pre-attempt output to be rejected")
        }
        XCTAssertEqual(rejectedID, downloadID)
        XCTAssertTrue(message.contains("existed before this attempt"))
        XCTAssertEqual(try Data(contentsOf: completedURL), originalPayload)
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: recoveryFolder.appendingPathComponent(".harbor-completion.json").path
            )
        )
    }

    func testInvalidChildOwnedMediaReceiptCanBeResetForRetry() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInvalidChildMediaReceipt-\(UUID().uuidString)")
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let completedURL = destinationRoot.appendingPathComponent("video.mp4")
        try Data("completed-output".utf8).write(to: completedURL)
        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/mismatch")),
            destinationFolder: destinationRoot,
            completedURLs: [completedURL]
        )
        try Data("\(UUID().uuidString)\n".utf8).write(
            to: recoveryFolder.appendingPathComponent(".harbor-process-succeeded"),
            options: .atomic
        )

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        guard case .invalid? = try await service.completedDownloadEntry(id: downloadID) else {
            return XCTFail("Expected mismatched child evidence to be invalid")
        }

        try await service.discardCompletionMarker(id: downloadID)
        let resetEntry = try await service.completedDownloadEntry(id: downloadID)
        XCTAssertNil(resetEntry)
        for filename in [
            ".harbor-completion.json",
            ".harbor-process-succeeded",
            ".harbor-final-paths.jsonl",
            ".harbor-attempt.json"
        ] {
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: recoveryFolder.appendingPathComponent(filename).path
                )
            )
        }
    }

    func testOrphanCleanupPromotesChildReceiptBeforeRetiringOwnership() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborOrphanChildMediaReceipt-\(UUID().uuidString)")
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/orphan"))
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let completedURL = destinationRoot.appendingPathComponent("video.mp4")
        try Data("orphan-completed-output".utf8).write(to: completedURL)
        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolder: destinationRoot,
            completedURLs: [completedURL]
        )

        let absentPID = pid_t(Int32.max)
        let ownership = MediaProcessOwnershipManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            pid: absentPID,
            processGroupIdentifier: absentPID,
            launchedExecutablePath: "/bin/sh",
            executablePath: "/bin/sh",
            temporaryFolderPath: recoveryFolder.standardizedFileURL.path,
            startSignature: "1:1",
            command: "/bin/sh \(recoveryFolder.path)"
        )
        let ownershipURL = recoveryFolder
            .appendingPathComponent(".harbor-process-owner.json")
        try JSONEncoder().encode(ownership).write(to: ownershipURL, options: .atomic)

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        try await service.terminateOrphanedMediaProcesses()

        XCTAssertFalse(fileManager.fileExists(atPath: ownershipURL.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: recoveryFolder.appendingPathComponent(".harbor-completion.json").path
            )
        )
        guard case let .valid(manifest)? = try await service.completedDownloadEntry(
            id: downloadID
        ) else {
            return XCTFail("Expected orphan cleanup to preserve the completed result")
        }
        XCTAssertEqual(manifest.attemptIdentifier, attemptIdentifier)
        XCTAssertEqual(manifest.fileLocationPath, completedURL.standardizedFileURL.path)
    }


    func testChildOwnedMediaReceiptRestoresCollectionThroughDownloadCenter() async throws {
        let suiteName = "HarborTests.MediaCompletionReplay.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionReplayTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let temporaryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let firstURL = destinationRoot.appendingPathComponent("episode-1.mp4")
        let secondURL = destinationRoot.appendingPathComponent("episode-2.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let firstPayload = Data("first-episode".utf8)
        let secondPayload = Data("second-episode".utf8)
        try firstPayload.write(to: firstURL)
        try secondPayload.write(to: secondURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/playlist")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .downloading,
            progress: 0.8,
            bytesWritten: 80,
            expectedBytes: 100
        )
        let attemptIdentifier = UUID()
        let actualBytes = Int64(firstPayload.count + secondPayload.count)
        let recoveryFolder = temporaryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolder: destinationRoot,
            completedURLs: [firstURL, secondURL],
            isCollection: true
        )

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let mediaService = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: temporaryRoot
        )
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("PendingRemoval"),
            mediaService: mediaService
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first { $0.id == item.id })
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.fileLocationPath, destinationRoot.path)
        XCTAssertEqual(restored.torrentPayloadPaths, [firstURL.path, secondURL.path])
        XCTAssertEqual(restored.bytesWritten, actualBytes)
        XCTAssertEqual(restored.expectedBytes, actualBytes)
        XCTAssertEqual(restored.progress, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: firstURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: secondURL.path))
        let persistedRecords = try await persistence.load()
        let persisted = try XCTUnwrap(persistedRecords.first)
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.torrentPayloadPaths, [firstURL.path, secondURL.path])
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testMediaCompletionJournalSurvivesRecordSaveFailure() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected media completion save failure" }
        }

        let suiteName = "HarborTests.MediaCompletionSaveFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionSaveFailure-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let payload = Data("durable-media".utf8)
        try payload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .paused
        )
        let attemptIdentifier = UUID()
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(payload.count),
                    sha256: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(payload.count)
        )
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(
            to: recoveryFolder.appendingPathComponent(".harbor-completion.json")
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])

        var failedCenter: DownloadCenter? = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            ),
            recordSaveOperation: { _, _, _ in
                throw ExpectedSaveFailure()
            }
        )
        await failedCenter?.initializeIfNeeded()

        XCTAssertEqual(failedCenter?.downloads.first?.status, .failed)
        XCTAssertTrue(fileManager.fileExists(atPath: recoveryFolder.path))
        let recordsAfterFailedSave = try await persistence.load()
        XCTAssertEqual(recordsAfterFailedSave.first?.status, .paused)
        failedCenter = nil

        let restoredCenter = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            )
        )
        await restoredCenter.initializeIfNeeded()

        XCTAssertEqual(restoredCenter.downloads.first?.status, .completed)
        XCTAssertEqual(restoredCenter.downloads.first?.bytesWritten, Int64(payload.count))
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        let recordsAfterRecovery = try await persistence.load()
        XCTAssertEqual(recordsAfterRecovery.first?.status, .completed)
        let shutdownSucceeded = await restoredCenter.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testInvalidMediaCompletionRotatesOutputPathBeforeDiscardingJournal() async throws {
        let suiteName = "HarborTests.InvalidMediaCompletionOutput.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInvalidMediaCompletion-\(UUID().uuidString)")
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let originalPayload = Data("original-completed-media".utf8)
        try originalPayload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .downloading
        )
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: UUID(),
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(originalPayload.count),
                    sha256: SHA256.hash(data: originalPayload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(originalPayload.count)
        )
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let markerURL = recoveryFolder.appendingPathComponent(".harbor-completion.json")
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: markerURL)
        let replacementPayload = Data("replacement-owned-by-another-writer".utf8)
        try replacementPayload.write(to: payloadURL)

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("PendingRemoval"),
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            )
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first)
        let conflictIdentifier = try XCTUnwrap(
            restored.mediaOutputConflictIdentifier
        )
        XCTAssertEqual(restored.status, .failed)
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try Data(contentsOf: payloadURL), replacementPayload)
        let storedRecords = try await persistence.load()
        XCTAssertEqual(
            storedRecords.first?.mediaOutputConflictIdentifier,
            conflictIdentifier
        )
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testMediaRetryReconcilesDurableCompletionInsteadOfStartingAnotherProcess() async throws {
        let suiteName = "HarborTests.MediaCompletionRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionRetry-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let temporaryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let payload = Data("already-finished-media".utf8)
        try payload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .failed
        )
        item.lastError = "The completion journal could not be published."
        let attemptIdentifier = UUID()
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(payload.count),
                    sha256: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(payload.count)
        )
        let recoveryFolder = temporaryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(
            to: recoveryFolder.appendingPathComponent(".harbor-completion.json")
        )

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let mediaService = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: temporaryRoot
        )
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: mediaService
        )
        center.downloads = [item]

        center.retryDownload(id: item.id)
        for _ in 0 ..< 200 where item.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.fileLocationPath, payloadURL.path)
        XCTAssertEqual(item.bytesWritten, Int64(payload.count))
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        let storedRecords = try await persistence.load()
        let stored = try XCTUnwrap(storedRecords.first)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fileLocationPath, payloadURL.path)
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testMediaRetryRetainsCompletionJournalWhenDestinationOwnershipChanged() async throws {
        let suiteName = "HarborTests.MediaCompletionOwnership.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionOwnership-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let completedDestination = testRoot.appendingPathComponent("OriginalDestination", isDirectory: true)
        let currentDestination = testRoot.appendingPathComponent("CurrentDestination", isDirectory: true)
        let payloadURL = completedDestination.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: completedDestination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: currentDestination, withIntermediateDirectories: true)
        let payload = Data("completed-at-the-original-destination".utf8)
        try payload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: currentDestination.path,
            status: .failed
        )
        let attemptIdentifier = UUID()
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolderPath: completedDestination.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(payload.count),
                    sha256: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(payload.count)
        )
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(
            to: recoveryFolder.appendingPathComponent(".harbor-completion.json")
        )

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            )
        )
        center.downloads = [item]

        center.retryDownload(id: item.id)
        for _ in 0 ..< 200
        where item.lastError?.contains("does not belong") != true {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .failed)
        XCTAssertTrue(item.lastError?.contains("does not belong") == true)
        XCTAssertNil(center.activeMediaAttemptIdentifier(for: item.id))
        XCTAssertTrue(fileManager.fileExists(atPath: recoveryFolder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: payloadURL.path))
        let storedRecords = try await persistence.load()
        let storedRecord = try XCTUnwrap(storedRecords.first)
        XCTAssertEqual(storedRecord.status, .failed)
        XCTAssertTrue(storedRecord.lastError?.contains("does not belong") == true)
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testMediaRetrySaveFailureDoesNotLeavePreparingItemWithoutAProcess() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected media recovery save failure" }
        }

        let suiteName = "HarborTests.MediaRetryFailureRollback.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaRetryFailureRollback-\(UUID().uuidString)", isDirectory: true)
        let persistence = DownloadPersistence(
            directoryURL: testRoot.appendingPathComponent("Persistence", isDirectory: true)
        )
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        try await persistence.save([item.makeRecord()])
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let markerURL = recoveryFolder.appendingPathComponent(".harbor-completion.json")
        try Data("{}".utf8).write(to: markerURL)

        let saveCounter = AsyncTestCounter()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            ),
            recordSaveOperation: { persistence, records, revision in
                let call = await saveCounter.incrementAndGet()
                if call == 1 {
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )
        center.downloads = [item]

        center.retryDownload(id: item.id)
        for _ in 0 ..< 200
        where item.lastError != "Expected media recovery save failure" {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.lastError, "Expected media recovery save failure")
        XCTAssertNil(center.activeMediaAttemptIdentifier(for: item.id))
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL.path))
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }


    func testRetryFinalizesPendingCompletionInsteadOfRedownloading() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPendingCompletionRetry-\(UUID().uuidString)")
        let handoffRoot = root.appendingPathComponent("handoffs", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        let persistenceRoot = root.appendingPathComponent("persistence", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let suiteName = "HarborTests.PendingCompletionRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let id = UUID()
        let attemptIdentifier = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let payload = Data("completed-payload".utf8)
        let payloadURL = root.appendingPathComponent("payload.bin")
        try payload.write(to: payloadURL)
        _ = try CompletedDownloadHandoffStore(directoryURL: handoffRoot).publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: id,
                attemptIdentifier: attemptIdentifier,
                owner: .direct,
                sourceURL: sourceURL,
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "archive.bin",
                actualBytes: Int64(payload.count),
                expectedBytes: Int64(payload.count)
            )
        )

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            completedHandoffDirectoryURL: handoffRoot
        )
        let item = DownloadItem(
            id: id,
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .failed
        )
        center.downloads = [item]

        center.retryDownload(id: id)
        for _ in 0 ..< 200 {
            if item.status == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .completed)
        let finalURL = try XCTUnwrap(item.fileLocationURL)
        XCTAssertEqual(try Data(contentsOf: finalURL), payload)
        XCTAssertTrue(try CompletedDownloadHandoffStore(directoryURL: handoffRoot).entries().isEmpty)
        await center.shutdownForTermination()
    }


    func testCompletionHashDoesNotBlockAnotherClaim() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborConcurrentCompletionClaims-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let firstID = UUID()
        let firstAttempt = UUID()
        let secondID = UUID()
        let secondAttempt = UUID()
        let hashEntered = LockedTestFlag()
        let releaseHash = DispatchSemaphore(value: 0)
        let secondClaimFinished = LockedTestFlag()
        let store = CompletedDownloadHandoffStore(
            directoryURL: root.appendingPathComponent("handoffs", isDirectory: true),
            payloadHashOperation: { url in
                if url.path.contains(firstAttempt.uuidString),
                   hashEntered.value == false {
                    hashEntered.set()
                    releaseHash.wait()
                }
                return SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let firstPayloadURL = root.appendingPathComponent("first.bin")
        let secondPayloadURL = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x41, count: 1_024).write(to: firstPayloadURL)
        try Data(repeating: 0x42, count: 128).write(to: secondPayloadURL)
        let firstClaim = try store.claim(
            payloadAt: firstPayloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: firstID,
                attemptIdentifier: firstAttempt,
                owner: .direct,
                sourceURL: sourceURL,
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "first.bin",
                actualBytes: 1_024,
                expectedBytes: 1_024
            )
        )
        let firstFinalize = Task.detached {
            try store.finalize(firstClaim)
        }
        for _ in 0 ..< 200 where hashEntered.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(hashEntered.value)

        let secondClaimTask = Task.detached {
            defer { secondClaimFinished.set() }
            return try store.claim(
                payloadAt: secondPayloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: secondID,
                    attemptIdentifier: secondAttempt,
                    owner: .direct,
                    sourceURL: sourceURL,
                    statusCode: 200,
                    mimeType: "application/octet-stream",
                    suggestedFilename: "second.bin",
                    actualBytes: 128,
                    expectedBytes: 128
                )
            )
        }
        for _ in 0 ..< 100 where secondClaimFinished.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondClaimCompletedBeforeRelease = secondClaimFinished.value
        releaseHash.signal()

        XCTAssertTrue(secondClaimCompletedBeforeRelease)
        _ = try await firstFinalize.value
        let secondClaim = try await secondClaimTask.value
        _ = try store.finalize(secondClaim)
        XCTAssertEqual(try store.entries().count, 2)
    }

    func testPlacementReconciliationHashDoesNotBlockUnrelatedClaim() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "HarborConcurrentPlacementReconciliation-\(UUID().uuidString)",
                isDirectory: true
            )
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let firstID = UUID()
        let firstAttempt = UUID()
        let secondID = UUID()
        let secondAttempt = UUID()
        let shouldBlockHash = LockedTestFlag()
        let hashEntered = LockedTestFlag()
        let releaseHash = DispatchSemaphore(value: 0)
        defer { releaseHash.signal() }
        let secondClaimFinished = LockedTestFlag()
        let store = CompletedDownloadHandoffStore(
            directoryURL: root.appendingPathComponent("Handoffs", isDirectory: true),
            payloadHashOperation: { url in
                if shouldBlockHash.value,
                   url.path.contains(firstAttempt.uuidString),
                   hashEntered.value == false {
                    hashEntered.set()
                    releaseHash.wait()
                }
                return SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let firstPayloadURL = root.appendingPathComponent("first.bin")
        let secondPayloadURL = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x41, count: 1_024).write(to: firstPayloadURL)
        try Data(repeating: 0x42, count: 128).write(to: secondPayloadURL)

        let firstClaim = try store.claim(
            payloadAt: firstPayloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: firstID,
                attemptIdentifier: firstAttempt,
                owner: .direct,
                sourceURL: sourceURL,
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "first.bin",
                actualBytes: 1_024,
                expectedBytes: 1_024
            )
        )
        let firstHandoff = try store.finalize(firstClaim)
        _ = try store.recordDestination(
            destinationRoot.appendingPathComponent("first.bin"),
            for: firstHandoff
        )

        shouldBlockHash.set()
        let reconciliationTask = Task.detached {
            try store.entries()
        }
        for _ in 0 ..< 200 where hashEntered.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(hashEntered.value)

        let secondClaimTask = Task.detached {
            defer { secondClaimFinished.set() }
            return try store.claim(
                payloadAt: secondPayloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: secondID,
                    attemptIdentifier: secondAttempt,
                    owner: .direct,
                    sourceURL: sourceURL,
                    statusCode: 200,
                    mimeType: "application/octet-stream",
                    suggestedFilename: "second.bin",
                    actualBytes: 128,
                    expectedBytes: 128
                )
            )
        }
        for _ in 0 ..< 100 where secondClaimFinished.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondClaimCompletedBeforeRelease = secondClaimFinished.value
        releaseHash.signal()

        XCTAssertTrue(secondClaimCompletedBeforeRelease)
        _ = try await reconciliationTask.value
        let secondClaim = try await secondClaimTask.value
        _ = try store.finalize(secondClaim)
        XCTAssertEqual(try store.entries().count, 2)
    }
}
