import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
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
}
