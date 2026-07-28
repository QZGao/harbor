import Foundation
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
            formatPreference: .original,
            speedLimitBytesPerSecond: 345_678
        )
        let unlimitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .original,
            speedLimitBytesPerSecond: nil
        )

        let limitIndex = try XCTUnwrap(limitedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(limitedArguments[limitedArguments.index(after: limitIndex)], "345678")
        XCTAssertFalse(unlimitedArguments.contains("--limit-rate"))
        XCTAssertFalse(limitedArguments.contains("--format"))
        XCTAssertFalse(unlimitedArguments.contains("--format"))

        let format = MediaDownloadFormatOption(
            formatID: "137",
            audioFormatID: "140",
            container: "mp4",
            videoCodec: "avc1.640028",
            audioCodec: "mp4a.40.2",
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            dynamicRange: "SDR",
            bitrateKbps: 4_500,
            estimatedBytes: 10_000_000,
            mergeOutputFormat: "mp4"
        )
        let metadata = MediaDownloadMetadata(
            title: "Video",
            platform: "Test",
            extractorKey: "Test",
            thumbnailURL: nil,
            webpageURL: sourceURL,
            expectedBytes: format.estimatedBytes,
            mediaType: .video,
            entryCount: 1,
            capabilities: MediaDownloadCapabilities(formatOptions: [format])
        )
        let selectedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: metadata,
            formatPreference: .specific(format.id),
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

        XCTAssertThrowsError(
            try MediaDownloadService.downloadArguments(
                runtime: runtime,
                sourceURL: sourceURL,
                destinationFolder: destinationURL,
                temporaryFolder: temporaryURL,
                metadata: metadata,
                formatPreference: .specific("unavailable-format"),
                speedLimitBytesPerSecond: nil
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The selected media format is no longer available."
            )
        }
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
