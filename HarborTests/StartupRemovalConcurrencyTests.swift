import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testMalformedPendingRemovalJournalDoesNotBlockDownloadRestoration() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMalformedPendingRemoval-\(UUID().uuidString)")
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let pendingRoot = testRoot.appendingPathComponent("Pending", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: pendingRoot, withIntermediateDirectories: true)

        let suiteName = "HarborTests.MalformedPendingRemoval.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: testRoot.path,
            status: .paused
        )
        let quarantinedItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/quarantined.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "quarantined.bin",
            destinationFolderPath: testRoot.path,
            status: .queued
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord(), quarantinedItem.makeRecord()])
        let malformedID = quarantinedItem.id
        let malformedURL = pendingRoot
            .appendingPathComponent(malformedID.uuidString)
            .appendingPathExtension("json")
        try Data("{not-valid-json".utf8).write(to: malformedURL)
        let completedPayloadURL = testRoot.appendingPathComponent("quarantined-completion.bin")
        try Data("completion-must-remain-quarantined".utf8).write(to: completedPayloadURL)
        let retainedHandoff = try makeCompletedHandoff(
            payloadURL: completedPayloadURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: quarantinedItem.id,
            attemptIdentifier: UUID(),
            sourceURL: quarantinedItem.sourceURL,
            suggestedFilename: "quarantined.bin"
        )

        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: handoffRoot,
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: pendingRoot,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: testRoot.appendingPathComponent("MediaRecovery")
            )
        )
        await center.initializeIfNeeded()

        XCTAssertEqual(
            Set(center.downloads.map(\.id)),
            Set([item.id, quarantinedItem.id])
        )
        XCTAssertEqual(center.downloads.first { $0.id == item.id }?.status, .paused)
        let quarantined = try XCTUnwrap(
            center.downloads.first { $0.id == quarantinedItem.id }
        )
        XCTAssertEqual(quarantined.status, .failed)
        XCTAssertTrue(quarantined.lastError?.contains("cleanup journal") == true)
        XCTAssertFalse(center.canRetryInitialization)
        XCTAssertNil(center.initializationFailureMessage)
        XCTAssertTrue(fileManager.fileExists(atPath: malformedURL.path))
        let recoveryEntries = try PendingDownloadDataRemovalStore(
            directoryURL: pendingRoot
        ).recoveryEntries()
        guard case let .invalid(downloadID, _) = try XCTUnwrap(recoveryEntries.first) else {
            return XCTFail("Expected malformed cleanup journal classification")
        }
        XCTAssertEqual(downloadID, malformedID)
        XCTAssertEqual(center.activeAlert?.title, "Download Cleanup Needs Attention")
        center.retryDownload(id: quarantinedItem.id)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(quarantined.status, .failed)
        XCTAssertNil(quarantined.fileLocationPath)
        XCTAssertTrue(fileManager.fileExists(atPath: retainedHandoff.packageURL.path))
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testPendingRemovalStoreRejectsSymlinkedRootWithoutConsumingExternalJournal() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborSymlinkedPendingRemoval-\(UUID().uuidString)")
        let pendingRoot = testRoot.appendingPathComponent("Pending", isDirectory: true)
        let externalRoot = testRoot.appendingPathComponent("External", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: testRoot.path,
            status: .failed
        )
        let journalURL = externalRoot
            .appendingPathComponent(item.id.uuidString)
            .appendingPathExtension("json")
        try JSONEncoder().encode(
            PendingDownloadDataRemovalManifest(record: item.makeRecord())
        ).write(to: journalURL)
        try fileManager.createSymbolicLink(
            at: pendingRoot,
            withDestinationURL: externalRoot
        )

        let store = PendingDownloadDataRemovalStore(directoryURL: pendingRoot)
        XCTAssertThrowsError(try store.recoveryEntries())
        XCTAssertThrowsError(try store.acknowledgeOrThrow(downloadID: item.id))
        XCTAssertTrue(fileManager.fileExists(atPath: journalURL.path))
    }

    func testDownloadMutationsWaitForAuthoritativeInitialization() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInitializationMutationGate-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: testRoot) }

        let suiteName = "HarborTests.InitializationMutationGate.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(
                directoryURL: testRoot.appendingPathComponent("Persistence", isDirectory: true)
            ),
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("Pending"),
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: testRoot.appendingPathComponent("MediaRecovery")
            ),
            torrentShutdownOperation: { _ in }
        )

        XCTAssertFalse(center.canAddDownloads)
        center.presentAddSheet()
        XCTAssertNil(center.addSheetDraft)

        let directURL = try XCTUnwrap(URL(string: "https://example.test/new.bin"))
        center.queueDownload(
            AddDownloadRequest(
                sourceKind: .directURL,
                sourceURL: directURL,
                customFilename: nil,
                destinationFolder: testRoot,
                shouldStartImmediately: true
            )
        )
        XCTAssertTrue(center.downloads.isEmpty)

        let externalURL = try XCTUnwrap(URL(string: "https://example.test/external.bin"))
        center.receiveExternalAddSources([externalURL])
        XCTAssertNil(center.addSheetDraft)

        await center.initializeIfNeeded()

        XCTAssertTrue(center.canAddDownloads)
        XCTAssertEqual(center.addSheetDraft?.sourceURLText, externalURL.absoluteString)
        XCTAssertTrue(center.downloads.isEmpty)
        center.handleAddSheetDismissal()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        center.queueDownload(
            AddDownloadRequest(
                sourceKind: .directURL,
                sourceURL: directURL,
                customFilename: nil,
                destinationFolder: testRoot,
                shouldStartImmediately: false
            )
        )
        XCTAssertEqual(center.downloads.map(\.sourceURL), [directURL])
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
        XCTAssertFalse(center.canAddDownloads)
    }

    func testInitializationCanRetryAfterPersistenceIsRepaired() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInitializationRetry-\(UUID().uuidString)")
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: persistenceRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: persistenceRoot.appendingPathComponent("downloads.json")
        )

        let suiteName = "HarborTests.InitializationRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        func makeCenter() -> DownloadCenter {
            DownloadCenter(
                settings: settings,
                persistence: persistence,
                directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
                completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
                browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
                pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("Pending"),
                mediaService: MediaDownloadService(
                    eventHandler: { _, _ in },
                    fileManager: fileManager,
                    temporaryRoot: testRoot.appendingPathComponent("MediaRecovery")
                ),
                torrentShutdownOperation: { _ in }
            )
        }
        let failedCenter = makeCenter()

        await failedCenter.initializeIfNeeded()
        XCTAssertTrue(failedCenter.canRetryInitialization)
        XCTAssertNotNil(failedCenter.initializationFailureMessage)
        XCTAssertTrue(failedCenter.downloads.isEmpty)
        let queuedExternalURL = try XCTUnwrap(
            URL(string: "https://example.test/queued-during-retry.bin")
        )
        failedCenter.receiveExternalAddSources([queuedExternalURL])
        XCTAssertNil(failedCenter.addSheetDraft)
        let corruptRecords = try Data(
            contentsOf: persistenceRoot.appendingPathComponent("downloads.json")
        )
        XCTAssertEqual(
            try Data(contentsOf: persistenceRoot.appendingPathComponent("downloads.json")),
            corruptRecords
        )

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/repaired.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "repaired.bin",
            destinationFolderPath: testRoot.path,
            status: .paused
        )
        try await persistence.save([item.makeRecord()])
        await failedCenter.initializeIfNeeded()

        XCTAssertFalse(failedCenter.canRetryInitialization)
        XCTAssertNil(failedCenter.initializationFailureMessage)
        XCTAssertEqual(failedCenter.downloads.map(\.id), [item.id])
        XCTAssertEqual(
            failedCenter.addSheetDraft?.sourceURLText,
            queuedExternalURL.absoluteString
        )
        let shutdownSucceeded = await failedCenter.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testBackendCleanupJournalCannotAuthorizeDeletingReplacementPayload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBackendCleanupReplacement-\(UUID().uuidString)", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let persistenceRoot = root.appendingPathComponent("persistence", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("archive.bin")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let replacement = Data("replacement-owned-by-someone-else".utf8)
        try replacement.write(to: payloadURL)

        let suiteName = "HarborTests.BackendCleanupReplacement.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.bin",
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            status: .completed,
            progress: 1,
            bytesWritten: Int64(replacement.count),
            expectedBytes: Int64(replacement.count),
            finishedAt: .now
        )
        let pendingStore = PendingDownloadDataRemovalStore(directoryURL: pendingRoot)
        try pendingStore.publish(record: item.makeRecord(), removingData: true)
        _ = try pendingStore.markPayloadDeletionStarted(downloadID: item.id)
        _ = try pendingStore.markBackendCleanup(downloadID: item.id)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            pendingDataRemovalDirectoryURL: pendingRoot
        )
        center.downloads = [item]
        center.removeDownloadsAndData(ids: [item.id])
        for _ in 0 ..< 100 where center.downloads.isEmpty == false {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(center.downloads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: payloadURL), replacement)
        XCTAssertTrue(try pendingStore.entries().isEmpty)
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testRecordRemovalRollbackCancelsJournalBeforeRelaunch() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected first removal save failure" }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborRemovalRollbackRelaunch-\(UUID().uuidString)", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let persistenceRoot = root.appendingPathComponent("persistence", isDirectory: true)
        let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let suiteName = "HarborTests.RemovalRollbackRelaunch.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed,
            progress: 0.7,
            bytesWritten: 7,
            expectedBytes: 10
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let recoveryStore = DirectDownloadRecoveryStore(directoryURL: recoveryRoot)
        let handle = try recoveryStore.openFreshFile(id: item.id)
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: item.sourceURL,
                entityTag: "\"rollback\"",
                lastModified: nil,
                expectedBytes: 10,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: item.id
        )
        let saveCounter = AsyncTestCounter()
        let firstCenter = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            directRecoveryDirectoryURL: recoveryRoot,
            pendingDataRemovalDirectoryURL: pendingRoot,
            recordSaveOperation: { persistence, records, revision in
                if await saveCounter.incrementAndGet() == 1 {
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )
        firstCenter.downloads = [item]
        await firstCenter.clearFailed()

        XCTAssertEqual(firstCenter.downloads.map(\.id), [item.id])
        XCTAssertTrue(try PendingDownloadDataRemovalStore(directoryURL: pendingRoot).entries().isEmpty)
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: item.id), 7)

        let secondCenter = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            directRecoveryDirectoryURL: recoveryRoot,
            pendingDataRemovalDirectoryURL: pendingRoot
        )
        await secondCenter.initializeIfNeeded()
        XCTAssertEqual(secondCenter.downloads.map(\.id), [item.id])
        XCTAssertEqual(recoveryStore.recoveredByteCount(id: item.id), 7)

        let firstShutdownSucceeded = await firstCenter.shutdownForTermination()
        let secondShutdownSucceeded = await secondCenter.shutdownForTermination()
        XCTAssertTrue(firstShutdownSucceeded)
        XCTAssertTrue(secondShutdownSucceeded)
    }

    func testInterruptedMultiPayloadRemovalRetiresOnlyMissingPaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPartialMultiPayloadRemoval-\(UUID().uuidString)", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let persistenceRoot = root.appendingPathComponent("persistence", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        let removedURL = destinationRoot.appendingPathComponent("removed.bin")
        let remainingURL = destinationRoot.appendingPathComponent("remaining.bin")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try Data("remaining".utf8).write(to: remainingURL)

        let suiteName = "HarborTests.PartialMultiPayloadRemoval.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: removedURL.path,
            status: .completed,
            progress: 1,
            bytesWritten: 16,
            expectedBytes: 16,
            finishedAt: .now,
            torrentPayloadPaths: [removedURL.path, remainingURL.path]
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let pendingStore = PendingDownloadDataRemovalStore(directoryURL: pendingRoot)
        try pendingStore.publish(record: item.makeRecord(), removingData: true)
        _ = try pendingStore.markPayloadDeletionStarted(downloadID: item.id)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            pendingDataRemovalDirectoryURL: pendingRoot
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first)
        XCTAssertEqual(restored.torrentPayloadPaths, [remainingURL.path])
        XCTAssertEqual(restored.fileLocationPath, remainingURL.path)
        XCTAssertFalse(restored.torrentPayloadPaths.contains(removedURL.path))
        let persistedRecords = try await persistence.load()
        XCTAssertEqual(persistedRecords.first?.torrentPayloadPaths, [remainingURL.path])
        XCTAssertTrue(try pendingStore.entries().isEmpty)
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testConcurrentCancellationsCannotPersistAnotherMutationBeforeRollback() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected first cancellation save failure" }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborSerializedCancellations-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let suiteName = "HarborTests.SerializedCancellations.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let firstItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/first.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            progress: 0.4,
            bytesWritten: 4,
            expectedBytes: 10
        )
        let secondItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/second.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            progress: 0.6,
            bytesWritten: 6,
            expectedBytes: 10
        )
        let persistence = DownloadPersistence(directoryURL: root.appendingPathComponent("persistence"))
        try await persistence.save([firstItem.makeRecord(), secondItem.makeRecord()])
        let saveCounter = AsyncTestCounter()
        let firstSaveEntered = AsyncTestGate()
        let releaseFirstSave = AsyncTestGate()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            recordSaveOperation: { persistence, records, revision in
                let call = await saveCounter.incrementAndGet()
                if call == 1 {
                    await firstSaveEntered.release()
                    await releaseFirstSave.wait()
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )
        center.downloads = [firstItem, secondItem]

        center.cancelDownload(id: firstItem.id)
        await firstSaveEntered.wait()
        center.cancelDownload(id: secondItem.id)
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(firstItem.status, .cancelled)
        XCTAssertEqual(secondItem.status, .paused)

        await releaseFirstSave.release()
        var persistedStatuses: [UUID: DownloadStatus] = [:]
        for _ in 0 ..< 200 {
            let records = try await persistence.load()
            persistedStatuses = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status) })
            if firstItem.status == .paused,
               secondItem.status == .cancelled,
               persistedStatuses[firstItem.id] == .paused,
               persistedStatuses[secondItem.id] == .cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(firstItem.status, .paused)
        XCTAssertEqual(secondItem.status, .cancelled)
        XCTAssertEqual(persistedStatuses[firstItem.id], .paused)
        XCTAssertEqual(persistedStatuses[secondItem.id], .cancelled)
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testFailedStopSeedingSaveRollsBackBeforeConcurrentCancellationPersists() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected stop-seeding save failure" }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborSerializedStopSeeding-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let suiteName = "HarborTests.SerializedStopSeeding.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let seeder = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .seeding,
            finishedAt: .now,
            backendIdentifier: "active-seeder-gid",
            shouldSeedAfterDownload: true
        )
        let directItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused
        )
        let persistence = DownloadPersistence(
            directoryURL: root.appendingPathComponent("persistence")
        )
        try await persistence.save([seeder.makeRecord(), directItem.makeRecord()])
        let saveCounter = AsyncTestCounter()
        let firstSaveEntered = AsyncTestGate()
        let releaseFirstSave = AsyncTestGate()
        let removeCounter = AsyncTestCounter()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            torrentRemoveOperation: { _, _ in
                _ = await removeCounter.incrementAndGet()
            },
            torrentShutdownOperation: { _ in },
            recordSaveOperation: { persistence, records, revision in
                let call = await saveCounter.incrementAndGet()
                if call == 1 {
                    await firstSaveEntered.release()
                    await releaseFirstSave.wait()
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )
        center.downloads = [seeder, directItem]

        center.stopSeeding(id: seeder.id)
        await firstSaveEntered.wait()
        center.cancelDownload(id: directItem.id)
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(seeder.status, .completed)
        XCTAssertEqual(directItem.status, .paused)

        await releaseFirstSave.release()
        var recordsByID: [UUID: DownloadRecord] = [:]
        for _ in 0 ..< 200 {
            let records = try await persistence.load()
            recordsByID = Dictionary(
                uniqueKeysWithValues: records.map { ($0.id, $0) }
            )
            if seeder.status == .seeding,
               directItem.status == .cancelled,
               recordsByID[seeder.id]?.status == .seeding,
               recordsByID[directItem.id]?.status == .cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(seeder.status, .seeding)
        XCTAssertTrue(seeder.shouldSeedAfterDownload)
        XCTAssertEqual(seeder.backendIdentifier, "active-seeder-gid")
        XCTAssertEqual(directItem.status, .cancelled)
        XCTAssertEqual(recordsByID[seeder.id]?.status, .seeding)
        XCTAssertTrue(try XCTUnwrap(recordsByID[seeder.id]).shouldSeedAfterDownload)
        XCTAssertEqual(recordsByID[seeder.id]?.backendIdentifier, "active-seeder-gid")
        XCTAssertEqual(recordsByID[directItem.id]?.status, .cancelled)
        let removalCalls = await removeCounter.currentValue()
        XCTAssertEqual(removalCalls, 0)
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }
}
