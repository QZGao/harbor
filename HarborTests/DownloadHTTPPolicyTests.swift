import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
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
            try DownloadHTTPResponseValidator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 0,
                isResumeAttempt: false
            ),
            0
        )
        XCTAssertThrowsError(
            try DownloadHTTPResponseValidator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 1,
                isResumeAttempt: false
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
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [firstFailure], timeout: 2)

        let failure = try XCTUnwrap(eventState.firstFailure)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(failure.recoverableBytes, 0)
        XCTAssertTrue(failure.requiresFreshStart)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
        XCTAssertNil(eventState.completedURL)

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
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
            try DownloadHTTPResponseValidator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 10,
                isResumeAttempt: true
            ),
            10
        )
        XCTAssertThrowsError(
            try DownloadHTTPResponseValidator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 9,
                isResumeAttempt: true
            )
        )
        XCTAssertThrowsError(
            try DownloadHTTPResponseValidator.validatedBrowserCompletedByteCount(
                response: response,
                actualBytes: 10,
                isResumeAttempt: false
            )
        )
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
        browserCoordinator.discardOrphanedTemporaryFiles()

        XCTAssertFalse(fileManager.fileExists(atPath: directHandoff.path))
        XCTAssertFalse(fileManager.fileExists(atPath: browserHandoff.path))
        XCTAssertTrue(fileManager.fileExists(atPath: directUnrelated.path))
        XCTAssertTrue(fileManager.fileExists(atPath: browserUnrelated.path))
    }

    func testContentRangeParserRejectsMismatchedOrMalformedRanges() {
        XCTAssertEqual(
            DownloadHTTPResponseValidator.contentRange(from: "bytes 4096-8191/16384"),
            HTTPDownloadContentRange(start: 4_096, end: 8_191, total: 16_384)
        )
        XCTAssertNil(DownloadHTTPResponseValidator.contentRange(from: "items 1-2/3"))
        XCTAssertNil(DownloadHTTPResponseValidator.contentRange(from: "bytes 9-4/10"))
        XCTAssertNil(DownloadHTTPResponseValidator.contentRange(from: "bytes 5-7/not-a-number"))
        XCTAssertEqual(
            DownloadHTTPResponseValidator.unsatisfiedContentRangeTotal(from: "bytes */8192"),
            8_192
        )
    }
}
