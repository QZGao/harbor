import CryptoKit
import Darwin
import Foundation
import WebKit
import XCTest
@testable import Harbor

@MainActor
final class HarborModelAndSafetyTests: XCTestCase {
    private struct ChildMediaAttemptReceipt: Encodable {
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

    private func writeChildOwnedMediaCompletionEvidence(
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

    private func makeCompletedHandoff(
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


    func testUnclaimableCompletionEventsDiscardTemporaryFiles() async throws {
        let suiteName = "HarborTests.UnclaimableCompletion.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnclaimableCompletionTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let directTemporaryURL = testRoot.appendingPathComponent("direct.download")
        let browserTemporaryURL = testRoot.appendingPathComponent("browser.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("direct".utf8).write(to: directTemporaryURL)
        try Data("browser".utf8).write(to: browserTemporaryURL)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            completedHandoffDirectoryURL: handoffRoot
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
        let directAttemptIdentifier = UUID()
        let directHandoff = try makeCompletedHandoff(
            payloadURL: directTemporaryURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: cancelledItem.id,
            attemptIdentifier: directAttemptIdentifier,
            sourceURL: cancelledItem.sourceURL,
            suggestedFilename: "cancelled.bin"
        )
        let removedID = UUID()
        let browserAttemptIdentifier = UUID()
        let browserSourceURL = try XCTUnwrap(URL(string: "https://example.test/removed.bin"))
        let browserHandoff = try makeCompletedHandoff(
            payloadURL: browserTemporaryURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: removedID,
            attemptIdentifier: browserAttemptIdentifier,
            sourceURL: browserSourceURL,
            owner: .browser,
            suggestedFilename: "removed.bin"
        )

        center.handle(
            .finished(
                id: cancelledItem.id,
                attemptIdentifier: directAttemptIdentifier,
                handoff: directHandoff
            )
        )
        center.handleBrowserDownloadEvent(
            .finished(
                id: removedID,
                attemptIdentifier: browserAttemptIdentifier,
                handoff: browserHandoff
            )
        )

        XCTAssertEqual(cancelledItem.status, .cancelled)
        XCTAssertFalse(fileManager.fileExists(atPath: directHandoff.packageURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: browserHandoff.packageURL.path))

        await center.shutdownForTermination()
    }

    func testCompletedHandoffSurvivesSaveFailureAndSupersedesCorruptSibling() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected completion save failure" }
        }

        let suiteName = "HarborTests.CompletedHandoffRecovery.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborCompletedHandoffRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let incomingURL = testRoot.appendingPathComponent("incoming.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("verified-payload".utf8).write(to: incomingURL)

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

        let validAttempt = UUID()
        _ = try makeCompletedHandoff(
            payloadURL: incomingURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: item.id,
            attemptIdentifier: validAttempt,
            sourceURL: item.sourceURL,
            suggestedFilename: "archive.bin"
        )
        let corruptPackageURL = handoffRoot
            .appendingPathComponent("\(item.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("handoff")
        try fileManager.createDirectory(at: corruptPackageURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: corruptPackageURL.appendingPathComponent("manifest.json")
        )

        var failedCenter: DownloadCenter? = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot,
            recordSaveOperation: { _, _, _ in
                throw ExpectedSaveFailure()
            }
        )
        await failedCenter?.initializeIfNeeded()

        // The validated journal owns the placed payload, but completion is
        // not exposed until the corresponding record is durable.
        XCTAssertEqual(failedCenter?.downloads.first?.status, .failed)
        XCTAssertFalse(fileManager.fileExists(atPath: corruptPackageURL.path))
        let handoffStore = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let retainedEntries = try handoffStore.entries()
        XCTAssertEqual(retainedEntries.count, 1)
        guard case let .valid(retainedHandoff) = try XCTUnwrap(retainedEntries.first) else {
            return XCTFail("Expected the completion handoff to remain valid")
        }
        XCTAssertNotNil(retainedHandoff.payloadURL)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: destinationRoot.appendingPathComponent("archive.bin").path
            )
        )
        failedCenter = nil

        // The failed record save leaves the journal authoritative. A third
        // party can replace the visible pathname before relaunch without
        // stealing or destroying the completed payload.
        let firstDestinationURL = destinationRoot.appendingPathComponent("archive.bin")
        let replacement = Data("replacement-owned-by-another-writer".utf8)
        try replacement.write(to: firstDestinationURL)

        let restoredCenter = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot
        )
        await restoredCenter.initializeIfNeeded()

        let restoredItem = try XCTUnwrap(
            restoredCenter.downloads.first { $0.id == item.id }
        )
        XCTAssertEqual(restoredItem.status, .completed)
        XCTAssertEqual(restoredItem.bytesWritten, Int64("verified-payload".utf8.count))
        let recoveredDestinationURL = destinationRoot.appendingPathComponent("archive 2.bin")
        XCTAssertEqual(restoredItem.fileLocationPath, recoveredDestinationURL.path)
        XCTAssertEqual(try Data(contentsOf: firstDestinationURL), replacement)
        XCTAssertEqual(
            try Data(contentsOf: recoveredDestinationURL),
            Data("verified-payload".utf8)
        )
        XCTAssertTrue(
            try CompletedDownloadHandoffStore(directoryURL: handoffRoot).entries().isEmpty
        )
        let persistedRecords = try await persistence.load()
        XCTAssertEqual(persistedRecords.first?.status, .completed)

