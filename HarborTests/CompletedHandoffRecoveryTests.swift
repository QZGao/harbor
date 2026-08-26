import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testRetryPreservesCompletedStagingWhenPromotionIsTemporarilyUnavailable() async throws {
        let suiteName = "HarborTests.StagingPromotionUnavailable.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborStagingPromotionUnavailableTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let directRecoveryRoot = testRoot.appendingPathComponent("DirectRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = testRoot.appendingPathComponent("payload.bin")
        var restoredPermissions = false
        defer {
            if restoredPermissions == false {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: handoffRoot.path
                )
            }
            try? fileManager.removeItem(at: testRoot)
        }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let payload = Data("durable-payload".utf8)
        try payload.write(to: payloadURL)

        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/durable.bin"))
        let downloadID = UUID()
        let store = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let readyHandoff = try store.publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: downloadID,
                attemptIdentifier: UUID(),
                owner: .direct,
                sourceURL: sourceURL,
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "durable.bin",
                actualBytes: Int64(payload.count),
                expectedBytes: Int64(payload.count)
            )
        )
        let stagingURL = readyHandoff.packageURL
            .deletingPathExtension()
            .appendingPathExtension("staging")
        try fileManager.moveItem(at: readyHandoff.packageURL, to: stagingURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: handoffRoot.path
        )

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            directRecoveryDirectoryURL: directRecoveryRoot,
            completedHandoffDirectoryURL: handoffRoot
        )
        let item = DownloadItem(
            id: downloadID,
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .failed
        )
        center.downloads = [item]

        center.retryDownload(id: downloadID)
        for _ in 0 ..< 200 where item.status != .failed || item.lastError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .failed)
        XCTAssertNotNil(item.lastError)
        XCTAssertTrue(fileManager.fileExists(atPath: stagingURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: destinationRoot.path))

        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: handoffRoot.path
        )
        restoredPermissions = true
        let recoveredEntries = try store.entries()
        guard case let .valid(recoveredHandoff) = try XCTUnwrap(recoveredEntries.first) else {
            return XCTFail("Expected the retained staging package to recover")
        }
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(recoveredHandoff.payloadURL)),
            payload
        )

        await center.shutdownForTermination()
    }

    func testBrowserCompletionMarkerRetainsPayloadAcrossHandoffStoreFailure() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserCompletionMarkerTests-\(UUID().uuidString)", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("Browser", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        var restoredPermissions = false
        defer {
            if restoredPermissions == false {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: handoffRoot.path
                )
            }
            try? fileManager.removeItem(at: testRoot)
        }
        try fileManager.createDirectory(at: browserRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: handoffRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/browser.bin"))
        let payload = Data("browser-complete".utf8)
        let basename = "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
        let payloadURL = browserRoot
            .appendingPathComponent(basename)
            .appendingPathExtension("part")
        let markerURL = browserRoot
            .appendingPathComponent(basename)
            .appendingPathExtension("completion")
        let manifest = CompletedDownloadHandoffManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            owner: .browser,
            sourceURL: sourceURL,
            statusCode: 200,
            mimeType: "application/octet-stream",
            suggestedFilename: "browser.bin",
            actualBytes: Int64(payload.count),
            expectedBytes: Int64(payload.count),
            phase: .claiming
        )
        try payload.write(to: payloadURL)
        try JSONEncoder().encode(
            BrowserCompletedTemporaryManifest(handoff: manifest)
        ).write(to: markerURL, options: .atomic)

        let store = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let coordinator = BrowserDownloadCoordinator(
            fileManager: fileManager,
            temporaryDirectory: browserRoot,
            completedHandoffStore: store,
            onEvent: { _ in }
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: handoffRoot.path
        )

        let firstFailures = try await coordinator.recoverCompletedTemporaryFiles(
            downloadID: downloadID
        )
        XCTAssertNotNil(firstFailures[downloadID])
        XCTAssertTrue(fileManager.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: markerURL.path))

        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: handoffRoot.path
        )
        restoredPermissions = true
        let secondFailures = try await coordinator.recoverCompletedTemporaryFiles(
            downloadID: downloadID
        )
        XCTAssertTrue(secondFailures.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: payloadURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
        let entries = try store.entries()
        guard case let .valid(handoff) = try XCTUnwrap(entries.first) else {
            return XCTFail("Expected the browser payload to become a durable handoff")
        }
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(handoff.payloadURL)),
            payload
        )
    }

    func testMalformedBrowserCompletionMarkerIsDiscardedWithoutBlockingRetry() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMalformedBrowserMarkerTests-\(UUID().uuidString)", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("Browser", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: browserRoot, withIntermediateDirectories: true)

        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let basename = "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
        let payloadURL = browserRoot
            .appendingPathComponent(basename)
            .appendingPathExtension("part")
        let markerURL = browserRoot
            .appendingPathComponent(basename)
            .appendingPathExtension("completion")
        try Data("untrusted".utf8).write(to: payloadURL)
        try Data("not-json".utf8).write(to: markerURL)

        let coordinator = BrowserDownloadCoordinator(
            fileManager: fileManager,
            temporaryDirectory: browserRoot,
            completedHandoffStore: CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: handoffRoot
            ),
            onEvent: { _ in }
        )
        let failures = try await coordinator.recoverCompletedTemporaryFiles(
            downloadID: downloadID
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: payloadURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
    }

    func testCompletedDestinationUnavailabilityIsNotClassifiedAsCorruption() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnavailableDestinationTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let sourceURL = testRoot.appendingPathComponent("payload.bin")
        let destinationURL = destinationRoot.appendingPathComponent("payload.bin")
        let detachedURL = testRoot.appendingPathComponent("detached-payload.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let payload = Data("durable-destination".utf8)
        try payload.write(to: sourceURL)

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let handoff = try store.publish(
            payloadAt: sourceURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier,
                owner: .direct,
                sourceURL: try XCTUnwrap(URL(string: "https://example.test/payload.bin")),
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "payload.bin",
                actualBytes: Int64(payload.count),
                expectedBytes: Int64(payload.count)
            )
        )
        let recorded = try store.recordDestination(destinationURL, for: handoff)
        let stagingURL = try XCTUnwrap(recorded.placementStagingURL)
        let resolver = DownloadDestinationResolver(fileManager: fileManager)
        try resolver.copyDownloadedFile(
            from: try XCTUnwrap(recorded.payloadURL),
            to: stagingURL
        )
        try resolver.moveDownloadedFile(from: stagingURL, to: destinationURL)
        let placed = try XCTUnwrap(
            store.handoff(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier
            )
        )
        try store.releasePayloadAfterPlacement(for: placed)
        try fileManager.moveItem(at: destinationURL, to: detachedURL)

        let unavailableEntries = try store.entries()
        XCTAssertEqual(unavailableEntries.count, 1)
        guard case .unavailable = try XCTUnwrap(unavailableEntries.first) else {
            return XCTFail("Expected a missing journaled destination to remain retryable")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: handoff.packageURL.path))

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: detachedURL, to: destinationURL)
        guard case let .valid(recovered) = try XCTUnwrap(try store.entries().first) else {
            return XCTFail("Expected the restored destination to validate")
        }
        XCTAssertEqual(recovered.destinationURL, destinationURL)
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
    }

    func testReadyHandoffWithoutPayloadIsClassifiedAsCorrupt() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMissingReadyPayloadTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let sourceURL = testRoot.appendingPathComponent("payload.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("completed-but-lost".utf8).write(to: sourceURL)

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        let handoff = try store.publish(
            payloadAt: sourceURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: UUID(),
                attemptIdentifier: UUID(),
                owner: .direct,
                sourceURL: try XCTUnwrap(URL(string: "https://example.test/payload.bin")),
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "payload.bin",
                actualBytes: 18,
                expectedBytes: 18
            )
        )
        try fileManager.removeItem(at: try XCTUnwrap(handoff.payloadURL))

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        guard case .invalid = try XCTUnwrap(entries.first) else {
            return XCTFail("Expected a ready handoff with no payload to be irrecoverable")
        }
    }

    func testClaimingHandoffWithoutPayloadIsDiscardedInsteadOfBlockingRetry() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborEmptyClaimingHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let packageURL = handoffRoot
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)",
                isDirectory: true
            )
            .appendingPathExtension("staging")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let manifest = CompletedDownloadHandoffManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            owner: .direct,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/payload.bin")),
            statusCode: 200,
            mimeType: "application/octet-stream",
            suggestedFilename: "payload.bin",
            actualBytes: 12,
            expectedBytes: 12,
            phase: .claiming
        )
        try JSONEncoder().encode(manifest).write(
            to: packageURL.appendingPathComponent("manifest.json")
        )

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.path))
        XCTAssertFalse(store.ownsAttempt(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier
        ))
    }

    func testCompletedHandoffScanDoesNotTreatOperationalFailureAsEmpty() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborHandoffScanFailureTests-\(UUID().uuidString)", isDirectory: true)
        let invalidDirectoryURL = testRoot.appendingPathComponent("not-a-directory")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: invalidDirectoryURL)

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: invalidDirectoryURL
        )
        XCTAssertThrowsError(try store.entries())
    }


    func testMissingHandoffManifestFailsWithoutPublishingPayload() async throws {
        let suiteName = "HarborTests.InvalidCompletedHandoff.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInvalidCompletedHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .paused
        )
        try await persistence.save([item.makeRecord()])

        let invalidPackageURL = handoffRoot
            .appendingPathComponent("\(item.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("handoff")
        try fileManager.createDirectory(at: invalidPackageURL, withIntermediateDirectories: true)
        try Data("untrusted".utf8).write(
            to: invalidPackageURL.appendingPathComponent("payload")
        )

        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot
        )
        await center.initializeIfNeeded()

        let restoredItem = try XCTUnwrap(center.downloads.first)
        XCTAssertEqual(restoredItem.status, .failed)
        XCTAssertEqual(restoredItem.bytesWritten, 0)
        XCTAssertNil(restoredItem.fileLocationPath)
        XCTAssertFalse(fileManager.fileExists(atPath: invalidPackageURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: destinationRoot.path))

        await center.shutdownForTermination()
    }

    func testInvalidHandoffClassificationSaveFailureCannotRestartQueuedDownload() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected handoff classification save failure" }
        }

        let suiteName = "HarborTests.InvalidHandoffSaveFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInvalidHandoffSaveFailure-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/queued.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: testRoot.path,
            status: .queued
        )
        try await persistence.save([item.makeRecord()])

        let invalidPackageURL = handoffRoot
            .appendingPathComponent("\(item.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("handoff")
        try fileManager.createDirectory(at: invalidPackageURL, withIntermediateDirectories: true)
        try Data("untrusted".utf8).write(
            to: invalidPackageURL.appendingPathComponent("payload")
        )

        let saveCounter = AsyncTestCounter()
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot,
            recordSaveOperation: { persistence, records, revision in
                let call = await saveCounter.incrementAndGet()
                if call == 1 {
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )
        await center.initializeIfNeeded()

        let restoredItem = try XCTUnwrap(center.downloads.first)
        XCTAssertEqual(restoredItem.status, .failed)
        XCTAssertEqual(restoredItem.lastError, "Expected handoff classification save failure")
        XCTAssertNil(restoredItem.taskIdentifier)
        XCTAssertNil(restoredItem.backendIdentifier)
        XCTAssertTrue(fileManager.fileExists(atPath: invalidPackageURL.path))
        let persistedRecords = try await persistence.load()
        let persistedRecord = try XCTUnwrap(persistedRecords.first)
        XCTAssertEqual(persistedRecord.status, .failed)
        XCTAssertEqual(persistedRecord.lastError, "Expected handoff classification save failure")

        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testTerminalItemsIgnoreLateDirectAndBrowserEvents() async throws {
        let suiteName = "HarborTests.TerminalLateEvents.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTerminalLateEventTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/cancelled.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .cancelled
        )
        center.downloads = [item]
        let directAttemptIdentifier = UUID()
        let browserAttemptIdentifier = UUID()

        center.handle(
            .started(
                id: item.id,
                attemptIdentifier: directAttemptIdentifier,
                taskIdentifier: 99,
                usesOwnedPartial: true,
                ownedRecovery: nil,
                resetReason: nil
            )
        )
        center.handle(
            .progress(
                id: item.id,
                attemptIdentifier: directAttemptIdentifier,
                bytesWritten: 5,
                expectedBytes: 10,
                speedBytesPerSecond: 1
            )
        )
        center.handle(
            .recoveryReset(
                id: item.id,
                attemptIdentifier: directAttemptIdentifier,
                reason: .serverRejectedRange
            )
        )
        center.handle(
            .failed(
                id: item.id,
                attemptIdentifier: directAttemptIdentifier,
                failure: DirectDownloadFailure(
                    error: URLError(.networkConnectionLost),
                    resumeData: nil
                )
            )
        )
        center.handleBrowserDownloadEvent(
            .started(
                id: item.id,
                attemptIdentifier: browserAttemptIdentifier,
                suggestedFilename: "late.bin",
                expectedBytes: 10,
                responseMimeType: "application/octet-stream",
                statusCode: 200,
                isResumed: false
            )
        )
        center.handleBrowserDownloadEvent(
            .failed(
                id: item.id,
                attemptIdentifier: browserAttemptIdentifier,
                failure: DirectDownloadFailure(
                    error: URLError(.cannotConnectToHost),
                    resumeData: nil
                )
            )
        )

        XCTAssertEqual(item.status, .cancelled)
        XCTAssertNil(item.taskIdentifier)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)
        XCTAssertEqual(item.progress, 0)
        XCTAssertNil(item.lastError)

        await center.shutdownForTermination()
    }
}
