import Foundation
import WebKit
import XCTest
@testable import Harbor

@MainActor
final class HarborModelAndSafetyTests: XCTestCase {
    func testTransferLimitOverrideResolution() {
        XCTAssertEqual(
            TransferLimitOverride.inherit.resolvedBytesPerSecond(inheriting: 4_096),
            4_096
        )
        XCTAssertNil(
            TransferLimitOverride.unlimited.resolvedBytesPerSecond(inheriting: 4_096)
        )
        XCTAssertEqual(
            TransferLimitOverride.limited(kilobytesPerSecond: 500)
                .resolvedBytesPerSecond(inheriting: nil),
            512_000
        )
        XCTAssertEqual(
            TransferLimitOverride.limited(kilobytesPerSecond: 0)
                .resolvedBytesPerSecond(inheriting: nil),
            1_024
        )
    }

    func testDirectDownloadLimitPrecedenceKeepsGlobalCapForUnlimitedItem() {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: 900_000,
            perDownloadSpeedLimitBytesPerSecond: 500_000,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 4
        )

        XCTAssertEqual(
            DownloadCoordinator.effectiveSpeedLimit(
                activeTransferCount: 3,
                transferSettings: settings,
                speedLimitOverride: .unlimited
            ),
            300_000
        )
        XCTAssertEqual(
            DownloadCoordinator.effectiveSpeedLimit(
                activeTransferCount: 1,
                transferSettings: settings,
                speedLimitOverride: .limited(kilobytesPerSecond: 200)
            ),
            200 * 1_024
        )
    }

    func testStaleBrowserResumeCallbackCannotAttachToReplacementSession() throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let firstID = UUID()
        let secondID = UUID()

        let firstSession = coordinator.startSession(
            downloadID: firstID,
            sourceURL: sourceURL,
            displayName: "First",
            resumeData: Data("first".utf8)
        )
        coordinator.cancelSession()
        let secondSession = coordinator.startSession(
            downloadID: secondID,
            sourceURL: sourceURL,
            displayName: "Second",
            resumeData: Data("second".utf8)
        )

        XCTAssertFalse(
            coordinator.claimPendingResume(
                downloadID: firstID,
                session: firstSession,
                webView: firstSession.webView
            )
        )
        XCTAssertTrue(
            coordinator.claimPendingResume(
                downloadID: secondID,
                session: secondSession,
                webView: secondSession.webView
            )
        )
    }

    func testReopeningPendingBrowserResumeDoesNotStartDuplicateDownload() throws {
        var resumeInvocationCount = 0
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in
                resumeInvocationCount += 1
            },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let id = UUID()

        let originalSession = coordinator.startSession(
            downloadID: id,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: Data("resume".utf8)
        )
        coordinator.cancelSession()
        let reopenedSession = coordinator.startSession(
            downloadID: id,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: Data("resume".utf8)
        )

        XCTAssertEqual(originalSession.id, reopenedSession.id)
        XCTAssertEqual(resumeInvocationCount, 1)
    }

    func testStaleBrowserCallbacksCannotDismissReplacementSession() throws {
        var failedDownloadIDs: [UUID] = []
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { event in
                if case let .failed(id, _) = event {
                    failedDownloadIDs.append(id)
                }
            }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let firstID = UUID()
        let secondID = UUID()
        let firstSession = coordinator.startSession(
            downloadID: firstID,
            sourceURL: sourceURL,
            displayName: "First",
            resumeData: Data("first".utf8)
        )
        coordinator.cancelSession()
        let secondSession = coordinator.startSession(
            downloadID: secondID,
            sourceURL: sourceURL,
            displayName: "Second",
            resumeData: Data("second".utf8)
        )

        coordinator.webView(
            firstSession.webView,
            didFailProvisionalNavigation: nil,
            withError: URLError(.cannotConnectToHost)
        )
        coordinator.webViewDidClose(firstSession.webView)

        XCTAssertTrue(failedDownloadIDs.isEmpty)
        XCTAssertTrue(
            coordinator.claimPendingResume(
                downloadID: secondID,
                session: secondSession,
                webView: secondSession.webView
            )
        )
    }

    func testDismissedFreshBrowserSessionDoesNotRetainResumableWebView() throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let id = UUID()

        _ = coordinator.startSession(
            downloadID: id,
            sourceURL: sourceURL,
            displayName: "Download"
        )

        XCTAssertFalse(coordinator.hasResumableWebView(id: id))
        coordinator.cancelSession()
        XCTAssertFalse(coordinator.hasResumableWebView(id: id))
    }

    func testRestoredBrowserResumeDoesNotBlockNextQueuedDownload() async throws {
        let suiteName = "HarborTests.BrowserResumeQueue.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserResumeQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        settings.maxConcurrentDownloads = 1
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let olderBrowserItem = DownloadItem(
            createdAt: .now.addingTimeInterval(-10),
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued,
            browserResumeData: Data("browser-resume".utf8)
        )
        let newerDirectItem = DownloadItem(
            createdAt: .now,
            sourceURL: try XCTUnwrap(URL(string: "harbor-test://ordinary-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        try await persistence.save([
            olderBrowserItem.makeRecord(),
            newerDirectItem.makeRecord()
        ])

        let center = DownloadCenter(settings: settings, persistence: persistence)
        await center.initializeIfNeeded()

        let restoredBrowserItem = try XCTUnwrap(
            center.downloads.first { $0.id == olderBrowserItem.id }
        )
        let restoredDirectItem = try XCTUnwrap(
            center.downloads.first { $0.id == newerDirectItem.id }
        )
        XCTAssertEqual(restoredBrowserItem.status, .browserSessionRequired)
        XCTAssertNotEqual(restoredDirectItem.status, .queued)
        XCTAssertNotNil(restoredDirectItem.startedAt)

        await center.shutdownForTermination()
    }

    func testBrowserFailureWithoutResumeDataClearsStaleProgress() async throws {
        let suiteName = "HarborTests.BrowserFailureProgress.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserFailureProgressTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading,
            progress: 0.8,
            bytesWritten: 8,
            expectedBytes: 10
        )
        center.downloads = [item]

        center.handleBrowserDownloadEvent(
            BrowserDownloadEvent.failed(
                id: item.id,
                failure: DirectDownloadFailure(
                    error: URLError(.networkConnectionLost),
                    resumeData: nil
                )
            )
        )

        XCTAssertEqual(item.status, .failed)
        XCTAssertNil(item.browserResumeData)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)
        XCTAssertEqual(item.progress, 0)

        await center.shutdownForTermination()
    }

    func testBrowserResumeHTTP200ResetsPreviousPayloadProgress() async throws {
        let suiteName = "HarborTests.BrowserResumeFallback.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserResumeFallbackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .preparing,
            progress: 0.8,
            bytesWritten: 8,
            expectedBytes: 10,
            browserResumeData: Data("webkit-resume".utf8)
        )
        center.downloads = [item]

        center.handleBrowserDownloadEvent(
            .started(
                id: item.id,
                suggestedFilename: "replacement.bin",
                expectedBytes: 5,
                responseMimeType: "application/octet-stream",
                statusCode: 200,
                isResumed: true
            )
        )

        XCTAssertEqual(item.status, .downloading)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 5)
        XCTAssertEqual(item.progress, 0)
        XCTAssertNil(item.browserResumeData)

        await center.shutdownForTermination()
    }

    func testBrowserRetryWaitsForCancellationCompletion() async throws {
        let suiteName = "HarborTests.BrowserCancellationRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserCancellationRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let browserItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading,
            progress: 0.5,
            bytesWritten: 5,
            expectedBytes: 10
        )
        let occupiedSlot = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/occupied")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        let cancellationGate = AsyncTestGate()
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.maxConcurrentDownloads = 1
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            browserCancellationCheck: { _, id in
                id == browserItem.id
            },
            browserCancelOperation: { _, _ in
                await cancellationGate.wait()
            }
        )
        center.downloads = [browserItem, occupiedSlot]

        center.cancelDownload(id: browserItem.id)
        center.retryDownload(id: browserItem.id)
        center.retryDownload(id: browserItem.id)
        XCTAssertEqual(browserItem.status, .cancelled)

        await cancellationGate.release()
        for _ in 0 ..< 100 {
            if browserItem.status == .queued {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(browserItem.status, .queued)
        XCTAssertEqual(browserItem.bytesWritten, 0)
        XCTAssertEqual(browserItem.expectedBytes, 0)
        XCTAssertEqual(browserItem.progress, 0)

        await center.shutdownForTermination()
    }

    func testReentrantQueueDrainDoesNotRestartFailedSnapshotItem() async throws {
        let suiteName = "HarborTests.ReentrantQueueDrain.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborReentrantQueueDrainTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: recoveryRoot.path
            )
            try? fileManager.removeItem(at: testRoot)
        }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        settings.maxConcurrentDownloads = 1
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let firstItem = DownloadItem(
            createdAt: .now.addingTimeInterval(-10),
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/first.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        let secondItem = DownloadItem(
            createdAt: .now,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/second.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        for item in [firstItem, secondItem] {
            try Data("partial".utf8).write(
                to: recoveryRoot
                    .appendingPathComponent(item.id.uuidString)
                    .appendingPathExtension("part")
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: recoveryRoot.path
        )
        try await persistence.save([firstItem.makeRecord(), secondItem.makeRecord()])

        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: recoveryRoot
        )
        await center.initializeIfNeeded()

        for itemID in [firstItem.id, secondItem.id] {
            let restoredItem = try XCTUnwrap(center.downloads.first { $0.id == itemID })
            XCTAssertEqual(restoredItem.status, .failed)
            XCTAssertEqual(
                restoredItem.activityEvents.filter { $0.kind == .started }.count,
                1
            )
            XCTAssertEqual(
                restoredItem.activityEvents.filter { $0.kind == .failed }.count,
                1
            )
        }

        await center.shutdownForTermination()
    }

    func testRecoveryResetAllowsExpectedByteCountToShrink() async throws {
        let suiteName = "HarborTests.RecoveryExpectedBytes.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborRecoveryExpectedBytesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/replaced.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .preparing,
            bytesWritten: 8,
            expectedBytes: 10
        )
        center.downloads = [item]

        center.handle(
            .started(
                id: item.id,
                taskIdentifier: 1,
                usesOwnedPartial: true,
                ownedRecovery: nil,
                resetReason: .missingValidator
            )
        )
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)

        item.bytesWritten = 8
        item.expectedBytes = 10
        center.handle(.recoveryReset(id: item.id, reason: .serverRejectedRange))
        center.handle(
            DownloadEvent.progress(
                id: item.id,
                bytesWritten: 5,
                expectedBytes: 5,
                speedBytesPerSecond: 0
            )
        )
        XCTAssertEqual(item.bytesWritten, 5)
        XCTAssertEqual(item.expectedBytes, 5)
        XCTAssertEqual(item.progress, 1)

        await center.shutdownForTermination()
    }

    func testLatePauseResultCannotOverwriteCompletedDownload() async throws {
        let suiteName = "HarborTests.LatePauseCompletion.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborLatePauseCompletionTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let temporaryURL = testRoot.appendingPathComponent("incoming.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("done".utf8).write(to: temporaryURL)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/done.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .downloading,
            progress: 1,
            bytesWritten: 4,
            expectedBytes: 4,
            taskIdentifier: 1
        )
        center.downloads = [item]

        center.togglePauseResume(id: item.id)
        center.handle(
            .finished(
                id: item.id,
                temporaryURL: temporaryURL,
                suggestedFilename: "done.bin",
                responseMimeType: "application/octet-stream",
                statusCode: 200
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.bytesWritten, 4)
        XCTAssertEqual(item.expectedBytes, 4)
        XCTAssertEqual(item.progress, 1)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: destinationRoot.appendingPathComponent("done.bin").path
            )
        )

        await center.shutdownForTermination()
    }

    func testPauseWithoutRecoveryClearsEntireProgressTuple() async throws {
        let suiteName = "HarborTests.PauseWithoutRecovery.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborPauseWithoutRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading,
            progress: 0.5,
            bytesWritten: 5,
            expectedBytes: 10,
            taskIdentifier: 1
        )
        center.downloads = [item]

        center.togglePauseResume(id: item.id)
        for _ in 0 ..< 100 {
            if item.status == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)
        XCTAssertEqual(item.progress, 0)
        XCTAssertNotNil(item.lastError)

        await center.shutdownForTermination()
    }

    func testUnclaimableCompletionEventsDiscardTemporaryFiles() async throws {
        let suiteName = "HarborTests.UnclaimableCompletion.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnclaimableCompletionTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let directTemporaryURL = testRoot.appendingPathComponent("direct.download")
        let browserTemporaryURL = testRoot.appendingPathComponent("browser.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("direct".utf8).write(to: directTemporaryURL)
        try Data("browser".utf8).write(to: browserTemporaryURL)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let cancelledItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/cancelled.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: testRoot.path,
            status: .cancelled
        )
        center.downloads = [cancelledItem]

        center.handle(
            .finished(
                id: cancelledItem.id,
                temporaryURL: directTemporaryURL,
                suggestedFilename: "cancelled.bin",
                responseMimeType: "application/octet-stream",
                statusCode: 200
            )
        )
        center.handleBrowserDownloadEvent(
            .finished(
                id: UUID(),
                temporaryURL: browserTemporaryURL,
                suggestedFilename: "removed.bin",
                responseMimeType: "application/octet-stream",
                statusCode: 200,
                expectedBytes: 7
            )
        )

        XCTAssertEqual(cancelledItem.status, .cancelled)
        XCTAssertFalse(fileManager.fileExists(atPath: directTemporaryURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: browserTemporaryURL.path))

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

        center.handle(
            .started(
                id: item.id,
                taskIdentifier: 99,
                usesOwnedPartial: true,
                ownedRecovery: nil,
                resetReason: nil
            )
        )
        center.handle(
            .progress(
                id: item.id,
                bytesWritten: 5,
                expectedBytes: 10,
                speedBytesPerSecond: 1
            )
        )
        center.handle(.recoveryReset(id: item.id, reason: .serverRejectedRange))
        center.handle(
            .failed(
                id: item.id,
                failure: DirectDownloadFailure(
                    error: URLError(.networkConnectionLost),
                    resumeData: nil
                )
            )
        )
        center.handleBrowserDownloadEvent(
            .started(
                id: item.id,
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

    func testMediaRetryWaitsForCleanupAndRejectsRetiredAttemptEvents() async throws {
        let suiteName = "HarborTests.MediaCleanupRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCleanupRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let cleanupGate = AsyncTestGate()
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.maxConcurrentDownloads = 1
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            mediaCleanupOperation: { _, _ in
                await cleanupGate.wait()
            }
        )
        let mediaItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused
        )
        let occupiedSlot = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/occupied")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        center.downloads = [mediaItem]

        center.togglePauseResume(id: mediaItem.id)
        let retiredAttempt = try XCTUnwrap(
            center.activeMediaAttemptIdentifier(for: mediaItem.id)
        )
        center.handle(
            .started(
                id: mediaItem.id,
                processIdentifier: 123,
                expectedBytes: 1_000,
                title: "Video",
                platform: nil
            ),
            attemptIdentifier: retiredAttempt
        )
        center.downloads.append(occupiedSlot)

        center.cancelDownload(id: mediaItem.id)
        center.retryDownload(id: mediaItem.id)
        center.retryDownload(id: mediaItem.id)
        XCTAssertEqual(mediaItem.status, .cancelled)

        await cleanupGate.release()
        for _ in 0 ..< 100 {
            if mediaItem.status == .queued {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mediaItem.status, .queued)

        // Releasing the occupied slot schedules a genuinely new media attempt.
        center.cancelDownload(id: occupiedSlot.id)
        let currentAttempt = try XCTUnwrap(
            center.activeMediaAttemptIdentifier(for: mediaItem.id)
        )
        XCTAssertNotEqual(currentAttempt, retiredAttempt)
        XCTAssertEqual(mediaItem.status, .preparing)

        center.handle(
            .started(
                id: mediaItem.id,
                processIdentifier: 123,
                expectedBytes: 1_000,
                title: "Stale title",
                platform: nil
            ),
            attemptIdentifier: retiredAttempt
        )
        center.handle(
            .progress(
                id: mediaItem.id,
                bytesWritten: 900,
                expectedBytes: 1_000,
                speedBytesPerSecond: 500
            ),
            attemptIdentifier: retiredAttempt
        )
        XCTAssertEqual(mediaItem.status, .preparing)
        XCTAssertNil(mediaItem.backendIdentifier)
        XCTAssertEqual(mediaItem.bytesWritten, 0)
        XCTAssertEqual(mediaItem.speedBytesPerSecond, 0)

        center.handle(
            .started(
                id: mediaItem.id,
                processIdentifier: 456,
                expectedBytes: 1_000,
                title: "Current title",
                platform: nil
            ),
            attemptIdentifier: currentAttempt
        )
        XCTAssertEqual(mediaItem.status, .downloading)
        XCTAssertEqual(mediaItem.backendIdentifier, "456")

        center.cancelDownload(id: mediaItem.id)
        await center.shutdownForTermination()
    }

    func testMediaResumeWaitsForPendingPauseTermination() async throws {
        let suiteName = "HarborTests.MediaPauseResume.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaPauseResumeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let pauseGate = AsyncTestGate()
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.maxConcurrentDownloads = 1
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            mediaPauseOperation: { _, _ in
                await pauseGate.wait()
            }
        )
        let mediaItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        mediaItem.backendIdentifier = "123"
        let occupiedSlot = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/occupied")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        center.downloads = [mediaItem, occupiedSlot]

        center.pauseDownloads(ids: [mediaItem.id])
        center.resumeDownloads(ids: [mediaItem.id])

        XCTAssertEqual(mediaItem.status, .paused)
        XCTAssertNil(center.activeMediaAttemptIdentifier(for: mediaItem.id))

        await pauseGate.release()
        for _ in 0 ..< 100 {
            if mediaItem.status == .queued {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(mediaItem.status, .queued)
        XCTAssertNil(center.activeMediaAttemptIdentifier(for: mediaItem.id))

        await center.shutdownForTermination()
    }

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

        let browserRecoveryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserDownloads", isDirectory: true)
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
            persistence: persistence
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
            recordSaveOperation: { _, _ in
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

    func testShutdownSnapshotCannotBeOverwrittenByLateDebouncedSave() async throws {
        let suiteName = "HarborTests.ShutdownPersistence.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborShutdownPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let pauseGate = AsyncTestGate()
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaPauseOperation: { _, _ in
                await pauseGate.wait()
            }
        )
        let mediaItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        mediaItem.backendIdentifier = "123"
        center.downloads = [mediaItem]
        center.pauseDownloads(ids: [mediaItem.id])

        let shutdownTask = Task { @MainActor in
            await center.shutdownForTermination()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        center.setDownloadLimitOverride(.unlimited, for: mediaItem.id)
        mediaItem.bytesWritten = 99
        mediaItem.expectedBytes = 100
        mediaItem.progress = 0.99

        await pauseGate.release()
        await shutdownTask.value
        try await Task.sleep(for: .milliseconds(350))

        let persistedRecords = try await persistence.load()
        let persistedItem = try XCTUnwrap(
            persistedRecords.first { $0.id == mediaItem.id }
        )
        XCTAssertEqual(persistedItem.bytesWritten, 99)
        XCTAssertEqual(persistedItem.expectedBytes, 100)
        XCTAssertEqual(persistedItem.progress, 0.99)
    }

    func testDirectDownloadThrottlePreservesLowRateByteDebt() throws {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 1,
            globalSpeedLimitBytesPerSecond: nil,
            perDownloadSpeedLimitBytesPerSecond: 1_024,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 1
        )

        let delay = try XCTUnwrap(DownloadCoordinator.throttleDelay(
            deltaBytes: 64 * 1_024,
            elapsed: 1,
            activeTransferCount: 1,
            transferSettings: settings,
            speedLimitOverride: .inherit
        ))

        XCTAssertEqual(delay, 63, accuracy: 0.001)
    }

    func testDirectDownloadRetryPolicyUsesBoundedBackoff() {
        XCTAssertEqual(
            (1 ... 5).compactMap { DirectDownloadRetryPolicy.delay(forAttempt: $0)?.components.seconds },
            [2, 5, 15, 30, 60]
        )
        XCTAssertNil(DirectDownloadRetryPolicy.delay(forAttempt: 0))
        XCTAssertNil(DirectDownloadRetryPolicy.delay(forAttempt: 6))
    }

    func testDirectRetryBackoffReleasesConcurrencySlot() async throws {
        let suiteName = "HarborTests.DirectRetrySlot.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDirectRetrySlotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.maxConcurrentDownloads = 1
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot)
        )
        let retryingItem = DownloadItem(
            createdAt: .now.addingTimeInterval(-10),
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/retrying")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .downloading
        )
        let queuedBrowserItem = DownloadItem(
            createdAt: .now,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued,
            browserResumeData: Data("browser-resume".utf8)
        )
        center.downloads = [retryingItem, queuedBrowserItem]

        center.handle(
            .failed(
                id: retryingItem.id,
                failure: DirectDownloadFailure(
                    error: URLError(.networkConnectionLost),
                    resumeData: nil
                )
            )
        )

        XCTAssertEqual(retryingItem.status, .waitingToRetry)
        XCTAssertTrue(retryingItem.isRunning)
        XCTAssertFalse(retryingItem.status.consumesDownloadSlot)
        XCTAssertEqual(queuedBrowserItem.status, .browserSessionRequired)

        await center.shutdownForTermination()
    }

    func testDirectDownloadRetryPolicyOnlyRetriesRecoverableURLFailures() {
        XCTAssertTrue(DirectDownloadRetryPolicy.isRetryable(.networkConnectionLost))
        XCTAssertTrue(DirectDownloadRetryPolicy.isRetryable(.notConnectedToInternet))
        XCTAssertTrue(DirectDownloadRetryPolicy.isRetryable(.timedOut))
        XCTAssertTrue(DirectDownloadRetryPolicy.isRetryable(.secureConnectionFailed))

        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.cancelled))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.userAuthenticationRequired))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.serverCertificateHasBadDate))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.serverCertificateUntrusted))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.serverCertificateHasUnknownRoot))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.serverCertificateNotYetValid))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.clientCertificateRejected))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(.clientCertificateRequired))
        XCTAssertFalse(DirectDownloadRetryPolicy.isRetryable(nil))
    }

    func testLegacyResumeHTTPFailuresReachTransientStatusRetryPolicy() throws {
        let transientFailure = try XCTUnwrap(
            DownloadCoordinator.legacyDownloadHTTPFailure(
                statusCode: 503,
                startedFromResumeData: true
            )
        )
        XCTAssertEqual(transientFailure.httpStatusCode, 503)
        XCTAssertTrue(transientFailure.isRetryable)
        XCTAssertTrue(transientFailure.requiresFreshStart)

        let permanentFailure = try XCTUnwrap(
            DownloadCoordinator.legacyDownloadHTTPFailure(
                statusCode: 403,
                startedFromResumeData: true
            )
        )
        XCTAssertEqual(permanentFailure.httpStatusCode, 403)
        XCTAssertFalse(permanentFailure.isRetryable)

        XCTAssertNil(
            DownloadCoordinator.legacyDownloadHTTPFailure(
                statusCode: 200,
                startedFromResumeData: true
            )
        )
    }

    func testRejectedResumeAttemptRequiresFreshStart() {
        let failure = DirectDownloadFailure(
            error: URLError(.cannotDecodeContentData),
            resumeData: nil,
            wasResuming: true
        )

        XCTAssertTrue(failure.isRetryable)
        XCTAssertTrue(failure.requiresFreshStart)
        XCTAssertNil(failure.resumeData)
    }

    func testOwnedPartialFailureRemainsRecoverableWithoutAppleResumeData() {
        let failure = DirectDownloadFailure(
            error: URLError(.networkConnectionLost),
            resumeData: nil,
            wasResuming: true,
            recoverableBytes: 4_096
        )

        XCTAssertTrue(failure.isRetryable)
        XCTAssertFalse(failure.requiresFreshStart)
        XCTAssertEqual(failure.recoverableBytes, 4_096)
    }

    func testOwnedPartialRequestUsesRangeAndStrongValidator() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let metadata = DirectDownloadRecoveryMetadata(
            sourceURL: sourceURL,
            entityTag: "\"archive-v1\"",
            lastModified: nil,
            expectedBytes: 8_192,
            suggestedFilename: "archive.bin",
            mimeType: "application/octet-stream"
        )
        let recovery = DirectDownloadRecoverySnapshot(
            bytesWritten: 4_096,
            metadata: metadata
        )

        let request = DownloadCoordinator.ownedDownloadRequest(
            sourceURL: sourceURL,
            recovery: recovery
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4096-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"archive-v1\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testValidatorlessPartialIsNotReportedAsRecoverable() throws {
        let fileManager = FileManager.default
        let recoveryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborValidatorlessStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: recoveryRoot) }

        let store = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let handle = try store.openFreshFile(id: id)
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        try store.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: nil,
                lastModified: nil,
                expectedBytes: 10,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )

        XCTAssertNil(store.snapshot(id: id, sourceURL: sourceURL))
        XCTAssertNil(store.recoveredByteCount(id: id))
        let preparation = try store.prepareStart(id: id, sourceURL: sourceURL)
        XCTAssertNil(preparation.snapshot)
        XCTAssertNil(preparation.resetReason)
        XCTAssertNil(store.recoveredByteCount(id: id))
    }

    func testStartupCleanupDiscardsOnlyOwnedTemporaryHandoffFiles() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTemporaryHandoffCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let directRoot = testRoot.appendingPathComponent("Direct", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("Browser", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: directRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: browserRoot, withIntermediateDirectories: true)

        let directHandoff = directRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        let browserHandoff = browserRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        let directUnrelated = directRoot.appendingPathComponent("keep.txt")
        let browserUnrelated = browserRoot.appendingPathComponent("not-a-download.download")
        for url in [directHandoff, browserHandoff, directUnrelated, browserUnrelated] {
            try Data("temporary".utf8).write(to: url)
        }

        let directCoordinator = DownloadCoordinator(
            eventHandler: { _ in },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            temporaryDirectory: directRoot
        )
        let browserCoordinator = BrowserDownloadCoordinator(
            fileManager: fileManager,
            temporaryDirectory: browserRoot,
            onEvent: { _ in }
        )
        directCoordinator.discardOrphanedTemporaryFiles()
        browserCoordinator.discardOrphanedTemporaryFiles()

        XCTAssertFalse(fileManager.fileExists(atPath: directHandoff.path))
        XCTAssertFalse(fileManager.fileExists(atPath: browserHandoff.path))
        XCTAssertTrue(fileManager.fileExists(atPath: directUnrelated.path))
        XCTAssertTrue(fileManager.fileExists(atPath: browserUnrelated.path))
    }

    func testContentRangeParserRejectsMismatchedOrMalformedRanges() {
        XCTAssertEqual(
            DownloadCoordinator.contentRange(from: "bytes 4096-8191/16384"),
            DirectDownloadContentRange(start: 4_096, end: 8_191, total: 16_384)
        )
        XCTAssertNil(DownloadCoordinator.contentRange(from: "items 1-2/3"))
        XCTAssertNil(DownloadCoordinator.contentRange(from: "bytes 9-4/10"))
        XCTAssertNil(DownloadCoordinator.contentRange(from: "bytes 5-7/not-a-number"))
        XCTAssertEqual(
            DownloadCoordinator.unsatisfiedContentRangeTotal(from: "bytes */8192"),
            8_192
        )
    }

    func testInterruptedDirectDownloadContinuesFromOwnedPartialFile() async throws {
        InterruptingRangeURLProtocol.reset()

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDirectRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]

        let firstFailure = expectation(description: "The first request is interrupted")
        let completion = expectation(description: "The range request completes the file")
        let eventState = DirectDownloadTestEventState()

        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .progress(_, bytesWritten, expectedBytes, _):
                    eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)

        let failure = eventState.firstFailure
        XCTAssertEqual(failure?.recoverableBytes, 5)
        XCTAssertFalse(failure?.requiresFreshStart ?? true)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            5
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let unwrappedResultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: unwrappedResultURL) }
        XCTAssertEqual(try Data(contentsOf: unwrappedResultURL), Data("abcdefghij".utf8))
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        let requests = InterruptingRangeURLProtocol.capturedHeaders
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].range)
        XCTAssertEqual(requests[1].range, "bytes=5-")
        XCTAssertEqual(requests[1].ifRange, "\"test-etag\"")
    }

    func testChangedResumeValidatorRestartsWithoutCombiningRepresentations() async throws {
        InterruptingRangeURLProtocol.reset(changeValidatorOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborChangedValidatorTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial representation is interrupted")
        let changedValidatorFailure = expectation(description: "The changed representation is rejected")
        let completion = expectation(description: "A fresh request downloads the replacement representation")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: changedValidatorFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [changedValidatorFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("klmnopqrst".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-", nil]
        )
    }

    func testChangedResumeTotalRestartsWithoutCombiningRepresentations() async throws {
        InterruptingRangeURLProtocol.reset(changeTotalOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborChangedResumeTotalTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial ten-byte representation is interrupted")
        let changedTotalFailure = expectation(description: "The contradictory eight-byte total is rejected")
        let completion = expectation(description: "A fresh request downloads the eight-byte replacement")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: changedTotalFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [changedTotalFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("uvwxyz12".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-", nil]
        )
    }

    func testFullResponseFallbackDoesNotReusePartialRepresentationMetadata() async throws {
        InterruptingRangeURLProtocol.reset(fallbackToFullResponseOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborFallbackMetadataTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The old HTML representation is interrupted")
        let completion = expectation(description: "The full replacement response completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    if eventState.recordFailure(failure) == 1 {
                        initialFailure.fulfill()
                    }
                case let .finished(
                    _, temporaryURL, suggestedFilename, responseMimeType, statusCode
                ):
                    eventState.recordCompletion(
                        temporaryURL,
                        suggestedFilename: suggestedFilename,
                        responseMimeType: responseMimeType,
                        statusCode: statusCode
                    )
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("uvwxyz12".utf8))
        XCTAssertNotEqual(eventState.completedSuggestedFilename, "old.html")
        XCTAssertNotEqual(eventState.completedResponseMimeType, "text/html")
        XCTAssertEqual(eventState.completedStatusCode, 200)
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-"]
        )
    }

    func testContradictoryUnsatisfiedRangeCannotCertifyIncompletePartial() async throws {
        InterruptingRangeURLProtocol.reset(contradictSavedTotalOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborContradictory416Tests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial ten-byte representation is interrupted")
        let contradictoryRangeFailure = expectation(description: "The contradictory five-byte total is rejected")
        let completion = expectation(description: "A fresh request downloads the five-byte replacement")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: contradictoryRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [contradictoryRangeFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("uvwxy".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-", nil]
        )
    }

    func testCompletePartialKeepsPayloadMetadataWhenRangeResponseIsHTML() async throws {
        InterruptingRangeURLProtocol.reset(completePartialWithHTML416: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborComplete416MetadataTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        let recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let handle = try recoveryStore.openFreshFile(id: id)
        try handle.write(contentsOf: Data("abcde".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"test-etag\"",
                lastModified: nil,
                expectedBytes: 5,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let completion = expectation(description: "The complete partial is claimed")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                if case let .finished(
                    _, temporaryURL, suggestedFilename, responseMimeType, statusCode
                ) = event {
                    eventState.recordCompletion(
                        temporaryURL,
                        suggestedFilename: suggestedFilename,
                        responseMimeType: responseMimeType,
                        statusCode: statusCode
                    )
                    completion.fulfill()
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcde".utf8))
        XCTAssertEqual(eventState.completedSuggestedFilename, "archive.bin")
        XCTAssertEqual(eventState.completedResponseMimeType, "application/octet-stream")
        XCTAssertEqual(eventState.completedStatusCode, 206)
        XCTAssertEqual(InterruptingRangeURLProtocol.capturedHeaders.map(\.range), ["bytes=5-"])
    }

    func testIncompleteRangeResponseRetainsPartialInsteadOfFinishing() async throws {
        InterruptingRangeURLProtocol.reset(shortFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborShortRangeTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The initial transfer is interrupted")
        let incompleteRangeFailure = expectation(description: "The capped range is rejected")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: incompleteRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [incompleteRangeFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.isRetryable ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 8)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            8
        )
    }

    func testOverlongRangeResponseCannotPublishUndeclaredBytesOnRetry() async throws {
        InterruptingRangeURLProtocol.reset(overlongFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborOverlongRangeTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial transfer is interrupted")
        let overflowFailure = expectation(description: "The overlong range is rejected")
        let completion = expectation(description: "The safe range retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: overflowFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [overflowFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.isRetryable ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 8)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            8
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcdefghij".utf8))

        let requests = InterruptingRangeURLProtocol.capturedHeaders
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].range, "bytes=5-")
        XCTAssertEqual(requests[2].range, "bytes=8-")
    }

    func testUnknownRangeTotalPreservesSavedLengthAndRejectsTruncation() async throws {
        InterruptingRangeURLProtocol.reset(unknownTotalFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnknownRangeTotalTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The initial transfer is interrupted")
        let incompleteRangeFailure = expectation(description: "The unknown-total range is rejected")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: incompleteRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [incompleteRangeFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.isRetryable ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 8)
        let recovery = coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)
        XCTAssertEqual(recovery?.bytesWritten, 8)
        XCTAssertEqual(recovery?.metadata.expectedBytes, 10)
    }

    func testValidatorlessInterruptedDownloadRestartsWithoutRange() async throws {
        InterruptingRangeURLProtocol.reset(omitValidator: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborValidatorlessDownloadTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The validator-less transfer is interrupted")
        let completion = expectation(description: "The fresh retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)

        XCTAssertEqual(eventState.firstFailure?.recoverableBytes, 0)
        XCTAssertTrue(eventState.firstFailure?.requiresFreshStart ?? false)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: recoveryRoot
                    .appendingPathComponent(id.uuidString)
                    .appendingPathExtension("part")
                    .path
            )
        )
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: recoveryRoot
                    .appendingPathComponent(id.uuidString)
                    .appendingPathExtension("json")
                    .path
            )
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let resultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: resultURL) }
        XCTAssertEqual(try Data(contentsOf: resultURL), Data("abcdefghij".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, nil]
        )
    }

    func testHTTPErrorDuringOwnedResumePreservesPartialAndDoesNotReportErrorBodyProgress() async throws {
        InterruptingRangeURLProtocol.reset(rejectFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborHTTPRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The initial transfer is interrupted")
        let rejectedResume = expectation(description: "The first range request receives an HTTP error")
        let completion = expectation(description: "The next range request completes the file")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: rejectedResume.fulfill()
                    default: break
                    }
                case let .progress(_, bytesWritten, expectedBytes, _):
                    eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, temporaryURL, _, _, _):
                    eventState.recordCompletion(temporaryURL)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)
        let progressCountBeforeRejection = eventState.progressCount

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [rejectedResume], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(eventState.failures.last?.httpStatusCode, 403)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 5)
        XCTAssertEqual(eventState.progressCount, progressCountBeforeRejection)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            5
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let resultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: resultURL) }
        XCTAssertEqual(try Data(contentsOf: resultURL), Data("abcdefghij".utf8))
    }

    func testMediaRecoveryCleanupPreservesRecordedFoldersAndRemovesOrphans() async throws {
        let fileManager = FileManager.default
        let recoveryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: recoveryRoot) }

        let retainedID = UUID()
        let orphanedID = UUID()
        let retainedFolder = recoveryRoot.appendingPathComponent(retainedID.uuidString, isDirectory: true)
        let orphanedFolder = recoveryRoot.appendingPathComponent(orphanedID.uuidString, isDirectory: true)
        let unrelatedFolder = recoveryRoot.appendingPathComponent("not-a-download", isDirectory: true)
        for folder in [retainedFolder, orphanedFolder, unrelatedFolder] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        await service.discardOrphanedRecoveryData(retaining: Set([retainedID]))

        XCTAssertTrue(fileManager.fileExists(atPath: retainedFolder.path))
        XCTAssertFalse(fileManager.fileExists(atPath: orphanedFolder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedFolder.path))

        try await service.discardRecoveryData(id: retainedID)
        XCTAssertFalse(fileManager.fileExists(atPath: retainedFolder.path))
    }

    func testAriaPerTorrentOptionsUseAuthoritativeItemLimits() {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: 900_000,
            perDownloadSpeedLimitBytesPerSecond: 500_000,
            globalUploadSpeedLimitBytesPerSecond: 300_000,
            perDownloadUploadSpeedLimitBytesPerSecond: 200_000,
            perDownloadConnectionCount: 6
        )
        let options = Aria2TorrentService.perDownloadOptions(
            settings,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: 75_000,
                shouldSeed: true
            )
        )

        XCTAssertEqual(options["max-download-limit"], "0")
        XCTAssertEqual(options["max-upload-limit"], "75000")
        XCTAssertEqual(options["max-connection-per-server"], "6")
        XCTAssertEqual(options["seed-ratio"], "0.0")
        XCTAssertNil(options["seed-time"])
    }

    func testAriaRecoveryOptionsResumeAndWaitBeforeGivingUp() {
        let options = Aria2TorrentService.recoveryOptions

        XCTAssertEqual(options["continue"], "true")
        XCTAssertEqual(options["max-tries"], "10")
        XCTAssertEqual(options["retry-wait"], "5")
        XCTAssertEqual(options["bt-stop-timeout"], "0")
    }

    func testMediaDownloadArgumentsKeepAutomaticAndExactFormatPathsSeparate() throws {
        let runtime = MediaRuntimeResolution(
            ytDlpURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe")
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/video"))
        let destinationURL = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let temporaryURL = URL(fileURLWithPath: "/tmp/media", isDirectory: true)

        let limitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            speedLimitBytesPerSecond: 345_678
        )
        let unlimitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            speedLimitBytesPerSecond: nil
        )

        let limitIndex = try XCTUnwrap(limitedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(limitedArguments[limitedArguments.index(after: limitIndex)], "345678")
        XCTAssertFalse(unlimitedArguments.contains("--limit-rate"))
        XCTAssertFalse(limitedArguments.contains("--format"))
        XCTAssertFalse(unlimitedArguments.contains("--format"))

        let retryValues = zip(limitedArguments, limitedArguments.dropFirst())
            .filter { $0.0 == "--retry-sleep" }
            .map(\.1)
        XCTAssertEqual(
            retryValues,
            [
                "http:exp=2:60",
                "fragment:exp=2:60",
                "file_access:exp=2:60",
                "extractor:exp=2:60"
            ]
        )
        func value(after option: String) -> String? {
            guard let optionIndex = limitedArguments.firstIndex(of: option) else {
                return nil
            }

            let valueIndex = limitedArguments.index(after: optionIndex)
            return limitedArguments.indices.contains(valueIndex)
                ? limitedArguments[valueIndex]
                : nil
        }
        XCTAssertEqual(value(after: "--retries"), "10")
        XCTAssertEqual(value(after: "--fragment-retries"), "10")
        XCTAssertEqual(value(after: "--file-access-retries"), "3")
        XCTAssertEqual(value(after: "--extractor-retries"), "3")

        let videoFormat = MediaDownloadFormatOption(
            formatID: "137",
            container: "mp4",
            videoCodec: "avc1.640028",
            audioCodec: nil,
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            dynamicRange: "SDR",
            bitrateKbps: 4_500,
            estimatedBytes: 9_000_000
        )
        let audioFormat = MediaDownloadFormatOption(
            formatID: "140",
            container: "m4a",
            videoCodec: nil,
            audioCodec: "mp4a.40.2",
            width: nil,
            height: nil,
            framesPerSecond: nil,
            dynamicRange: nil,
            bitrateKbps: 128,
            estimatedBytes: 1_000_000,
            language: "en",
            formatNote: "English (Original)",
            audioChannels: 2,
            languagePreference: 10
        )
        let metadata = MediaDownloadMetadata(
            title: "Video",
            platform: "Test",
            extractorKey: "Test",
            thumbnailURL: nil,
            webpageURL: sourceURL,
            expectedBytes: 10_000_000,
            mediaType: .video,
            entryCount: 1,
            capabilities: MediaDownloadCapabilities(
                formatOptions: [videoFormat, audioFormat]
            )
        )
        let selection = MediaDownloadFormatSelection(
            format: videoFormat,
            audioFormat: audioFormat
        )
        let selectedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: metadata.persistenceSnapshot,
            formatPreference: .specific(selection),
            speedLimitBytesPerSecond: 345_678
        )

        let formatIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--format"))
        XCTAssertEqual(selectedArguments[selectedArguments.index(after: formatIndex)], "137+140")
        let mergeIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--merge-output-format"))
        XCTAssertEqual(selectedArguments[selectedArguments.index(after: mergeIndex)], "mp4")
        let selectedLimitIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(
            selectedArguments[selectedArguments.index(after: selectedLimitIndex)],
            "345678"
        )

        XCTAssertEqual(
            selection.displaySummary,
            "1080p • MP4 • AVC1 + English (Original)"
        )
        XCTAssertEqual(
            MediaDownloadFormatPreference.specific(selection)
                .initialExpectedBytes(metadataEstimate: 243_768_398),
            selection.estimatedBytes
        )
        XCTAssertEqual(
            MediaDownloadFormatPreference.bestAvailable
                .initialExpectedBytes(metadataEstimate: 243_768_398),
            243_768_398
        )
    }

    func testMediaRecordPersistsSelectionWithoutFormatCatalog() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/video"))
        let videoFormat = MediaDownloadFormatOption(
            formatID: "137",
            container: "mp4",
            videoCodec: "avc1.640028",
            audioCodec: nil,
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            dynamicRange: "SDR",
            bitrateKbps: 4_500,
            estimatedBytes: 9_000_000
        )
        let audioFormat = MediaDownloadFormatOption(
            formatID: "140",
            container: "m4a",
            videoCodec: nil,
            audioCodec: "mp4a.40.2",
            width: nil,
            height: nil,
            framesPerSecond: nil,
            dynamicRange: nil,
            bitrateKbps: 128,
            estimatedBytes: 1_000_000,
            language: "en",
            formatNote: "English (Original)",
            audioChannels: 2,
            languagePreference: 10
        )
        let metadata = MediaDownloadMetadata(
            title: "Video",
            platform: "Test",
            extractorKey: "Test",
            thumbnailURL: nil,
            webpageURL: sourceURL,
            expectedBytes: 10_000_000,
            mediaType: .video,
            entryCount: 1,
            capabilities: MediaDownloadCapabilities(
                formatOptions: [videoFormat, audioFormat]
            )
        )
        let selection = MediaDownloadFormatSelection(
            format: videoFormat,
            audioFormat: audioFormat
        )
        let item = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp/downloads",
            status: .paused,
            mediaMetadata: metadata,
            mediaFormatPreference: .specific(selection)
        )

        let record = item.makeRecord()

        XCTAssertEqual(record.mediaMetadata?.capabilities, .unavailable)
        XCTAssertEqual(record.mediaFormatPreference, .specific(selection))
        XCTAssertEqual(
            item.mediaMetadata?.capabilities.formatOptions,
            [videoFormat, audioFormat]
        )

        let encodedRecord = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: encodedRecord, as: UTF8.self).contains("formatOptions"))
    }

    func testUnavailableExactMediaFormatHasDedicatedError() {
        XCTAssertEqual(
            MediaDownloadErrorClassifier.message(
                from: "ERROR: [youtube] Requested format is not available"
            ),
            MediaDownloadErrorClassifier.selectedFormatUnavailableMessage
        )
    }

    func testLegacyCompletedTorrentDoesNotSeed() throws {
        let record = try legacyTorrentRecord(status: .completed)

        XCTAssertFalse(record.shouldSeedAfterDownload)
        XCTAssertFalse(record.removeOriginalTorrentAfterImport)
        XCTAssertTrue(record.completionNotificationDelivered)
        XCTAssertEqual(record.downloadLimitOverride, .inherit)
        XCTAssertEqual(record.uploadLimitOverride, .inherit)
        XCTAssertTrue(record.torrentPayloadPaths.isEmpty)
    }

    func testLegacyUnfinishedTorrentSeeds() throws {
        let record = try legacyTorrentRecord(status: .downloading)

        XCTAssertTrue(record.shouldSeedAfterDownload)
    }

    func testTorrentDisplayNamePrefersSemanticMetadata() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.torrent"),
            sourceKind: .torrentFile,
            metadataName: "Ubuntu 26.04",
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "Ubuntu 26.04")
    }

    func testTorrentDisplayNameUsesTorrentFilenameBeforePayloadFilename() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu-desktop.torrent"),
            sourceKind: .torrentFile,
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "ubuntu-desktop")
    }

    func testMagnetDisplayNameWinsOverPayloadFilename() throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "magnet:?xt=urn:btih:ABC123&dn=Ubuntu%2026.04")
        )
        let item = makeTorrentItem(
            sourceURL: sourceURL,
            sourceKind: .magnetLink,
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "Ubuntu 26.04")
    }

    func testSeedingStatusIsActiveButDoesNotConsumeDownloadConcurrency() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.torrent"),
            sourceKind: .torrentFile,
            status: .seeding
        )

        XCTAssertFalse(DownloadStatus.seeding.isTerminal)
        XCTAssertFalse(DownloadStatus.seeding.isRunning)
        XCTAssertTrue(DownloadStatus.allCases.contains(.seeding))
        XCTAssertTrue(DownloadFilter.active.includes(item))
        XCTAssertTrue(item.canPause)
    }

    func testBrowserResumeDataPersistsSeparatelyFromURLSessionResumeData() throws {
        let browserResumeData = Data("webkit-resume".utf8)
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .failed,
            browserResumeData: browserResumeData
        )

        let encoded = try JSONEncoder().encode(item.makeRecord())
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: encoded)

        XCTAssertEqual(decoded.browserResumeData, browserResumeData)
        XCTAssertNil(decoded.resumeData)
    }

    func testPayloadResolutionRejectsRootAndTraversalAndKeepsExactPayloadPaths() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("destination", isDirectory: true)
        let outsideURL = rootURL.appendingPathComponent("outside.bin")
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let resolution = DownloadDataRemovalService().resolvePayloadURLs(
            destinationFolderPath: destinationURL.path,
            payloadPaths: [
                "Collection/one.bin",
                "Collection/two.bin",
                destinationURL.appendingPathComponent("single.iso").path,
                destinationURL.path,
                "../outside.bin",
                outsideURL.path
            ]
        )

        XCTAssertEqual(
            resolution.safeURLs.map(\.path),
            [
                destinationURL.appendingPathComponent("Collection/one.bin").path,
                destinationURL.appendingPathComponent("Collection/two.bin").path,
                destinationURL.appendingPathComponent("single.iso").path
            ]
        )
        XCTAssertEqual(
            Set(resolution.rejectedPaths),
            Set([destinationURL.path, "../outside.bin", outsideURL.path])
        )
    }

    private func legacyTorrentRecord(status: DownloadStatus) throws -> DownloadRecord {
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
            "torrentFingerprint",
            "managedTorrentSourcePath",
            "torrentPayloadPaths",
            "shouldSeedAfterDownload",
            "removeOriginalTorrentAfterImport",
            "completionNotificationDelivered"
        ].forEach { object.removeValue(forKey: $0) }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
    }

    private func makeTorrentItem(
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

private actor AsyncTestGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isReleased == false else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private nonisolated final class DirectDownloadTestEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailures: [DirectDownloadFailure] = []
    private var storedProgress: [(bytesWritten: Int64, expectedBytes: Int64)] = []
    private var storedCompletedURL: URL?
    private var storedCompletedSuggestedFilename: String?
    private var storedCompletedResponseMimeType: String?
    private var storedCompletedStatusCode: Int?

    var firstFailure: DirectDownloadFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures.first
    }

    var failures: [DirectDownloadFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }

    var progressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedProgress.count
    }

    var completedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedURL
    }

    var completedSuggestedFilename: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedSuggestedFilename
    }

    var completedResponseMimeType: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedResponseMimeType
    }

    var completedStatusCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedStatusCode
    }

    func recordFailure(_ failure: DirectDownloadFailure) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedFailures.append(failure)
        return storedFailures.count
    }

    func recordProgress(bytesWritten: Int64, expectedBytes: Int64) {
        lock.lock()
        storedProgress.append((bytesWritten, expectedBytes))
        lock.unlock()
    }

    func recordCompletion(_ url: URL) {
        lock.lock()
        storedCompletedURL = url
        lock.unlock()
    }

    func recordCompletion(
        _ url: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?
    ) {
        lock.lock()
        storedCompletedURL = url
        storedCompletedSuggestedFilename = suggestedFilename
        storedCompletedResponseMimeType = responseMimeType
        storedCompletedStatusCode = statusCode
        lock.unlock()
    }
}