        await restoredCenter.shutdownForTermination()
    }

    func testValidStagingHandoffReplacesCorruptReadyPackage() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborStagingPromotionTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let payloadURL = testRoot.appendingPathComponent("payload.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: payloadURL)

        let store = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let handoff = try store.publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: UUID(),
                attemptIdentifier: UUID(),
                owner: .direct,
                sourceURL: try XCTUnwrap(URL(string: "https://example.test/payload.bin")),
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "payload.bin",
                actualBytes: 7,
                expectedBytes: 7
            )
        )
        let readyURL = handoff.packageURL
        let stagingURL = readyURL.deletingPathExtension().appendingPathExtension("staging")
        try fileManager.moveItem(at: readyURL, to: stagingURL)
        try fileManager.createDirectory(at: readyURL, withIntermediateDirectories: false)
        try Data("corrupt".utf8).write(
            to: readyURL.appendingPathComponent("manifest.json")
        )

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        guard case let .valid(promoted) = try XCTUnwrap(entries.first) else {
            return XCTFail("Expected the valid staging package to be promoted")
        }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(promoted.payloadURL)), Data("payload".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.path))
    }

    func testFinalizePromotesReadyManifestLeftInStagingDirectory() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborReadyStagingFinalizeTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let payloadURL = testRoot.appendingPathComponent("payload.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: payloadURL)

        let store = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let ready = try store.publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: UUID(),
                attemptIdentifier: UUID(),
                owner: .direct,
                sourceURL: try XCTUnwrap(URL(string: "https://example.test/payload.bin")),
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "payload.bin",
                actualBytes: 7,
                expectedBytes: 7
            )
        )
        let stagingURL = ready.packageURL
            .deletingPathExtension()
            .appendingPathExtension("staging")
        try fileManager.moveItem(at: ready.packageURL, to: stagingURL)
        let repeatedClaim = CompletedDownloadHandoffClaim(
            packageURL: stagingURL,
            manifest: ready.manifest
        )

        let finalized = try store.finalize(repeatedClaim)

        XCTAssertEqual(finalized.manifest, ready.manifest)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(finalized.payloadURL)),
            Data("payload".utf8)
        )
        XCTAssertTrue(fileManager.fileExists(atPath: ready.packageURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.path))
    }

    func testClaimingHandoffSurvivesReadFailureAndFinishesRecovery() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborClaimingHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let packageURL = handoffRoot
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)",
                isDirectory: true
            )
            .appendingPathExtension("staging")
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let payloadURL = packageURL.appendingPathComponent("payload")
        var restoredPermissions = false
        defer {
            if restoredPermissions == false {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: manifestURL.path
                )
            }
            try? fileManager.removeItem(at: testRoot)
        }

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let payload = Data("claimed-before-hash".utf8)
        try payload.write(to: payloadURL)
        let claim = CompletedDownloadHandoffManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            owner: .direct,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/claimed.bin")),
            statusCode: 200,
            mimeType: "application/octet-stream",
            suggestedFilename: "claimed.bin",
            actualBytes: Int64(payload.count),
            expectedBytes: Int64(payload.count),
            phase: .claiming
        )
        try JSONEncoder().encode(claim).write(to: manifestURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: manifestURL.path
        )

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        let unavailableEntries = try store.entries()
        XCTAssertEqual(unavailableEntries.count, 1)
        guard case .unavailable = try XCTUnwrap(unavailableEntries.first) else {
            return XCTFail("A transient manifest read failure must retain the claimed payload")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: packageURL.path))

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
        restoredPermissions = true
        let recoveredEntries = try store.entries()
        guard case let .valid(handoff) = try XCTUnwrap(recoveredEntries.first) else {
            return XCTFail("Expected the claiming handoff to finish after access returned")
        }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(handoff.payloadURL)), payload)
        XCTAssertEqual(handoff.manifest.phase, .ready)
        XCTAssertEqual(handoff.manifest.payloadSHA256.count, SHA256.byteCount * 2)
        XCTAssertEqual(handoff.packageURL.pathExtension, "handoff")
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.path))
    }

    func testDanglingDestinationSymlinkCannotBeOverwritten() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDanglingDestinationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let occupiedURL = directoryURL.appendingPathComponent("archive.bin")
        try fileManager.createSymbolicLink(
            at: occupiedURL,
            withDestinationURL: directoryURL.appendingPathComponent("missing-target.bin")
        )

        let resolved = try DownloadDestinationResolver(fileManager: fileManager)
            .uniqueDestinationURL(for: "archive.bin", in: directoryURL)
        XCTAssertEqual(resolved, directoryURL.appendingPathComponent("archive 2.bin"))
        XCTAssertNoThrow(
            try fileManager.destinationOfSymbolicLink(atPath: occupiedURL.path)
        )
    }

    func testConcurrentDestinationMovesPublishExactlyOnePayloadWithoutReplacement() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborExclusiveDestinationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let resolver = DownloadDestinationResolver(fileManager: fileManager)

        for iteration in 0 ..< 25 {
            let payloads = [
                Data("first-\(iteration)".utf8),
                Data("second-\(iteration)".utf8)
            ]
            let sourceURLs = payloads.indices.map { index in
                directoryURL.appendingPathComponent("source-\(iteration)-\(index).part")
            }
            for index in payloads.indices {
                try payloads[index].write(to: sourceURLs[index])
            }
            let destinationURL = directoryURL.appendingPathComponent("archive-\(iteration).bin")
            let results = ConcurrentMoveResults()
            let ready = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()

            for index in payloads.indices {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    ready.signal()
                    start.wait()
                    do {
                        try resolver.moveDownloadedFile(
                            from: sourceURLs[index],
                            to: destinationURL
                        )
                        results.recordSuccess(index)
                    } catch let error as CocoaError {
                        results.recordCocoaError(error.code)
                    } catch {
                        results.recordUnexpectedError(error)
                    }
                }
            }

            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

            let snapshot = results.snapshot
            XCTAssertEqual(snapshot.successfulIndices.count, 1)
            XCTAssertEqual(snapshot.cocoaErrorCodes, [.fileWriteFileExists])
            XCTAssertTrue(snapshot.unexpectedErrors.isEmpty)
            let winningIndex = try XCTUnwrap(snapshot.successfulIndices.first)
            let losingIndex = winningIndex == 0 ? 1 : 0
            XCTAssertEqual(try Data(contentsOf: destinationURL), payloads[winningIndex])
            XCTAssertEqual(try Data(contentsOf: sourceURLs[losingIndex]), payloads[losingIndex])
        }
    }

    func testRecordedDestinationCollisionDoesNotCorruptIntactHandoffPayload() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborRecordedDestinationCollision-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = testRoot.appendingPathComponent("payload.bin")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let payload = Data("completed-payload".utf8)
        try payload.write(to: payloadURL)

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let handoff = try store.publish(
            payloadAt: payloadURL,
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
        let occupiedURL = destinationRoot.appendingPathComponent("payload.bin")
        _ = try store.recordDestination(occupiedURL, for: handoff)
        try fileManager.createSymbolicLink(
            at: occupiedURL,
            withDestinationURL: destinationRoot.appendingPathComponent("missing.bin")
        )

        let recovered = try XCTUnwrap(
            store.handoff(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier
            )
        )
        XCTAssertNil(recovered.destinationURL)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(recovered.payloadURL)), payload)

        let replacementURL = destinationRoot.appendingPathComponent("payload 2.bin")
        let rerecorded = try store.recordDestination(replacementURL, for: recovered)
        XCTAssertEqual(rerecorded.manifest.destinationPath, replacementURL.path)
        XCTAssertNoThrow(
            try fileManager.destinationOfSymbolicLink(atPath: occupiedURL.path)
        )
    }

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

    func testLegacyRangeCompletionMustMatchSavedResumeOffset() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes 5-9/10",
                    "Content-Length": "5",
                    "Content-Encoding": "identity",
                    "ETag": "\"archive-v1\""
                ]
            )
        )

        XCTAssertEqual(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 10,
                startedFromResumeData: true,
                resumeOffset: 5,
                resumeValidator: "\"archive-v1\""
            ),
            10
        )
        XCTAssertThrowsError(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 10,
                startedFromResumeData: true,
                resumeOffset: 4,
                resumeValidator: "\"archive-v1\""
            )
        )
        XCTAssertThrowsError(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 10,
                startedFromResumeData: true,
                resumeOffset: nil,
                resumeValidator: "\"archive-v1\""
            )
        )
        XCTAssertThrowsError(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 10,
                startedFromResumeData: true,
                resumeOffset: 5,
                resumeValidator: nil
            )
        )
    }

    func testKnownZeroContentLengthRejectsUnexpectedResponseBody() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/empty.bin"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "0",
                    "Content-Encoding": "identity"
                ]
            )
        )

        XCTAssertEqual(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 0,
                startedFromResumeData: false,
                resumeOffset: nil
            ),
            0
        )
        XCTAssertThrowsError(
            try DownloadCoordinator.validatedCompletedByteCount(
                response: response,
                actualBytes: 1,
                startedFromResumeData: false,
                resumeOffset: nil
            )
        )
    }

    func testKnownZeroOwnedResponseCannotPublishUnexpectedBytesThrough416Retry() async throws {
        KnownZeroOverflowURLProtocol.reset()

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborKnownZeroOverflowTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KnownZeroOverflowURLProtocol.self]

        let firstFailure = expectation(description: "The undeclared body is rejected")
        let completion = expectation(description: "A fresh retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            completedHandoffStore: CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: handoffRoot
            ),
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(
            URL(string: "https://known-zero.example.test/archive.bin")
        )
        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [firstFailure], timeout: 2)

        let failure = try XCTUnwrap(eventState.firstFailure)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(failure.recoverableBytes, 0)
        XCTAssertTrue(failure.requiresFreshStart)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
        XCTAssertNil(eventState.completedURL)

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("xyz".utf8))
        XCTAssertEqual(KnownZeroOverflowURLProtocol.capturedRanges.count, 2)
        XCTAssertNil(KnownZeroOverflowURLProtocol.capturedRanges[0])
        XCTAssertNil(KnownZeroOverflowURLProtocol.capturedRanges[1])
    }

    func testBrowserResumeValidatesPublicRangeWithoutOpaqueResumeOffset() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes 5-9/10",
                    "Content-Length": "5",
                    "Content-Encoding": "identity"
                ]
            )
        )

        XCTAssertEqual(
            try BrowserDownloadCoordinator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 10,
                isResumeAttempt: true
            ),
            10
        )
        XCTAssertThrowsError(
            try BrowserDownloadCoordinator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 9,
                isResumeAttempt: true
            )
        )
        XCTAssertThrowsError(
            try BrowserDownloadCoordinator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 10,
                isResumeAttempt: false
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

    func testPostTransferStorageFailureDoesNotScheduleDestructiveResumeRetry() {
        let failure = DirectDownloadFailure(
            error: CocoaError(.fileWriteNoPermission),
            resumeData: nil,
            wasResuming: true
        )

        XCTAssertFalse(failure.isRetryable)
        XCTAssertTrue(failure.requiresFreshStart)
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

    func testTemporarilyUnreadableDirectRecoveryIsPreserved() throws {
        let fileManager = FileManager.default
        let recoveryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnreadableRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let id = UUID()
        let metadataURL = recoveryRoot
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        var restoredPermissions = false
        defer {
            if restoredPermissions == false {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: metadataURL.path
                )
            }
            try? fileManager.removeItem(at: recoveryRoot)
        }

        let store = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let handle = try store.openFreshFile(id: id)
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        try store.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"archive-v1\"",
                lastModified: nil,
                expectedBytes: 10,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: metadataURL.path
        )

        guard case .unavailable = store.lookup(id: id, sourceURL: sourceURL) else {
            return XCTFail("Expected the inaccessible metadata to be reported as unavailable")
        }
        XCTAssertNil(store.snapshot(id: id, sourceURL: sourceURL))
        XCTAssertThrowsError(try store.prepareStart(id: id, sourceURL: sourceURL))
        XCTAssertEqual(store.recoveredByteCount(id: id), 7)
        XCTAssertTrue(fileManager.fileExists(atPath: metadataURL.path))

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadataURL.path
        )
        restoredPermissions = true
        let preparation = try store.prepareStart(id: id, sourceURL: sourceURL)
        XCTAssertEqual(preparation.snapshot?.bytesWritten, 7)
        XCTAssertEqual(preparation.snapshot?.metadata.entityTag, "\"archive-v1\"")
    }

    func testOversizedPartialIsDiscardedBeforeResume() throws {
        let fileManager = FileManager.default
        let recoveryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborOversizedPartialTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: recoveryRoot) }

        let store = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let handle = try store.openFreshFile(id: id)
        try handle.write(contentsOf: Data("too-long".utf8))
        try handle.close()
        try store.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"archive-v1\"",
                lastModified: nil,
                expectedBytes: 4,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )

        let preparation = try store.prepareStart(id: id, sourceURL: sourceURL)
        XCTAssertNil(preparation.snapshot)
        XCTAssertEqual(preparation.resetReason, .invalidLength)
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
        browserCoordinator.discardOrphanedTemporaryFiles(retaining: [])

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
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .progress(_, _, bytesWritten, expectedBytes, _):
                    eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: changedValidatorFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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

    func testMissingResumeValidatorRestartsWithoutCombiningRepresentations() async throws {
        InterruptingRangeURLProtocol.reset(omitValidatorOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMissingResumeValidatorTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial representation is interrupted")
        let missingValidatorFailure = expectation(description: "The unverifiable range is rejected")
        let completion = expectation(description: "A fresh request downloads the replacement representation")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: missingValidatorFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
        await fulfillment(of: [missingValidatorFailure], timeout: 2)

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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: changedTotalFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        initialFailure.fulfill()
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: contradictoryRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                if case let .finished(_, _, handoff) = event {
                    eventState.recordCompletion(handoff)
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

    func testUnsatisfiedRangeWithoutMatchingValidatorCannotCertifyCompletePartial() async throws {
        InterruptingRangeURLProtocol.reset(completePartialWithoutValidator416: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnvalidated416Tests-\(UUID().uuidString)", isDirectory: true)
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
        let failureExpectation = expectation(description: "The unvalidated 416 is rejected")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    _ = eventState.recordFailure(failure)
                    failureExpectation.fulfill()
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [failureExpectation], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: incompleteRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: overflowFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcdefghij".utf8))

        let requests = InterruptingRangeURLProtocol.capturedHeaders
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].range, "bytes=5-")
        XCTAssertNil(requests[2].range)
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
        let completion = expectation(description: "The fresh retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: incompleteRangeFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [incompleteRangeFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.isRetryable ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL, resumeData: nil)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcdefghij".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-", nil]
        )
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
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: rejectedResume.fulfill()
                    default: break
                    }
                case let .progress(_, _, bytesWritten, expectedBytes, _):
                    eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
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
        try await service.discardOrphanedRecoveryData(retaining: Set([retainedID]))

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

        let ratioLimitedOptions = Aria2TorrentService.perDownloadOptions(
            settings,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: true,
                seedRatioLimit: 2
            )
        )
        XCTAssertEqual(ratioLimitedOptions["seed-ratio"], "2.0")
    }

    func testAriaTorrentOptionsDoNotInjectIrrelevantHTTPRecoverySettings() {
        let options = Aria2TorrentService.perDownloadOptions(
            .default,
            transferOptions: nil
        )

        XCTAssertNil(options["continue"])
        XCTAssertNil(options["max-tries"])
        XCTAssertNil(options["retry-wait"])
        XCTAssertNil(options["bt-stop-timeout"])
    }

    func testOnlyExplicitAriaRPCRejectionMakesMutationFailureDefinitive() {
        XCTAssertFalse(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                TorrentEngineError.invalidResponse
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                TorrentEngineError.rpc("The mutation was rejected")
            )
        )
    }

    func testAriaOwnershipMarkerAcceptsCurrentOrReparentedDaemonOnly() {
        XCTAssertTrue(
            Aria2TorrentService.isVerifiedOwnershipParent(
                4321,
                currentProcessIdentifier: 4321
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.isVerifiedOwnershipParent(
                1,
                currentProcessIdentifier: 4321
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.isVerifiedOwnershipParent(
                9876,
                currentProcessIdentifier: 4321
            )
        )
    }

    func testMediaProcessOwnershipRequiresExactPersistedIdentity() throws {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/HarborMediaOwnership",
            isDirectory: true
        )
        let downloadID = UUID()
        let launchedExecutablePath = "/Applications/Harbor.app/Contents/Resources/MediaRuntime/bin/yt-dlp"
        let executablePath = "/usr/bin/python3"
        let temporaryFolder = temporaryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let command = "\(executablePath) \(launchedExecutablePath) --paths temp:\(temporaryFolder.path) https://example.test/video"
        let manifest = MediaProcessOwnershipManifest(
            downloadID: downloadID,
            attemptIdentifier: UUID(),
            pid: 9_001,
            processGroupIdentifier: 9_001,
            launchedExecutablePath: launchedExecutablePath,
            executablePath: executablePath,
            temporaryFolderPath: temporaryFolder.path,
            startSignature: "1786420000:123456",
            command: command
        )
        let exactOwner = MediaRunningProcess(
            pid: 9_001,
            parentPID: 1,
            processGroupIdentifier: 9_001,
            executablePath: executablePath,
            startSignature: manifest.startSignature,
            command: command
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                MediaProcessOwnershipManifest.self,
                from: JSONEncoder().encode(manifest)
            ),
            manifest
        )

        XCTAssertTrue(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                exactOwner,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let unrelatedReader = MediaRunningProcess(
            pid: manifest.pid,
            parentPID: 1,
            processGroupIdentifier: manifest.processGroupIdentifier,
            executablePath: "/usr/bin/tail",
            startSignature: manifest.startSignature,
            command: "/usr/bin/tail -f \(temporaryFolder.appendingPathComponent("payload.part").path)"
        )
        XCTAssertFalse(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                unrelatedReader,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let reusedIdentity = MediaRunningProcess(
            pid: exactOwner.pid,
            parentPID: exactOwner.parentPID,
            processGroupIdentifier: exactOwner.processGroupIdentifier,
            executablePath: exactOwner.executablePath,
            startSignature: "1786420000:123457",
            command: exactOwner.command
        )
        XCTAssertFalse(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                reusedIdentity,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let survivingChild = MediaRunningProcess(
            pid: 9_002,
            parentPID: manifest.pid,
            processGroupIdentifier: manifest.processGroupIdentifier,
            executablePath: "/Applications/Harbor.app/Contents/Resources/MediaRuntime/bin/ffmpeg",
            startSignature: "1786420001:123456",
            command: "ffmpeg -i \(temporaryFolder.appendingPathComponent("payload.part").path)"
        )
        XCTAssertTrue(
            MediaDownloadService.hasLiveProcessGroupMember(
                manifest.processGroupIdentifier,
                in: [survivingChild]
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasLiveProcessGroupMember(
                manifest.processGroupIdentifier,
                in: []
            )
        )
        XCTAssertTrue(
            MediaDownloadService.hasProcessReferencingRecoveryFolder(
                temporaryFolder,
                in: [unrelatedReader]
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasProcessReferencingRecoveryFolder(
                temporaryFolder,
                in: [
                    MediaRunningProcess(
                        pid: 9_003,
                        parentPID: 1,
                        processGroupIdentifier: 9_003,
                        executablePath: "/usr/bin/true",
                        startSignature: "1786420002:123456",
                        command: "/usr/bin/true"
                    )
                ]
            )
        )
        XCTAssertTrue(
            MediaDownloadService.hasUntrackedProcessReferencingRecoveryRoot(
                temporaryRoot,
                in: [survivingChild],
                trackedProcessGroups: []
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasUntrackedProcessReferencingRecoveryRoot(
                temporaryRoot,
                in: [survivingChild],
                trackedProcessGroups: [manifest.processGroupIdentifier]
            )
        )
    }

    func testMediaRecoveryCleanupPreservesDurableProcessOwnershipMarker() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaOwnedCleanup-\(UUID().uuidString)")
        let downloadID = UUID()
        let recoveryFolder = root
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let ownershipMarker = recoveryFolder
            .appendingPathComponent(".harbor-process-owner.json")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: recoveryFolder,
            withIntermediateDirectories: true
        )
        try Data("unverifiable-owner".utf8).write(to: ownershipMarker)
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: root
        )

        do {
            try await service.discardRecoveryData(id: downloadID)
            XCTFail("Cleanup must fail closed while durable process ownership remains")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: recoveryFolder.path))
            XCTAssertTrue(fileManager.fileExists(atPath: ownershipMarker.path))
        }

        // A process scan is the authority that can retire malformed ownership
        // metadata: with no writer referencing the recovery root, cleanup can
        // safely remove the marker and then the recovery directory.
        try await service.terminateOrphanedMediaProcesses()
        XCTAssertFalse(fileManager.fileExists(atPath: ownershipMarker.path))
        try await service.discardRecoveryData(id: downloadID)
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))

        let redirectedID = UUID()
        let redirectedTarget = root.appendingPathComponent("redirected", isDirectory: true)
        let redirectedFolder = root.appendingPathComponent(
            redirectedID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: redirectedTarget, withIntermediateDirectories: true)
        try Data("external-fragment".utf8).write(
            to: redirectedTarget.appendingPathComponent("payload.part")
        )
        try fileManager.createSymbolicLink(
            at: redirectedFolder,
            withDestinationURL: redirectedTarget
        )
        let redirectedBytes = await service.recoverableByteCount(id: redirectedID)
        XCTAssertNil(redirectedBytes)
        do {
            try await service.discardRecoveryData(id: redirectedID)
            XCTFail("Cleanup must not remove a symlinked media recovery folder")
        } catch {}
        XCTAssertEqual(
            try Data(contentsOf: redirectedTarget.appendingPathComponent("payload.part")),
            Data("external-fragment".utf8)
        )
        XCTAssertTrue(fileManager.fileExists(atPath: redirectedFolder.path))
    }

    func testMediaRecoveryCleanupRejectsSymlinkedRootWithoutDeletingTarget() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaSymlinkedRoot-\(UUID().uuidString)")
        let recoveryRoot = container.appendingPathComponent("Recovery", isDirectory: true)
        let externalRoot = container.appendingPathComponent("External", isDirectory: true)
        let downloadID = UUID()
        let externalFolder = externalRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let externalPayload = externalFolder.appendingPathComponent("payload.part")
        defer { try? fileManager.removeItem(at: container) }

        try fileManager.createDirectory(
            at: externalFolder,
            withIntermediateDirectories: true
        )
        let payload = Data("not-owned-by-harbor".utf8)
        try payload.write(to: externalPayload)
        try fileManager.createSymbolicLink(
            at: recoveryRoot,
            withDestinationURL: externalRoot
        )
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )

        do {
            try await service.discardRecoveryData(id: downloadID)
            XCTFail("Item cleanup must reject a symlinked media recovery root")
        } catch {}
        do {
            try await service.discardOrphanedRecoveryData(retaining: [])
            XCTFail("Orphan cleanup must reject a symlinked media recovery root")
        } catch {}
        do {
            try await service.terminateOrphanedMediaProcesses()
            XCTFail("Ownership cleanup must reject a symlinked media recovery root")
        } catch {}

        XCTAssertTrue(fileManager.fileExists(atPath: externalFolder.path))
        XCTAssertEqual(try Data(contentsOf: externalPayload), payload)
    }

    func testMediaCompletionRejectsUnchangedPreexistingDestinationIdentity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaOutputIdentity-\(UUID().uuidString)")
        let outputURL = root.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing-output".utf8).write(to: outputURL)
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: root.appendingPathComponent("Recovery")
        )

        let before = try await service.regularFileIdentity(at: outputURL)
        let unchanged = try await service.regularFileIdentity(at: outputURL)
        XCTAssertFalse(
            MediaDownloadService.isAttemptProducedOutput(
                previousIdentity: before,
                currentIdentity: unchanged
            )
        )

        try Data("new-attempt-output".utf8).write(to: outputURL, options: .atomic)
        let replaced = try await service.regularFileIdentity(at: outputURL)
        XCTAssertTrue(
            MediaDownloadService.isAttemptProducedOutput(
                previousIdentity: before,
                currentIdentity: replaced
            )
        )
    }

    func testTorrentSubmissionReservationIsStableUntilExactAcknowledgement() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentReservation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let store = TorrentSubmissionReservationStore(
            fileManager: fileManager,
            directoryURL: root
        )
        let ownerID = UUID()
        let sourceURL = try XCTUnwrap(
            URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        )

        let first = try store.reserve(
            ownerDownloadID: ownerID,
            sourceURL: sourceURL,
            destinationFolderPath: "/tmp/downloads",
            sourceKind: .magnetLink,
            shouldSeedAfterDownload: true
        )
        let replay = try store.reserve(
            ownerDownloadID: ownerID,
            sourceURL: sourceURL,
            destinationFolderPath: "/tmp/downloads",
            sourceKind: .magnetLink,
            shouldSeedAfterDownload: true
        )

        XCTAssertEqual(first.gid, replay.gid)
        XCTAssertEqual(first.sourceKind, .magnetLink)
        XCTAssertEqual(first.shouldSeedAfterDownload, true)
        XCTAssertEqual(try store.reservations().map(\.gid), [first.gid])
        XCTAssertNotNil(
            first.gid.range(of: "^[0-9a-f]{16}$", options: .regularExpression)
        )
        XCTAssertThrowsError(
            try store.reserve(
                ownerDownloadID: ownerID,
                sourceURL: sourceURL,
                destinationFolderPath: "/tmp/other",
                sourceKind: .magnetLink,
                shouldSeedAfterDownload: true
            )
        )
        XCTAssertThrowsError(
            try store.acknowledge(ownerDownloadID: ownerID, gid: "0000000000000000")
        )
        XCTAssertEqual(try store.reservation(ownerDownloadID: ownerID)?.gid, first.gid)

        try store.acknowledge(ownerDownloadID: ownerID, gid: first.gid)
        XCTAssertNil(try store.reservation(ownerDownloadID: ownerID))
    }

    func testManagedChildProcessDrainsFinalOutputBeforeTermination() async throws {
        let state = ManagedProcessTestState()
        let terminated = expectation(description: "child process terminated")
        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'stdout-first\\nstdout-tail'; printf 'stderr-tail' >&2"
            ],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { state.appendStdout($0) },
            onStderr: { state.appendStderr($0) },
            onTermination: { termination in
                state.recordTermination(termination)
                terminated.fulfill()
            }
        )

        await fulfillment(of: [terminated], timeout: 3)
        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.stdout, "stdout-first\nstdout-tail")
        XCTAssertEqual(snapshot.stderr, "stderr-tail")
        XCTAssertEqual(snapshot.stdoutAtTermination, snapshot.stdout)
        XCTAssertEqual(snapshot.stderrAtTermination, snapshot.stderr)
        XCTAssertTrue(snapshot.termination?.isSuccess == true)
        withExtendedLifetime(process) {}
    }

    func testManagedChildProcessCanAlwaysTerminateAfterSuccessfulConstruction() async throws {
        let state = ManagedProcessTestState()
        let terminated = expectation(description: "managed child was terminated")
        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { state.appendStdout($0) },
            onStderr: { state.appendStderr($0) },
            onTermination: { termination in
                state.recordTermination(termination)
                terminated.fulfill()
            }
        )

        XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier)
        process.terminate(grace: 0.1)
        await fulfillment(of: [terminated], timeout: 3)
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(state.snapshot.termination?.isSuccess ?? true)
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
        let completionReceiptURL = URL(
            fileURLWithPath: "/tmp/media%owned/final-paths.jsonl"
        )

        let limitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: 345_678
        )
        let unlimitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: nil
        )
        let outputConflictIdentifier = UUID()
        let collisionSafeArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            outputConflictIdentifier: outputConflictIdentifier,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: nil
        )

        let limitIndex = try XCTUnwrap(limitedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(limitedArguments[limitedArguments.index(after: limitIndex)], "345678")
        XCTAssertTrue(limitedArguments.contains("--progress"))
        XCTAssertTrue(unlimitedArguments.contains("--progress"))
        XCTAssertFalse(unlimitedArguments.contains("--limit-rate"))
        XCTAssertFalse(limitedArguments.contains("--format"))
        XCTAssertFalse(unlimitedArguments.contains("--format"))
        let collisionOutputIndex = try XCTUnwrap(
            collisionSafeArguments.firstIndex(of: "--output")
        )
        XCTAssertEqual(
            collisionSafeArguments[collisionSafeArguments.index(after: collisionOutputIndex)],
            "%(title).180B [%(id)s] [Harbor \(outputConflictIdentifier.uuidString)].%(ext)s"
        )
        let concurrentDownloadID = UUID()
        XCTAssertNil(
            MediaDownloadService.outputIdentifier(
                requested: nil,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: false
            )
        )
        XCTAssertEqual(
            MediaDownloadService.outputIdentifier(
                requested: nil,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: true
            ),
            concurrentDownloadID
        )
        XCTAssertEqual(
            MediaDownloadService.outputIdentifier(
                requested: outputConflictIdentifier,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: true
            ),
            outputConflictIdentifier
        )

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
        let printToFileIndex = try XCTUnwrap(
            limitedArguments.firstIndex(of: "--print-to-file")
        )
        XCTAssertFalse(limitedArguments.contains("--print"))
        XCTAssertEqual(
            limitedArguments[limitedArguments.index(after: printToFileIndex)],
            "after_move:harbor-file:%(filepath)j"
        )
        let receiptPathIndex = limitedArguments.index(
            printToFileIndex,
            offsetBy: 2
        )
        XCTAssertEqual(
            limitedArguments[receiptPathIndex],
            "/tmp/media%%owned/final-paths.jsonl"
        )

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
            completionReceiptURL: temporaryURL.appendingPathComponent("final-paths.jsonl"),
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

    func testMediaCompletionMonitorPublishesSuccessOnlyAfterCleanExit() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "Harbor Media Monitor ; $()-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        func runMonitor(
            mediaExecutableURL: URL,
            successMarkerURL: URL,
            attemptIdentifier: UUID
        ) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = MediaDownloadService.completionMonitorArguments(
                mediaExecutableURL: mediaExecutableURL,
                successMarkerURL: successMarkerURL,
                attemptIdentifier: attemptIdentifier,
                mediaArguments: []
            )
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let successfulAttempt = UUID()
        let successfulMarker = root.appendingPathComponent("success marker")
        XCTAssertEqual(
            try runMonitor(
                mediaExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                successMarkerURL: successfulMarker,
                attemptIdentifier: successfulAttempt
            ),
            0
        )
        XCTAssertEqual(
            try String(contentsOf: successfulMarker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            successfulAttempt.uuidString
        )

        let failedAttempt = UUID()
        let failedMarker = root.appendingPathComponent("failed marker")
        XCTAssertEqual(
            try runMonitor(
                mediaExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
                successMarkerURL: failedMarker,
                attemptIdentifier: failedAttempt
            ),
            1
        )
        XCTAssertFalse(fileManager.fileExists(atPath: failedMarker.path))

        let unavailableMarker = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("success marker")
        XCTAssertEqual(
            try runMonitor(
                mediaExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                successMarkerURL: unavailableMarker,
                attemptIdentifier: UUID()
            ),
            MediaDownloadService.completionMonitorPublicationFailureExitCode
        )
        XCTAssertFalse(fileManager.fileExists(atPath: unavailableMarker.path))

        let blockedMarker = root.appendingPathComponent("blocked marker")
        let blockedTemporaryMarker = URL(
            fileURLWithPath: blockedMarker.path + ".tmp"
        )
        let sentinel = Data("preexisting-temp".utf8)
        try sentinel.write(to: blockedTemporaryMarker)
        XCTAssertEqual(
            try runMonitor(
                mediaExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
                successMarkerURL: blockedMarker,
                attemptIdentifier: UUID()
            ),
            MediaDownloadService.completionMonitorPublicationFailureExitCode
        )
        XCTAssertFalse(fileManager.fileExists(atPath: blockedMarker.path))
        XCTAssertEqual(try Data(contentsOf: blockedTemporaryMarker), sentinel)

        let terminatedMarker = root.appendingPathComponent("terminated marker")
        let terminatedState = ManagedProcessTestState()
        let terminated = expectation(description: "completion monitor terminated")
        let managedMonitor = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: MediaDownloadService.completionMonitorArguments(
                mediaExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
                successMarkerURL: terminatedMarker,
                attemptIdentifier: UUID(),
                mediaArguments: ["30"]
            ),
            environment: ProcessInfo.processInfo.environment,
            onStdout: { terminatedState.appendStdout($0) },
            onStderr: { terminatedState.appendStderr($0) },
            onTermination: { termination in
                terminatedState.recordTermination(termination)
                terminated.fulfill()
            }
        )
        try await Task.sleep(for: .milliseconds(100))
        managedMonitor.terminate(grace: 0.2)
        await fulfillment(of: [terminated], timeout: 3)
        XCTAssertFalse(terminatedState.snapshot.termination?.isSuccess ?? true)
        XCTAssertEqual(terminatedState.snapshot.termination?.exitCode, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: terminatedMarker.path))
    }

    func testDurableAtomicWriteDoesNotReplaceExistingJournal() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "HarborDurableExclusiveWrite-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let journalURL = root.appendingPathComponent("journal.json")
        let original = Data("original-journal".utf8)

        try DurableFileSystem.writeAtomicallyWithoutReplacing(
            original,
            to: journalURL
        )
        XCTAssertThrowsError(
            try DurableFileSystem.writeAtomicallyWithoutReplacing(
                Data("replacement-journal".utf8),
                to: journalURL
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), original)
        XCTAssertFalse(
            try fileManager.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix(".harbor-") && $0.hasSuffix(".tmp") }
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

    func testMediaRecoveryBarriersPersistAndDefaultSafelyForLegacyRecords() throws {
        let outputConflictIdentifier = UUID()
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .cancelled,
            requiresMediaRecoveryReset: true,
            mediaOutputConflictIdentifier: outputConflictIdentifier
        )
        let encoded = try JSONEncoder().encode(item.makeRecord())
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: encoded)
        XCTAssertTrue(decoded.requiresMediaRecoveryReset)
        XCTAssertEqual(decoded.mediaOutputConflictIdentifier, outputConflictIdentifier)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "requiresMediaRecoveryReset")
        legacyObject.removeValue(forKey: "mediaOutputConflictIdentifier")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyRecord = try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
        XCTAssertFalse(legacyRecord.requiresMediaRecoveryReset)
        XCTAssertNil(legacyRecord.mediaOutputConflictIdentifier)
    }

    func testStartupMediaCleanupKeepsBarrierWhenClearedStateCannotBeSaved() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected cleared-barrier save failure" }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborStartupMediaResetBarrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let suiteName = "HarborTests.StartupMediaResetBarrier.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let persistence = DownloadPersistence(
            directoryURL: root.appendingPathComponent("persistence")
        )
        let mediaItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .cancelled,
            progress: 0.5,
            bytesWritten: 50,
            expectedBytes: 100,
            requiresMediaRecoveryReset: true
        )
        try await persistence.save([mediaItem.makeRecord()])

        let cleanupCounter = AsyncTestCounter()
        let saveCounter = AsyncTestCounter()
        let firstCenter = DownloadCenter(
            settings: settings,
            persistence: persistence,
            mediaCleanupOperation: { _, _ in
                _ = await cleanupCounter.incrementAndGet()
            },
            torrentShutdownOperation: { _ in },
            recordSaveOperation: { persistence, records, revision in
                let call = await saveCounter.incrementAndGet()
                if call == 1 {
                    throw ExpectedSaveFailure()
                }
                try await persistence.save(records, revision: revision)
            }
        )

        await firstCenter.initializeIfNeeded()

        let firstRestoredItem = try XCTUnwrap(firstCenter.downloads.first)
        XCTAssertTrue(firstRestoredItem.requiresMediaRecoveryReset)
        XCTAssertEqual(firstRestoredItem.status, .cancelled)
        let firstCleanupCount = await cleanupCounter.currentValue()
        XCTAssertEqual(firstCleanupCount, 1)
        let recordsAfterFailedClear = try await persistence.load()
        XCTAssertTrue(try XCTUnwrap(recordsAfterFailedClear.first).requiresMediaRecoveryReset)
        let firstShutdownSucceeded = await firstCenter.shutdownForTermination()
        XCTAssertTrue(firstShutdownSucceeded)

        let secondCenter = DownloadCenter(
            settings: settings,
            persistence: persistence,
            mediaCleanupOperation: { _, _ in
                _ = await cleanupCounter.incrementAndGet()
            },
            torrentShutdownOperation: { _ in }
        )
        await secondCenter.initializeIfNeeded()

        let secondRestoredItem = try XCTUnwrap(secondCenter.downloads.first)
        XCTAssertFalse(secondRestoredItem.requiresMediaRecoveryReset)
        XCTAssertEqual(secondRestoredItem.status, .cancelled)
        let secondCleanupCount = await cleanupCounter.currentValue()
        XCTAssertEqual(secondCleanupCount, 2)
        let recordsAfterDurableClear = try await persistence.load()
        XCTAssertFalse(try XCTUnwrap(recordsAfterDurableClear.first).requiresMediaRecoveryReset)
        let secondShutdownSucceeded = await secondCenter.shutdownForTermination()
        XCTAssertTrue(secondShutdownSucceeded)
    }

    func testUnavailableExactMediaFormatHasDedicatedError() {
        XCTAssertEqual(
            MediaDownloadErrorClassifier.message(
                from: "ERROR: [youtube] Requested format is not available"
            ),
            MediaDownloadErrorClassifier.selectedFormatUnavailableMessage
        )
    }

    func testQuickLookRequiresCompletedExistingLocalFiles() throws {
        let suiteName = "HarborTests.QuickLook.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harbor-Quick-Look-\(UUID().uuidString).txt")
        try Data("Preview".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let previewService = FakeQuickLookPreviewService()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            quickLookPreviewService: previewService
        )
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/preview.torrent"),
            sourceKind: .torrentFile,
            fileLocationPath: fileURL.path
        )
        center.downloads = [item]
        center.selectedDownloadID = item.id

        XCTAssertTrue(center.canQuickLookSelectedDownloads)

        center.quickLookSelectedDownloads()

        XCTAssertEqual(previewService.previewedURLs, [fileURL])
        XCTAssertEqual(item.status, .completed)

        item.status = .paused
        XCTAssertFalse(center.canQuickLookSelectedDownloads)

        item.status = .completed
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertFalse(center.canQuickLookSelectedDownloads)

        center.quickLookSelectedDownloads()
        XCTAssertEqual(center.activeAlert?.title, "Quick Look Unavailable")
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

