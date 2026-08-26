import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testTerminalMediaRecordsDoNotRetainRecoveryDirectories() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/video"))
        func makeItem(backend: DownloadBackend = .ytDlp, status: DownloadStatus) -> DownloadItem {
            DownloadItem(
                sourceURL: sourceURL,
                sourceKind: backend == .ytDlp ? .mediaURL : .directURL,
                backend: backend,
                preferredFilename: nil,
                destinationFolderPath: "/tmp",
                status: status
            )
        }

        let failed = makeItem(status: .failed)
        let paused = makeItem(status: .paused)
        let queued = makeItem(status: .queued)
        let completed = makeItem(status: .completed)
        let cancelled = makeItem(status: .cancelled)
        let failedDirect = makeItem(backend: .urlSession, status: .failed)

        let retainedIDs = DownloadCenter.retainedMediaRecoveryIDs(
            in: [failed, paused, queued, completed, cancelled, failedDirect]
        )

        XCTAssertEqual(retainedIDs, Set([failed.id, paused.id, queued.id]))
        XCTAssertTrue(failed.status.isTerminal)
        XCTAssertTrue(retainedIDs.contains(failed.id))
        XCTAssertFalse(retainedIDs.contains(completed.id))
        XCTAssertFalse(retainedIDs.contains(cancelled.id))
        XCTAssertFalse(retainedIDs.contains(failedDirect.id))
    }

    func testCancellationKeepsDirectRecoveryWhenRecordSaveFails() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected cancellation save failure" }
        }

        let suiteName = "HarborTests.CancelSaveFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborCancelSaveFailureTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            progress: 0.7,
            bytesWritten: 7,
            expectedBytes: 10
        )
        let recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let handle = try recoveryStore.openFreshFile(id: item.id)
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: item.sourceURL,
                entityTag: "\"cancel-test\"",
                lastModified: nil,
                expectedBytes: 10,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: item.id
        )

        let saveEntered = AsyncTestGate()
        let releaseSave = AsyncTestGate()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            directRecoveryDirectoryURL: recoveryRoot,
            recordSaveOperation: { _, _, _ in
                await saveEntered.release()
                await releaseSave.wait()
                throw ExpectedSaveFailure()
            }
        )
        center.downloads = [item]

        center.cancelDownload(id: item.id)
        await saveEntered.wait()
        XCTAssertEqual(item.status, .cancelled)
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: item.id), 7)

        await releaseSave.release()
        for _ in 0 ..< 100 {
            if center.activeAlert?.message == "Expected cancellation save failure" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(item.bytesWritten, 7)
        XCTAssertEqual(item.expectedBytes, 10)
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: item.id), 7)

        await center.shutdownForTermination()
    }

    func testPendingDataRemovalFinishesAfterCrashBetweenTrashAndRecordSave() async throws {
        let suiteName = "HarborTests.PendingDataRemovalReplay.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPendingDataRemovalReplayTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let pendingRoot = testRoot.appendingPathComponent("PendingRemoval", isDirectory: true)
        let directRoot = testRoot.appendingPathComponent("DirectRecovery", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("BrowserRecovery", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("archive.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try Data("already-trashed".utf8).write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            status: .completed,
            progress: 1,
            bytesWritten: 15,
            expectedBytes: 15,
            finishedAt: .now
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let pendingStore = PendingDownloadDataRemovalStore(
            fileManager: fileManager,
            directoryURL: pendingRoot
        )
        try pendingStore.publish(record: item.makeRecord())

        // This is the crash boundary: the payload move completed, but the old
        // record was still the last durable download-list snapshot.
        try fileManager.removeItem(at: payloadURL)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: directRoot,
            completedHandoffDirectoryURL: handoffRoot,
            browserRecoveryDirectoryURL: browserRoot,
            pendingDataRemovalDirectoryURL: pendingRoot
        )
        await center.initializeIfNeeded()

        XCTAssertTrue(center.downloads.isEmpty)
        let replayedRecords = try await persistence.load()
        XCTAssertTrue(replayedRecords.isEmpty)
        XCTAssertTrue(try pendingStore.entries().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: payloadURL.path))
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testInterruptedDataRemovalDoesNotDeleteReplacementAtSamePath() async throws {
        let suiteName = "HarborTests.PendingDataRemovalReplacement.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPendingRemovalReplacement-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let pendingRoot = testRoot.appendingPathComponent("PendingRemoval", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("archive.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try Data("original-download".utf8).write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            status: .completed,
            progress: 1,
            bytesWritten: 17,
            expectedBytes: 17,
            finishedAt: .now
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let pendingStore = PendingDownloadDataRemovalStore(
            fileManager: fileManager,
            directoryURL: pendingRoot
        )
        try pendingStore.publish(record: item.makeRecord(), removingData: true)
        _ = try pendingStore.markPayloadDeletionStarted(downloadID: item.id)

        // Model the ambiguous crash boundary: Harbor may have moved the
        // original away, and another process then created a new file at the
        // same pathname before Harbor relaunched.
        try fileManager.removeItem(at: payloadURL)
        let replacement = Data("replacement-must-survive".utf8)
        try replacement.write(to: payloadURL)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: pendingRoot
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first { $0.id == item.id })
        XCTAssertEqual(restored.status, .completed)
        XCTAssertNotNil(restored.lastError)
        XCTAssertEqual(try Data(contentsOf: payloadURL), replacement)
        XCTAssertTrue(try pendingStore.entries().isEmpty)
        XCTAssertEqual(center.activeAlert?.title, "Download Data Was Left in Place")
        let persistedIDs = try await persistence.load().map(\.id)
        XCTAssertEqual(persistedIDs, [item.id])
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testDataRemovalJournalFailureLeavesPayloadAndRecordUntouched() async throws {
        let suiteName = "HarborTests.PendingDataRemovalPublishFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPendingDataRemovalFailureTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let blockedPendingRoot = testRoot.appendingPathComponent("not-a-directory")
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("archive.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try Data("must-remain-owned".utf8).write(to: payloadURL)
        try Data("occupied".utf8).write(to: blockedPendingRoot)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            status: .completed,
            progress: 1,
            bytesWritten: 17,
            expectedBytes: 17,
            finishedAt: .now
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: blockedPendingRoot
        )
        center.downloads = [item]

        center.removeDownloadsAndData(ids: [item.id])
        for _ in 0 ..< 200 {
            if center.activeAlert != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(center.downloads.map(\.id), [item.id])
        XCTAssertTrue(fileManager.fileExists(atPath: payloadURL.path))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("must-remain-owned".utf8))
        XCTAssertEqual(center.activeAlert?.title, "Couldn’t Prepare Download Data Removal")
        let retainedRecords = try await persistence.load()
        XCTAssertEqual(retainedRecords.map(\.id), [item.id])
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }


    func testTorrentPauseFailureRestoresStatusAndKeepsQueueSlot() async throws {
        struct ExpectedPauseFailure: LocalizedError {
            var errorDescription: String? { "Expected torrent pause failure" }
        }

        let suiteName = "HarborTests.TorrentPauseFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.maxConcurrentDownloads = 1
        let pauseGate = AsyncTestGate()
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborTorrentPauseFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            torrentPauseOperation: { _, _ in
                await pauseGate.wait()
                throw ExpectedPauseFailure()
            }
        )
        let torrentItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        torrentItem.backendIdentifier = "torrent-gid"
        let queuedItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/queued.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        center.downloads = [torrentItem, queuedItem]

        center.pauseDownloads(ids: [torrentItem.id])
        XCTAssertEqual(torrentItem.status, .paused)
        XCTAssertEqual(queuedItem.status, .queued)

        await pauseGate.release()
        for _ in 0 ..< 100 {
            if torrentItem.lastError == "Expected torrent pause failure" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(torrentItem.status, .downloading)
        XCTAssertEqual(queuedItem.status, .queued)

        await center.shutdownForTermination()
    }

    func testTorrentCancellationRetainsIdentifierUntilConfirmedCleanup() async throws {
        struct ExpectedCleanupFailure: LocalizedError {
            var errorDescription: String? { "Expected torrent cleanup failure" }
        }

        let suiteName = "HarborTests.TorrentCancelCleanup.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentCancelCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            torrentPauseOperation: { _, _ in },
            torrentRemoveOperation: { _, _ in throw ExpectedCleanupFailure() }
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        item.backendIdentifier = "torrent-gid"
        center.downloads = [item]

        center.cancelDownload(id: item.id)
        for _ in 0 ..< 100 {
            if item.status == .cancelled,
               item.lastError == "Expected torrent cleanup failure" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .cancelled)
        XCTAssertEqual(item.backendIdentifier, "torrent-gid")
        XCTAssertEqual(center.activeAlert?.message, "Expected torrent cleanup failure")
        let persistedRecords = try await persistence.load()
        let persistedItem = try XCTUnwrap(persistedRecords.first)
        XCTAssertEqual(persistedItem.status, .cancelled)
        XCTAssertEqual(persistedItem.backendIdentifier, "torrent-gid")

        await center.shutdownForTermination()
    }

    func testTorrentRetryDoesNotClearIdentifierBeforeConfirmedCleanup() async throws {
        struct ExpectedCleanupFailure: LocalizedError {
            var errorDescription: String? { "Expected retry cleanup failure" }
        }

        let suiteName = "HarborTests.TorrentRetryCleanup.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentRetryCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }
        let cleanupGate = AsyncTestGate()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            torrentRemoveOperation: { _, _ in
                await cleanupGate.wait()
                throw ExpectedCleanupFailure()
            }
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        item.backendIdentifier = "old-torrent-gid"
        center.downloads = [item]

        center.retryDownload(id: item.id)
        XCTAssertEqual(item.status, .preparing)
        XCTAssertEqual(item.backendIdentifier, "old-torrent-gid")

        await cleanupGate.release()
        for _ in 0 ..< 100 {
            if item.lastError == "Expected retry cleanup failure" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.backendIdentifier, "old-torrent-gid")
        XCTAssertEqual(center.activeAlert?.message, "Expected retry cleanup failure")

        await center.shutdownForTermination()
    }

    func testTorrentPauseDuringRetryCleanupSettlesPausedWithoutStartingReplacement() async throws {
        let suiteName = "HarborTests.TorrentRetryPause.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentRetryPause-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        let cleanupEntered = AsyncTestGate()
        let releaseCleanup = AsyncTestGate()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(
                directoryURL: testRoot.appendingPathComponent("Persistence")
            ),
            pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("PendingRemovals"),
            torrentRemoveOperation: { _, _ in
                await cleanupEntered.release()
                await releaseCleanup.wait()
            }
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        item.backendIdentifier = "old-torrent-gid"
        center.downloads = [item]

        center.retryDownload(id: item.id)
        await cleanupEntered.wait()
        XCTAssertEqual(item.status, .preparing)

        center.togglePauseResume(id: item.id)
        await releaseCleanup.release()
        for _ in 0 ..< 100 where item.status != .paused {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .paused)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.progress, 0)
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testCancelledDirectRetryDoesNotStartBeforeConfirmedCleanup() async throws {
        struct ExpectedCleanupFailure: LocalizedError {
            var errorDescription: String? { "Expected direct retry cleanup failure" }
        }

        let suiteName = "HarborTests.DirectRetryCleanup.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDirectRetryCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            urlSessionCleanupOperation: { _, _, _ in
                throw ExpectedCleanupFailure()
            }
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .cancelled
        )
        center.downloads = [item]

        center.retryDownload(id: item.id)
        for _ in 0 ..< 100 {
            if item.lastError == "Expected direct retry cleanup failure" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .cancelled)
        XCTAssertNil(item.taskIdentifier)
        XCTAssertEqual(item.lastError, "Expected direct retry cleanup failure")
        XCTAssertEqual(center.activeAlert?.title, "Couldn’t Restart Download")

        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testClearFailedRemovesDirectAndBrowserRecoveryState() async throws {
        let suiteName = "HarborTests.ClearFailedRecovery.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborClearFailedRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let failedDirect = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        let failedBrowser = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed,
            browserResumeData: Data("browser-resume".utf8)
        )
        let pausedDirect = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused
        )

        let recoveryStore = DirectDownloadRecoveryStore(fileManager: fileManager)
        func seedDirectRecovery(id: UUID) throws {
            let handle = try recoveryStore.openFreshFile(id: id)
            try handle.write(contentsOf: Data("partial".utf8))
            try handle.close()
            try recoveryStore.saveMetadata(
                DirectDownloadRecoveryMetadata(
                    sourceURL: sourceURL,
                    entityTag: "\"clear-failed-test\"",
                    lastModified: nil,
                    expectedBytes: 10,
                    suggestedFilename: "archive.bin",
                    mimeType: "application/octet-stream"
                ),
                id: id
            )
        }
        try seedDirectRecovery(id: failedDirect.id)
        try seedDirectRecovery(id: pausedDirect.id)

        let browserRecoveryRoot = persistenceRoot
            .appendingPathComponent("BrowserRecovery", isDirectory: true)
        let browserRecoveryURL = browserRecoveryRoot
            .appendingPathComponent(failedBrowser.id.uuidString)
            .appendingPathExtension("download")
        try fileManager.createDirectory(
            at: browserRecoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("browser-partial".utf8).write(to: browserRecoveryURL)
        defer {
            recoveryStore.discard(id: failedDirect.id)
            recoveryStore.discard(id: pausedDirect.id)
            try? fileManager.removeItem(at: browserRecoveryURL)
        }

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            browserRecoveryDirectoryURL: browserRecoveryRoot
        )
        center.downloads = [failedDirect, failedBrowser, pausedDirect]

        await center.clearFailed()

        XCTAssertEqual(center.downloads.map(\.id), [pausedDirect.id])
        XCTAssertNil(recoveryStore.recoveredByteCount(id: failedDirect.id))
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: pausedDirect.id), 7)
        XCTAssertFalse(fileManager.fileExists(atPath: browserRecoveryURL.path))

        await center.shutdownForTermination()
        let persistedRecords = try await persistence.load()
        XCTAssertEqual(persistedRecords.map(\.id), [pausedDirect.id])
    }

    func testClearFailedPreservesRecoveryWhenPersistenceFails() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected persistence failure" }
        }

        let suiteName = "HarborTests.ClearFailedSaveFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborClearFailedSaveFailureTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let pendingRemovalRoot = testRoot.appendingPathComponent("PendingRemovals", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let failedItem = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        let recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let handle = try recoveryStore.openFreshFile(id: failedItem.id)
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"clear-failed-failure-test\"",
                lastModified: nil,
                expectedBytes: 10,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: failedItem.id
        )

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            directRecoveryDirectoryURL: recoveryRoot,
            pendingDataRemovalDirectoryURL: pendingRemovalRoot,
            recordSaveOperation: { _, _, _ in
                throw ExpectedSaveFailure()
            }
        )
        center.downloads = [failedItem]
        center.selectedDownloadID = failedItem.id

        await center.clearFailed()

        XCTAssertEqual(center.downloads.map(\.id), [failedItem.id])
        XCTAssertEqual(center.selectedDownloadID, failedItem.id)
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: failedItem.id), 7)
        XCTAssertEqual(center.activeAlert?.message, "Expected persistence failure")

        await center.shutdownForTermination()
    }

    func testClearFailedCannotBeUndoneByCancelledDebouncedSave() async throws {
        let suiteName = "HarborTests.ClearFailedDebounce.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborClearFailedDebounceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let failedItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence
        )
        center.downloads = [failedItem]

        center.setDownloadLimitOverride(.unlimited, for: failedItem.id)
        await center.clearFailed()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(center.downloads.isEmpty)
        let persistedRecords = try await persistence.load()
        XCTAssertTrue(persistedRecords.isEmpty)

        await center.shutdownForTermination()
    }


    func testShutdownRefusesTerminationWhenTorrentRecoveryCannotBeSaved() async throws {
        struct ExpectedTorrentShutdownFailure: LocalizedError {
            var errorDescription: String? { "Expected torrent session save failure" }
        }

        let suiteName = "HarborTests.TorrentShutdownFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborTorrentShutdownFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            torrentShutdownOperation: { _ in
                throw ExpectedTorrentShutdownFailure()
            }
        )
        center.downloads = [
            DownloadItem(
                sourceURL: try XCTUnwrap(
                    URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
                ),
                sourceKind: .magnetLink,
                backend: .aria2,
                preferredFilename: nil,
                destinationFolderPath: "/tmp",
                status: .paused
            )
        ]

        let didShutDown = await center.shutdownForTermination()

        XCTAssertFalse(didShutDown)
        XCTAssertEqual(
            center.activeAlert?.title,
            "Couldn’t Save Torrent Recovery Before Quitting"
        )
        XCTAssertEqual(
            center.activeAlert?.message,
            "Expected torrent session save failure"
        )
    }
}