private nonisolated final class InterruptingRangeURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedHeaders: Sendable {
        let range: String?
        let ifRange: String?
    }

    private static let stateLock = NSLock()
    private static var headers: [CapturedHeaders] = []
    private static var shouldRejectFirstResume = false
    private static var shouldShortenFirstResume = false
    private static var shouldOverrunFirstResume = false
    private static var shouldUseUnknownTotalForFirstResume = false
    private static var shouldOmitValidator = false
    private static var shouldChangeValidatorOnFirstResume = false
    private static var shouldChangeTotalOnFirstResume = false
    private static var shouldFallbackToFullResponseOnFirstResume = false
    private static var shouldContradictSavedTotalOnFirstResume = false
    private static var shouldCompletePartialWithHTML416 = false

    static var capturedHeaders: [CapturedHeaders] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return headers
    }

    static func reset(
        rejectFirstResume: Bool = false,
        shortFirstResume: Bool = false,
        overlongFirstResume: Bool = false,
        unknownTotalFirstResume: Bool = false,
        omitValidator: Bool = false,
        changeValidatorOnFirstResume: Bool = false,
        changeTotalOnFirstResume: Bool = false,
        fallbackToFullResponseOnFirstResume: Bool = false,
        contradictSavedTotalOnFirstResume: Bool = false,
        completePartialWithHTML416: Bool = false
    ) {
        stateLock.lock()
        headers = []
        shouldRejectFirstResume = rejectFirstResume
        shouldShortenFirstResume = shortFirstResume
        shouldOverrunFirstResume = overlongFirstResume
        shouldUseUnknownTotalForFirstResume = unknownTotalFirstResume
        shouldOmitValidator = omitValidator
        shouldChangeValidatorOnFirstResume = changeValidatorOnFirstResume
        shouldChangeTotalOnFirstResume = changeTotalOnFirstResume
        shouldFallbackToFullResponseOnFirstResume = fallbackToFullResponseOnFirstResume
        shouldContradictSavedTotalOnFirstResume = contradictSavedTotalOnFirstResume
        shouldCompletePartialWithHTML416 = completePartialWithHTML416
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "recovery.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        Self.stateLock.lock()
        Self.headers.append(CapturedHeaders(range: range, ifRange: ifRange))
        let requestNumber = Self.headers.count
        let rejectFirstResume = Self.shouldRejectFirstResume
        let shortenFirstResume = Self.shouldShortenFirstResume
        let overrunFirstResume = Self.shouldOverrunFirstResume
        let useUnknownTotalForFirstResume = Self.shouldUseUnknownTotalForFirstResume
        let omitValidator = Self.shouldOmitValidator
        let changeValidatorOnFirstResume = Self.shouldChangeValidatorOnFirstResume
        let changeTotalOnFirstResume = Self.shouldChangeTotalOnFirstResume
        let fallbackToFullResponseOnFirstResume = Self.shouldFallbackToFullResponseOnFirstResume
        let contradictSavedTotalOnFirstResume = Self.shouldContradictSavedTotalOnFirstResume
        let completePartialWithHTML416 = Self.shouldCompletePartialWithHTML416
        Self.stateLock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if range == nil, requestNumber == 1 {
            var headerFields = [
                "Content-Length": "10",
                "Content-Type": fallbackToFullResponseOnFirstResume
                    ? "text/html"
                    : "application/octet-stream"
            ]
            if fallbackToFullResponseOnFirstResume {
                headerFields["Content-Disposition"] = "attachment; filename=old.html"
            }
            if omitValidator == false {
                headerFields["ETag"] = "\"test-etag\""
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcde".utf8))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else {
                    return
                }
                self.client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.networkConnectionLost)
                )
            }
            return
        }

        if omitValidator, range == nil, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "10",
                    "Content-Type": "application/octet-stream"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcdefghij".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeValidatorOnFirstResume, range == nil, requestNumber == 3 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("klmnopqrst".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeTotalOnFirstResume, range == nil, requestNumber == 3 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "8",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("uvwxyz12".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if contradictSavedTotalOnFirstResume, range == nil, requestNumber == 3 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("uvwxy".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if overrunFirstResume,
           requestNumber == 3,
           range == "bytes=8-",
           ifRange == "\"test-etag\"" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 8-9/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ij".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard range == "bytes=5-", ifRange == "\"test-etag\"" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if completePartialWithHTML416, requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes */5",
                    "Content-Type": "text/html",
                    "Content-Disposition": "attachment; filename=error.html",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeValidatorOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Range": "bytes 5-9/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("pqrst".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeTotalOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "3",
                    "Content-Range": "bytes 5-7/8",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fgh".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if fallbackToFullResponseOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "8",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("uvwxyz12".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if contradictSavedTotalOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes */5",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if rejectFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "9",
                    "Content-Type": "text/plain"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else {
                    return
                }
                self.client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        if shortenFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes 5-7/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fgh".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if overrunFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Range": "bytes 5-7/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fghXX".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if useUnknownTotalForFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "3",
                    "Content-Range": "bytes 5-7/*",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fgh".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "5",
                "Content-Range": "bytes 5-9/10",
                "Content-Type": "application/octet-stream",
                "ETag": "\"test-etag\""
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fghij".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
