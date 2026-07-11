import Darwin
import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentLifecycleAndStorageTests: XCTestCase {
    func testPausedSeederWithoutBackendIdentifierCanStopSeeding() {
        let suiteName = "HarborTests.SeedingLifecycle.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let center = DownloadCenter(settings: AppSettingsStore(userDefaults: userDefaults))
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
    }

    func testPausedSeederIsNotCancellableAsAFreshDownload() {
        let suiteName = "HarborTests.PausedSeederCancellation.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let center = DownloadCenter(settings: AppSettingsStore(userDefaults: userDefaults))
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
    }

    func testWatchedTorrentSourceIsTrashedWhileImportRemainsPaused() async throws {
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
            managedTorrentSourceStore: store
        )
        let torrentURL = watchDirectoryURL.appendingPathComponent("watched.torrent")
        try Data("paused watched torrent".utf8).write(to: torrentURL)

        center.receiveWatchedTorrent(torrentURL)

        for _ in 0 ..< 40 {
            if center.downloads.count == 1,
               fileManager.fileExists(atPath: torrentURL.path) == false {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(center.downloads.count, 1)
        XCTAssertEqual(center.downloads.first?.status, .paused)
        XCTAssertFalse(fileManager.fileExists(atPath: torrentURL.path))
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
}
