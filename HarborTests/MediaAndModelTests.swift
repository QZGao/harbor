import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
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

}
