import Foundation
import WebKit
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testHarborURLSchemeIsRegistered() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }

        XCTAssertTrue(schemes.contains("harbor"))
    }

    func testExternalHTTPSourcePrefillsAddSheetWithDefaultDestination() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborExternalSourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let settings = HarborPreviewFixtures.makeSettings()
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(
                directoryURL: testRoot.appendingPathComponent("Persistence", isDirectory: true)
            ),
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery", isDirectory: true),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs", isDirectory: true),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery", isDirectory: true),
            pendingDataRemovalDirectoryURL: testRoot.appendingPathComponent("PendingRemoval", isDirectory: true),
            managedTorrentSourceStore: ManagedTorrentSourceStore(
                fileManager: fileManager,
                directoryURL: testRoot.appendingPathComponent("ManagedTorrents", isDirectory: true)
            ),
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
            )
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/file.zip"))

        center.receiveExternalAddSources([sourceURL])
        await center.initializeIfNeeded()

        let draft = try XCTUnwrap(center.addSheetDraft)
        XCTAssertEqual(draft.entryMode, .linkOrMagnet)
        XCTAssertEqual(draft.sourceURLText, sourceURL.absoluteString)
        XCTAssertEqual(draft.destinationFolderURL, settings.defaultDestinationURL)
        await center.shutdownForTermination()
    }

    func testDownloadedPayloadClassifierDetectsTorrentResponses() {
        let extensionlessURL = URL(string: "https://example.com/download?id=42")!

        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: nil,
                responseMimeType: "application/x-bittorrent"
            )
        )
        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "Linux.torrent",
                responseMimeType: "application/octet-stream"
            )
        )
        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: URL(string: "https://example.com/linux.torrent")!,
                suggestedFilename: nil,
                responseMimeType: nil
            )
        )
        XCTAssertFalse(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "archive.zip",
                responseMimeType: "application/octet-stream"
            )
        )
        XCTAssertFalse(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "error.torrent",
                responseMimeType: "application/x-bittorrent",
                statusCode: 404
            )
        )
    }

    func testTorrentShareRatioPersistsWithUploadedBytes() throws {
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .seeding,
            progress: 1,
            bytesWritten: 1_000,
            expectedBytes: 1_000,
            uploadedBytes: 1_500
        )

        XCTAssertEqual(item.shareRatio, 1.5)

        let restoredItem = DownloadItem(record: item.makeRecord())
        XCTAssertEqual(restoredItem.uploadedBytes, 1_500)
        XCTAssertEqual(restoredItem.shareRatio, 1.5)
    }

    func testDownloadedTorrentHandoffReusesTheDirectDownloadRow() {
        let sourceURL = URL(string: "https://example.com/download?id=42")!
        let item = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "metadata.torrent",
            destinationFolderPath: "/tmp",
            fileLocationPath: "/tmp/metadata.torrent",
            status: .downloading,
            progress: 1,
            bytesWritten: 512,
            expectedBytes: 512,
            finishedAt: .now,
            resumeData: Data([0x01]),
            taskIdentifier: 7,
            backendIdentifier: "old-backend",
            completionNotificationDelivered: true,
            activityEvents: [
                DownloadActivityEvent(kind: .added),
                DownloadActivityEvent(kind: .started)
            ]
        )
        let originalID = item.id
        let originalActivity = item.activityEvents

        DownloadCenter.configureDownloadedTorrentHandoff(
            item,
            shouldSeedAfterDownload: true
        )

        XCTAssertEqual(item.id, originalID)
        XCTAssertEqual(item.sourceURL, sourceURL)
        XCTAssertEqual(item.sourceKind, .torrentFile)
        XCTAssertEqual(item.backend, .aria2)
        XCTAssertEqual(item.status, .preparing)
        XCTAssertEqual(item.activityEvents, originalActivity)
        XCTAssertNil(item.preferredFilename)
        XCTAssertNil(item.fileLocationPath)
        XCTAssertNil(item.resumeData)
        XCTAssertNil(item.taskIdentifier)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.progress, 0)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)
        XCTAssertNil(item.finishedAt)
        XCTAssertTrue(item.shouldSeedAfterDownload)
        XCTAssertFalse(item.completionNotificationDelivered)
    }

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

    func testNewBrowserAttemptAbandonsPendingResumeInsteadOfSharingItsCallback() throws {
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

        XCTAssertNotEqual(originalSession.id, reopenedSession.id)
        XCTAssertNotEqual(
            originalSession.attemptIdentifier,
            reopenedSession.attemptIdentifier
        )
        XCTAssertEqual(resumeInvocationCount, 2)
    }

    func testSameBrowserAttemptReusesItsPendingResumeCallback() throws {
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
        let attemptIdentifier = UUID()

        let originalSession = coordinator.startSession(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: Data("resume".utf8)
        )
        coordinator.cancelSession()
        let reopenedSession = coordinator.startSession(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: Data("resume".utf8)
        )

        XCTAssertEqual(originalSession.id, reopenedSession.id)
        XCTAssertEqual(resumeInvocationCount, 1)
    }

    func testPendingBrowserResumeQuiescenceReturnsOriginalBlobWhenWebKitNeverCallsBack() async throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let id = UUID()
        let attemptIdentifier = UUID()
        let resumeData = Data("opaque-webkit-resume-data".utf8)
        _ = coordinator.startSession(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: resumeData
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await coordinator.quiesceDownload(id: id)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(result?.attemptIdentifier, attemptIdentifier)
        XCTAssertEqual(result?.resumeData, resumeData)
        XCTAssertNil(result?.completionUnavailableMessage)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertFalse(coordinator.hasPendingOrActiveAttempt(id: id))
        XCTAssertFalse(coordinator.hasResumableWebView(id: id))
    }


    func testSuccessfulBrowserResumeRetainsFreshDataAfterTransientFailure() {
        XCTAssertFalse(
            BrowserDownloadCoordinator.shouldRetireResumeData(
                after: URLError(.networkConnectionLost),
                statusCode: 206
            )
        )
        XCTAssertFalse(
            BrowserDownloadCoordinator.shouldRetireResumeData(
                after: URLError(.networkConnectionLost),
                statusCode: 200
            )
        )
        XCTAssertTrue(
            BrowserDownloadCoordinator.shouldRetireResumeData(
                after: URLError(.badServerResponse),
                statusCode: 404
            )
        )
    }


    func testRetainedResumeCallbackDoesNotRetainQuiescedWebView() async throws {
        var retainedCompletion: BrowserDownloadCoordinator.ResumeCompletion?
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, completion in
                retainedCompletion = completion
            },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let id = UUID()
        var session: BrowserDownloadSession? = coordinator.startSession(
            downloadID: id,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            displayName: "Archive",
            resumeData: Data("resume".utf8)
        )
        weak var weakWebView: WKWebView?
        weakWebView = session?.webView
        XCTAssertNotNil(retainedCompletion)

        _ = await coordinator.quiesceDownload(id: id)
        session = nil
        for _ in 0 ..< 100 where weakWebView != nil {
            autoreleasepool {}
            await Task.yield()
        }

        XCTAssertNil(weakWebView)
        withExtendedLifetime(retainedCompletion) {}
    }


    func testStaleBrowserCallbacksCannotDismissReplacementSession() throws {
        var failedDownloadIDs: [UUID] = []
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { event in
                if case let .failed(id, _, _) = event {
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


    func testMissingBrowserRecoveryDirectoryIsAnEmptyCompletionLookup() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMissingBrowserRecovery-\(UUID().uuidString)", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("Browser", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let coordinator = BrowserDownloadCoordinator(
            fileManager: fileManager,
            temporaryDirectory: browserRoot,
            completedHandoffStore: CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: handoffRoot
            ),
            onEvent: { _ in }
        )
        try fileManager.removeItem(at: browserRoot)

        let failures = try await coordinator.recoverCompletedTemporaryFiles(
            downloadID: UUID()
        )
        XCTAssertTrue(failures.isEmpty)
    }

    func testBrowserCompletionRecoveryReportsOperationalRootFailure() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserRecoveryRootFailure-\(UUID().uuidString)", isDirectory: true)
        let browserRoot = testRoot.appendingPathComponent("not-a-directory")
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: browserRoot)

        let coordinator = BrowserDownloadCoordinator(
            fileManager: fileManager,
            temporaryDirectory: browserRoot,
            completedHandoffStore: CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: handoffRoot
            ),
            onEvent: { _ in }
        )

        do {
            _ = try await coordinator.recoverCompletedTemporaryFiles()
            XCTFail("An unreadable recovery root must not be treated as empty")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
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
                0,
                "Strict recovery preflight must reject the unsafe partial before URLSession starts"
            )
            XCTAssertEqual(
                restoredItem.activityEvents.filter { $0.kind == .failed }.count,
                1
            )
        }

        await center.shutdownForTermination()
    }
}
