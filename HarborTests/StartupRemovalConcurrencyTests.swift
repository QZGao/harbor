import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
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

}
