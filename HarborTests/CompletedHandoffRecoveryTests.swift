import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
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