private final class ConcurrentMoveResults: @unchecked Sendable {
    struct Snapshot {
        let successfulIndices: [Int]
        let cocoaErrorCodes: [CocoaError.Code]
        let unexpectedErrors: [String]
    }

    private let lock = NSLock()
    private var successfulIndices: [Int] = []
    private var cocoaErrorCodes: [CocoaError.Code] = []
    private var unexpectedErrors: [String] = []

    func recordSuccess(_ index: Int) {
        lock.lock()
        successfulIndices.append(index)
        lock.unlock()
    }

    func recordCocoaError(_ code: CocoaError.Code) {
        lock.lock()
        cocoaErrorCodes.append(code)
        lock.unlock()
    }

    func recordUnexpectedError(_ error: Error) {
        lock.lock()
        unexpectedErrors.append(error.localizedDescription)
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            successfulIndices: successfulIndices,
            cocoaErrorCodes: cocoaErrorCodes,
            unexpectedErrors: unexpectedErrors
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

private actor AsyncTestCounter {
    private var value = 0

    func incrementAndGet() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int {
        value
    }
}

private nonisolated final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }
}

private nonisolated final class ManagedProcessTestState: @unchecked Sendable {
    struct Snapshot {
        let stdout: String
        let stderr: String
        let stdoutAtTermination: String
        let stderrAtTermination: String
        let termination: ManagedChildProcessTermination?
    }

    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""
    private var stdoutAtTermination = ""
    private var stderrAtTermination = ""
    private var termination: ManagedChildProcessTermination?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            stdout: stdout,
            stderr: stderr,
            stdoutAtTermination: stdoutAtTermination,
            stderrAtTermination: stderrAtTermination,
            termination: termination
        )
    }

    func appendStdout(_ output: String) {
        lock.lock()
        stdout += output
        lock.unlock()
    }

    func appendStderr(_ output: String) {
        lock.lock()
        stderr += output
        lock.unlock()
    }

    func recordTermination(_ value: ManagedChildProcessTermination) {
        lock.lock()
        stdoutAtTermination = stdout
        stderrAtTermination = stderr
        termination = value
        lock.unlock()
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

    func recordCompletion(_ handoff: CompletedDownloadHandoff) {
        lock.lock()
        storedCompletedURL = handoff.availablePayloadURL
        storedCompletedSuggestedFilename = handoff.manifest.suggestedFilename
        storedCompletedResponseMimeType = handoff.manifest.mimeType
        storedCompletedStatusCode = handoff.manifest.statusCode
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

private nonisolated final class KnownZeroOverflowURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private static var ranges: [String?] = []

    static var capturedRanges: [String?] {
        stateLock.withLock { ranges }
    }

    static func reset() {
        stateLock.withLock {
            ranges = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "known-zero.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let range = request.value(forHTTPHeaderField: "Range")
        let requestNumber = Self.stateLock.withLock { () -> Int in
            Self.ranges.append(range)
            return Self.ranges.count
        }

        if requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "0",
                    "Content-Encoding": "identity",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"zero-v1\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcde".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if range == "bytes=5-" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "0",
                    "Content-Range": "bytes */5",
                    "Content-Encoding": "identity",
                    "ETag": "\"zero-v1\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "3",
                "Content-Encoding": "identity",
                "Content-Type": "application/octet-stream",
                "ETag": "\"fresh-v2\""
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("xyz".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
    private static var shouldOmitValidatorOnFirstResume = false
    private static var shouldChangeValidatorOnFirstResume = false
    private static var shouldChangeTotalOnFirstResume = false
    private static var shouldFallbackToFullResponseOnFirstResume = false
    private static var shouldContradictSavedTotalOnFirstResume = false
    private static var shouldCompletePartialWithHTML416 = false
    private static var shouldCompletePartialWithoutValidator416 = false

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
        omitValidatorOnFirstResume: Bool = false,
        changeValidatorOnFirstResume: Bool = false,
        changeTotalOnFirstResume: Bool = false,
        fallbackToFullResponseOnFirstResume: Bool = false,
        contradictSavedTotalOnFirstResume: Bool = false,
        completePartialWithHTML416: Bool = false,
        completePartialWithoutValidator416: Bool = false
    ) {
        stateLock.lock()
        headers = []
        shouldRejectFirstResume = rejectFirstResume
        shouldShortenFirstResume = shortFirstResume
        shouldOverrunFirstResume = overlongFirstResume
        shouldUseUnknownTotalForFirstResume = unknownTotalFirstResume
        shouldOmitValidator = omitValidator
        shouldOmitValidatorOnFirstResume = omitValidatorOnFirstResume
        shouldChangeValidatorOnFirstResume = changeValidatorOnFirstResume
        shouldChangeTotalOnFirstResume = changeTotalOnFirstResume
        shouldFallbackToFullResponseOnFirstResume = fallbackToFullResponseOnFirstResume
        shouldContradictSavedTotalOnFirstResume = contradictSavedTotalOnFirstResume
        shouldCompletePartialWithHTML416 = completePartialWithHTML416
        shouldCompletePartialWithoutValidator416 = completePartialWithoutValidator416
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
        let omitValidatorOnFirstResume = Self.shouldOmitValidatorOnFirstResume
        let changeValidatorOnFirstResume = Self.shouldChangeValidatorOnFirstResume
        let changeTotalOnFirstResume = Self.shouldChangeTotalOnFirstResume
        let fallbackToFullResponseOnFirstResume = Self.shouldFallbackToFullResponseOnFirstResume
        let contradictSavedTotalOnFirstResume = Self.shouldContradictSavedTotalOnFirstResume
        let completePartialWithHTML416 = Self.shouldCompletePartialWithHTML416
        let completePartialWithoutValidator416 = Self.shouldCompletePartialWithoutValidator416
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

        if (overrunFirstResume || useUnknownTotalForFirstResume),
           range == nil,
           requestNumber == 3 {
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

        if omitValidatorOnFirstResume, range == nil, requestNumber == 3 {
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

        if completePartialWithoutValidator416, requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes */5",
                    "Content-Type": "application/octet-stream"
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

        if omitValidatorOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Range": "bytes 5-9/10",
                    "Content-Type": "application/octet-stream"
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

@MainActor
private final class FakeQuickLookPreviewService: QuickLookPreviewing {
    private(set) var previewedURLs: [URL] = []

    func preview(urls: [URL]) {
        previewedURLs = urls
    }
}
