import Darwin
import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentLifecycleAndStorageTests: XCTestCase {
    func testPausedSeederWithoutBackendIdentifierCanStopSeeding() async {
        let suiteName = "HarborTests.SeedingLifecycle.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let persistenceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborSeedingLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceDirectoryURL) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceDirectoryURL)
        )
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .seeding,
            finishedAt: .now,
            backendIdentifier: nil,
            shouldSeedAfterDownload: true
        )
        center.downloads = [item]

        center.pauseDownloads(ids: [item.id])

        XCTAssertEqual(item.status, .paused)
        XCTAssertTrue(item.shouldSeedAfterDownload)
        XCTAssertNil(item.backendIdentifier)

        center.stopSeeding(id: item.id)

        XCTAssertEqual(item.status, .completed)
        XCTAssertFalse(item.shouldSeedAfterDownload)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.activityEvents.last?.kind, .seedingStopped)
        await center.shutdownForTermination()
    }

    func testPausedSeederIsNotCancellableAsAFreshDownload() async {
        let suiteName = "HarborTests.PausedSeederCancellation.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let persistenceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborPausedSeederTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceDirectoryURL) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceDirectoryURL)
        )
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            finishedAt: .now,
            backendIdentifier: nil,
            shouldSeedAfterDownload: true
        )
        center.downloads = [item]

        XCTAssertTrue(item.isPausedSeeder)
        XCTAssertFalse(center.canCancelDownloads(ids: [item.id]))

        center.cancelDownload(id: item.id)

        XCTAssertEqual(item.status, .completed)
        XCTAssertFalse(item.shouldSeedAfterDownload)
        await center.shutdownForTermination()
    }

    func testWatchedTorrentSourceIsTrashedOnlyAfterCompletion() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatchedCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let watchDirectoryURL = rootURL.appendingPathComponent("Watch", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        let applicationSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try fileManager.createDirectory(at: watchDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let key = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
        setenv(key, applicationSupportURL.path, 1)

        let suiteName = "HarborTests.WatchedCleanup.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        settings.removeWatchedTorrentAfterImport = true
        settings.torrentDestinationPath = rootURL.appendingPathComponent("Downloads", isDirectory: true).path

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: applicationSupportURL),
            managedTorrentSourceStore: store
        )
        let torrentURL = watchDirectoryURL.appendingPathComponent("watched.torrent")
        try Data("paused watched torrent".utf8).write(to: torrentURL)

        center.receiveWatchedTorrent(torrentURL)

        for _ in 0 ..< 40 {
            if center.downloads.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(center.downloads.count, 1)
        let item = try XCTUnwrap(center.downloads.first)
        XCTAssertEqual(item.status, .paused)
        XCTAssertTrue(fileManager.fileExists(atPath: torrentURL.path))

        await center.removeOriginalTorrentSourceAfterCompletionIfNeeded(item)

        XCTAssertTrue(fileManager.fileExists(atPath: torrentURL.path))

        item.status = .completed
        item.finishedAt = .now
        await center.removeOriginalTorrentSourceAfterCompletionIfNeeded(item)

        XCTAssertFalse(fileManager.fileExists(atPath: torrentURL.path))
        XCTAssertFalse(item.removeOriginalTorrentAfterImport)
    }

    func testPrepareLocalTorrentCreatesStableDeduplicatedManagedCopy() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborManagedTorrentTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectoryURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let data = Data("abc".utf8)
        let firstSourceURL = sourceDirectoryURL.appendingPathComponent("first.torrent")
        let secondSourceURL = sourceDirectoryURL.appendingPathComponent("second.torrent")
        try data.write(to: firstSourceURL)
        try data.write(to: secondSourceURL)

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let first = try await store.prepareLocalTorrent(at: firstSourceURL)
        let second = try await store.prepareLocalTorrent(at: secondSourceURL)
        let expectedFingerprint = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        XCTAssertEqual(first.fingerprint, expectedFingerprint)
        XCTAssertEqual(second.fingerprint, expectedFingerprint)
        XCTAssertEqual(first.originalURL, firstSourceURL)
        XCTAssertEqual(second.originalURL, secondSourceURL)
        XCTAssertEqual(first.managedURL, second.managedURL)
        XCTAssertEqual(
            first.managedURL,
            managedDirectoryURL.appendingPathComponent("\(expectedFingerprint).torrent")
        )
        XCTAssertEqual(try Data(contentsOf: first.managedURL), data)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(
                at: managedDirectoryURL,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testCleanupFingerprintRejectsReplacementAtSamePath() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("watched.torrent")
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        try Data("original torrent".utf8).write(to: sourceURL)
        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let managedSource = try await store.prepareLocalTorrent(at: sourceURL)

        let originalMatches = await store.torrent(
            at: sourceURL,
            matches: managedSource.fingerprint
        )
        XCTAssertTrue(originalMatches)

        try Data("replacement torrent".utf8).write(to: sourceURL, options: .atomic)

        let replacementMatches = await store.torrent(
            at: sourceURL,
            matches: managedSource.fingerprint
        )
        XCTAssertFalse(replacementMatches)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("replacement torrent".utf8))
    }

    func testApplicationSupportDirectoryHonorsEnvironmentOverride() {
        let key = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }

        let overrideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborApplicationSupportTests-\(UUID().uuidString)", isDirectory: true)
        setenv(key, overrideURL.path, 1)

        XCTAssertEqual(
            HarborApplicationSupport.directoryURL().standardizedFileURL,
            overrideURL.appendingPathComponent("Harbor", isDirectory: true).standardizedFileURL
        )
    }

    func testSessionRecoveryRequiresCorruptionSignal() {
        XCTAssertTrue(
            Aria2TorrentService.shouldRecoverSession(
                from: "ERROR Unrecognized URI or unsupported protocol: broken session row"
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.shouldRecoverSession(
                from: "Failed to parse aria2 session"
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.shouldRecoverSession(
                from: "Address already in use while opening RPC port"
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.shouldRecoverSession(
                from: "Timed out waiting for network connectivity"
            )
        )
    }

    func testRestorePolicyPreservesPausedIntentAndOnlyRestartsActiveSeeder() {
        XCTAssertTrue(
            DownloadCenter.shouldPauseRestoredTorrent(
                persistedStatus: .paused,
                engineStatus: "active"
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldPauseRestoredTorrent(
                persistedStatus: .seeding,
                engineStatus: "active"
            )
        )
        XCTAssertTrue(
            DownloadCenter.shouldRestartStaleSeeder(
                persistedStatus: .seeding,
                hasFinishedData: true,
                shouldSeed: true
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRestartStaleSeeder(
                persistedStatus: .paused,
                hasFinishedData: true,
                shouldSeed: true
            )
        )
    }

    func testMagnetMetadataCompletionWaitsForAria2FollowedPayload() {
        let metadataSnapshot = TorrentStatusSnapshot(
            gid: "metadata-gid",
            status: "complete",
            totalLength: 21_167,
            completedLength: 21_167,
            downloadSpeed: 0,
            uploadSpeed: 0,
            isSeeder: false,
            infoHash: "c8b32b9552e94fba03b8b2a8041e0593649fb4a1",
            errorMessage: nil,
            metadataName: "Example Torrent",
            filePaths: ["[METADATA]Example Torrent"],
            primaryPath: "[METADATA]Example Torrent",
            followedBy: ["payload-gid"],
            following: nil
        )
        let metadataLineage = TorrentStatusLineage(
            rootGID: "metadata-gid",
            gids: ["metadata-gid"],
            currentSnapshot: metadataSnapshot
        )

        XCTAssertTrue(metadataSnapshot.isMetadataDownload)
        XCTAssertTrue(
            DownloadCenter.shouldAwaitMagnetPayload(
                sourceKind: .magnetLink,
                lineage: metadataLineage
            )
        )

        let payloadSnapshot = TorrentStatusSnapshot(
            gid: "payload-gid",
            status: "active",
            totalLength: 4_199_224_677,
            completedLength: 1_048_576,
            downloadSpeed: 512_000,
            uploadSpeed: 0,
            isSeeder: false,
            infoHash: "c8b32b9552e94fba03b8b2a8041e0593649fb4a1",
            errorMessage: nil,
            metadataName: "Example Torrent",
            filePaths: ["/Downloads/example.mkv"],
            primaryPath: "/Downloads/example.mkv",
            followedBy: [],
            following: "metadata-gid"
        )
        let payloadLineage = TorrentStatusLineage(
            rootGID: "metadata-gid",
            gids: ["metadata-gid", "payload-gid"],
            currentSnapshot: payloadSnapshot
        )

        XCTAssertFalse(payloadSnapshot.isMetadataDownload)
        XCTAssertFalse(
            DownloadCenter.shouldAwaitMagnetPayload(
                sourceKind: .magnetLink,
                lineage: payloadLineage
            )
        )
        XCTAssertEqual(payloadLineage.currentSnapshot.gid, "payload-gid")
        XCTAssertEqual(payloadLineage.currentSnapshot.following, "metadata-gid")
    }

    func testRestoredMagnetLineageDoesNotTreatPayloadChildAsOrphan() {
        let orphans = DownloadCenter.orphanedTorrentGIDs(
            engineGIDs: ["metadata-gid", "payload-gid", "untracked-gid"],
            retainedGIDs: ["metadata-gid", "payload-gid"]
        )

        XCTAssertEqual(orphans, ["untracked-gid"])
    }

    func testMetadataOnlyCompletedMagnetIsEligibleForRepair() {
        XCTAssertTrue(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .magnetLink,
                status: .completed,
                fileLocationPath: "[METADATA]Example Torrent",
                payloadPaths: []
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .magnetLink,
                status: .completed,
                fileLocationPath: "/Downloads/example.mkv",
                payloadPaths: []
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .torrentFile,
                status: .completed,
                fileLocationPath: "[METADATA]Example Torrent",
                payloadPaths: []
            )
        )
    }
}
