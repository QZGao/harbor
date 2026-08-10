import Foundation
import Darwin
import OSLog

enum TorrentEngineError: LocalizedError {
    case binaryNotFound
    case startupFailed(String)
    case invalidSource
    case invalidResponse
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Torrent support requires aria2c. \(Aria2BinaryResolver.installHint)"
        case let .startupFailed(message):
            "Couldn’t start the torrent engine. \(message)"
        case .invalidSource:
            "This download source isn’t valid for the torrent engine."
        case .invalidResponse:
            "The torrent engine returned an invalid response."
        case let .rpc(message):
            message
        }
    }
}

struct TorrentStatusSnapshot: Sendable {
    let gid: String
    let status: String
    let totalLength: Int64
    let completedLength: Int64
    let downloadSpeed: Double
    let uploadSpeed: Double
    let isSeeder: Bool
    let infoHash: String?
    let errorMessage: String?
    let metadataName: String?
    let filePaths: [String]
    let primaryPath: String?
    let followedBy: [String]
    let following: String?

    nonisolated var isMetadataDownload: Bool {
        filePaths.contains { path in
            URL(fileURLWithPath: path).lastPathComponent.hasPrefix("[METADATA]")
        }
    }
}

struct TorrentStatusLineage: Sendable {
    let rootGID: String
    let gids: [String]
    let currentSnapshot: TorrentStatusSnapshot

    nonisolated var isMetadataOnly: Bool {
        gids.count == 1 && currentSnapshot.isMetadataDownload
    }
}

struct TorrentTransferOptions: Equatable, Sendable {
    let downloadLimitBytesPerSecond: Int64?
    let uploadLimitBytesPerSecond: Int64?
    let shouldSeed: Bool
    let verifyExistingData: Bool

    init(
        downloadLimitBytesPerSecond: Int64?,
        uploadLimitBytesPerSecond: Int64?,
        shouldSeed: Bool,
        verifyExistingData: Bool = false
    ) {
        self.downloadLimitBytesPerSecond = downloadLimitBytesPerSecond
        self.uploadLimitBytesPerSecond = uploadLimitBytesPerSecond
        self.shouldSeed = shouldSeed
        self.verifyExistingData = verifyExistingData
    }
}

private final class TorrentEngineLogBuffer: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var output = ""

    nonisolated init() {}

    nonisolated func reset() {
        lock.lock()
        output = ""
        lock.unlock()
    }

    nonisolated func append(_ value: String) {
        lock.lock()
        output.append(value)
        output.append("\n")
        lock.unlock()
    }

    nonisolated func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

actor Aria2TorrentService {
    nonisolated static let recoveryOptions = [
        "continue": "true",
        "max-tries": "10",
        "retry-wait": "5",
        "bt-stop-timeout": "0"
    ]

    private struct RPCEnvelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: RPCFailure?
    }

    private struct RPCFailure: Decodable {
        let code: Int
        let message: String
    }

    private struct VersionPayload: Decodable {
        let version: String
    }

    private struct GIDPayload: Decodable {
        let gid: String
    }

    private struct StatusPayload: Decodable {
        let gid: String
        let status: String
        let totalLength: String?
        let completedLength: String?
        let downloadSpeed: String?
        let uploadSpeed: String?
        let seeder: String?
        let infoHash: String?
        let errorMessage: String?
        let files: [FilePayload]?
        let bittorrent: BittorrentPayload?
        let followedBy: [String]?
        let following: String?
    }

    private struct FilePayload: Decodable {
        let path: String?
        let selected: String?
    }

    private struct BittorrentPayload: Decodable {
        let info: InfoPayload?
    }

    private struct InfoPayload: Decodable {
        let name: String?
    }

    private struct RunningDaemon {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
    }

    nonisolated private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Harbor",
        category: "TorrentEngine"
    )

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    private var process: Process?
    private var rpcPort: Int?
    private var rpcSecret: String?
    private var stderrPipe: Pipe?
    private let startupLogBuffer = TorrentEngineLogBuffer()
    private var transferSettings: DownloadTransferSettings
    private var isRetryingAfterSessionRecovery = false

    init(transferSettings: DownloadTransferSettings = .default) {
        self.transferSettings = transferSettings
    }

    deinit {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            terminateDaemonProcess(process)
        }
    }

    func resolvedBinaryPath() -> String? {
        Aria2BinaryResolver.resolveBinaryURL()?.path
    }

    func updateTransferSettings(
        _ transferSettings: DownloadTransferSettings,
        activeGIDs: [String],
        transferOptionsByGID: [String: TorrentTransferOptions] = [:]
    ) async {
        self.transferSettings = transferSettings

        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            return
        }

        do {
            try await applyGlobalOptions(transferSettings)

            for rootGID in activeGIDs {
                let lineage = try? await followedStatus(for: rootGID)
                let gid = lineage?.currentSnapshot.gid ?? rootGID
                try? await applyDownloadOptions(
                    transferSettings,
                    transferOptions: transferOptionsByGID[rootGID],
                    gid: gid
                )
            }

            await persistSessionAfterMutation("transfer settings update")
        } catch {
            logger.warning("Failed to update aria2 transfer settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveSession() async throws {
        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            return
        }

        _ = try await rpcCall(method: "aria2.saveSession", params: [
            authorizedToken()
        ], as: String.self)
    }

    func allKnownGIDs() async throws -> Set<String> {
        try await ensureDaemonRunning()
        let token = try authorizedToken()
        let active = try await rpcCall(
            method: "aria2.tellActive",
            params: [token, ["gid"]],
            as: [GIDPayload].self
        )
        let waiting = try await rpcCall(
            method: "aria2.tellWaiting",
            params: [token, 0, 1_000, ["gid"]],
            as: [GIDPayload].self
        )
        let stopped = try await rpcCall(
            method: "aria2.tellStopped",
            params: [token, 0, 1_000, ["gid"]],
            as: [GIDPayload].self
        )

        return Set((active + waiting + stopped).map(\.gid))
    }

    func shutdown() async {
        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            resetDaemon(terminateIfRunning: process?.isRunning == true)
            return
        }

        do {
            try await saveSession()
            _ = try await rpcCall(method: "aria2.shutdown", params: [
                authorizedToken()
            ], as: String.self)

            for _ in 0 ..< 20 where process?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            logger.warning("Failed to gracefully shut down aria2: \(error.localizedDescription, privacy: .public)")
        }

        resetDaemon(terminateIfRunning: process?.isRunning == true)
    }

    func addDownload(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        destinationFolderPath: String,
        transferOptions: TorrentTransferOptions? = nil
    ) async throws -> String {
        logger.info("Starting torrent add request for source kind \(String(describing: sourceKind), privacy: .public)")
        try await ensureDaemonRunning()

        let options = downloadOptions(
            destinationFolderPath: destinationFolderPath,
            transferOptions: transferOptions
        )

        switch sourceKind {
        case .magnetLink:
            let gid = try await rpcCallWithDaemonRestart(
                method: "aria2.addUri",
                params: {
                    [
                        try authorizedToken(),
                        [sourceURL.absoluteString],
                        options
                    ]
                },
                as: String.self
            )
            logger.info("aria2 accepted magnet download with gid \(gid, privacy: .public)")
            await persistSessionAfterMutation("magnet add")
            return gid
        case .torrentFile:
            let torrentData = try Data(contentsOf: sourceURL)
            let gid = try await rpcCallWithDaemonRestart(
                method: "aria2.addTorrent",
                params: {
                    [
                        try authorizedToken(),
                        torrentData.base64EncodedString(),
                        [],
                        options
                    ]
                },
                as: String.self
            )
            logger.info("aria2 accepted torrent file with gid \(gid, privacy: .public)")
            await persistSessionAfterMutation("torrent add")
            return gid
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }
    }

    func pause(gid: String) async throws {
        let lineage = try await followedStatus(for: gid)
        let currentGID = lineage.currentSnapshot.gid
        _ = try await rpcCallWithDaemonRestart(
            method: "aria2.forcePause",
            params: {
                [
                    try authorizedToken(),
                    currentGID
                ]
            },
            as: String.self
        )
        await persistSessionAfterMutation("pause")
    }

    func unpause(gid: String) async throws {
        let lineage = try await followedStatus(for: gid)
        let currentGID = lineage.currentSnapshot.gid
        _ = try await rpcCallWithDaemonRestart(
            method: "aria2.unpause",
            params: {
                [
                    try authorizedToken(),
                    currentGID
                ]
            },
            as: String.self
        )
        await persistSessionAfterMutation("unpause")
    }

    func remove(gid: String) async {
        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil,
              let token = try? authorizedToken() else {
            return
        }

        let lineage = try? await followedStatus(for: gid)
        let gids = lineage?.gids.reversed() ?? [gid].reversed()
        var didRemove = false

        for targetGID in gids {
            didRemove = await removeSingle(gid: targetGID, token: token) || didRemove
        }

        if didRemove {
            await persistSessionAfterMutation("remove")
        }
    }

    func removeAndConfirmStopped(gid: String) async throws {
        try await ensureDaemonRunning()
        let token = try authorizedToken()
        let lineage = try? await followedStatus(for: gid)
        let gids = lineage?.gids.reversed() ?? [gid].reversed()

        for targetGID in gids {
            try await removeSingleAndConfirmStopped(gid: targetGID, token: token)
        }

        await persistSessionAfterMutation("confirmed remove")
    }

    private func removeSingle(gid: String, token: String) async -> Bool {
        var didRemove = false

        do {
            _ = try await rpcCall(method: "aria2.forceRemove", params: [
                token,
                gid
            ], as: String.self)
            didRemove = true
        } catch {
            logger.debug("aria2 forceRemove did not remove gid \(gid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        do {
            _ = try await rpcCall(method: "aria2.removeDownloadResult", params: [
                token,
                gid
            ], as: String.self)
            didRemove = true
        } catch {
            logger.debug("aria2 removeDownloadResult did not remove gid \(gid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return didRemove
    }

    private func removeSingleAndConfirmStopped(gid: String, token: String) async throws {
        do {
            _ = try await rpcCall(method: "aria2.forceRemove", params: [
                token,
                gid
            ], as: String.self)
        } catch {
            do {
                let snapshot = try await status(for: gid)
                if snapshot.status == "active"
                    || snapshot.status == "waiting"
                    || snapshot.status == "paused" {
                    throw error
                }
            } catch let statusError {
                guard isMissingGIDError(statusError) else {
                    throw statusError
                }
            }
        }

        do {
            _ = try await rpcCall(method: "aria2.removeDownloadResult", params: [
                token,
                gid
            ], as: String.self)
        } catch {
            guard isMissingGIDError(error) else {
                throw error
            }
        }
    }

    func status(for gid: String) async throws -> TorrentStatusSnapshot {
        let payload = try await rpcCallWithDaemonRestart(
            method: "aria2.tellStatus",
            params: {
                [
                    try authorizedToken(),
                    gid,
                    [
                        "gid",
                        "status",
                        "totalLength",
                        "completedLength",
                        "downloadSpeed",
                        "uploadSpeed",
                        "seeder",
                        "infoHash",
                        "errorMessage",
                        "files",
                        "bittorrent",
                        "followedBy",
                        "following"
                    ]
                ]
            },
            as: StatusPayload.self
        )

        let filePaths = payload.files?
            .compactMap(\.path)
            .filter { $0.isEmpty == false } ?? []

        return TorrentStatusSnapshot(
            gid: payload.gid,
            status: payload.status,
            totalLength: Int64(payload.totalLength ?? "") ?? 0,
            completedLength: Int64(payload.completedLength ?? "") ?? 0,
            downloadSpeed: Double(payload.downloadSpeed ?? "") ?? 0,
            uploadSpeed: Double(payload.uploadSpeed ?? "") ?? 0,
            isSeeder: payload.seeder == "true",
            infoHash: payload.infoHash,
            errorMessage: payload.errorMessage,
            metadataName: payload.bittorrent?.info?.name,
            filePaths: filePaths,
            primaryPath: preferredPath(from: filePaths),
            followedBy: payload.followedBy ?? [],
            following: payload.following
        )
    }

    func followedStatus(for rootGID: String) async throws -> TorrentStatusLineage {
        var gids = [rootGID]
        var visited = Set(gids)
        var snapshot = try await status(for: rootGID)

        while let nextGID = snapshot.followedBy.first(where: { visited.contains($0) == false }) {
            do {
                snapshot = try await status(for: nextGID)
                gids.append(nextGID)
                visited.insert(nextGID)
            } catch {
                guard isMissingGIDError(error) else {
                    throw error
                }
                break
            }
        }

        return TorrentStatusLineage(
            rootGID: rootGID,
            gids: gids,
            currentSnapshot: snapshot
        )
    }

    private func ensureDaemonRunning() async throws {
        if let process, process.isRunning, rpcPort != nil, rpcSecret != nil {
            return
        }

        if process != nil || rpcPort != nil || rpcSecret != nil || stderrPipe != nil {
            resetDaemon(terminateIfRunning: process?.isRunning == true)
        }

        guard let binaryURL = Aria2BinaryResolver.resolveBinaryURL() else {
            throw TorrentEngineError.binaryNotFound
        }

        terminateOrphanedDaemons(matching: binaryURL)
        logger.info("Launching aria2 from \(binaryURL.path, privacy: .public)")

        let port = Int.random(in: 18_000 ... 28_000)
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sessionFileURL = try prepareSessionFile()

        var arguments = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            "--input-file=\(sessionFileURL.path)",
            "--save-session=\(sessionFileURL.path)",
            "--save-session-interval=5",
            "--force-save=true",
            "--bt-detach-seed-only=true",
            // TODO: Replace indefinite seeding with per-torrent ratio/time policies when Harbor exposes those controls.
            "--seed-ratio=0.0",
            "--bt-save-metadata=true",
            "--bt-load-saved-metadata=true",
            "--follow-torrent=true",
            "--allow-overwrite=false",
            "--auto-file-renaming=true"
        ]
        let recoveryArguments = Self.recoveryOptions
            .sorted { $0.key < $1.key }
            .map { "--\($0.key)=\($0.value)" }
        arguments.append(contentsOf: recoveryArguments)
        arguments.append(contentsOf: [
            "--summary-interval=0",
            "--max-concurrent-downloads=\(transferSettings.maxConcurrentDownloads)",
            "--max-overall-download-limit=\(Self.aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond))",
            "--max-overall-upload-limit=\(Self.aria2LimitString(transferSettings.globalUploadSpeedLimitBytesPerSecond))",
            "--max-download-limit=\(Self.aria2LimitString(transferSettings.perDownloadSpeedLimitBytesPerSecond))",
            "--max-upload-limit=\(Self.aria2LimitString(transferSettings.perDownloadUploadSpeedLimitBytesPerSecond))",
            "--max-connection-per-server=\(transferSettings.perDownloadConnectionCount)",
            "--split=\(transferSettings.perDownloadConnectionCount)",
            "--check-certificate=true",
            "--console-log-level=notice"
        ])

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        startupLogBuffer.reset()
        let stderrPipe = Pipe()
        process.standardOutput = stderrPipe
        process.standardError = stderrPipe
        installReadabilityHandler(for: stderrPipe)

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch aria2: \(error.localizedDescription, privacy: .public)")
            throw TorrentEngineError.startupFailed(error.localizedDescription)
        }

        self.process = process
        self.rpcPort = port
        self.rpcSecret = secret
        self.stderrPipe = stderrPipe
        logger.info("aria2 process started on RPC port \(port, privacy: .public)")

        for _ in 0 ..< 20 {
            if process.isRunning == false {
                logger.error("aria2 exited before RPC became available")
                resetDaemon(terminateIfRunning: false)
                if try recoverCorruptSessionIfPossible(
                    at: sessionFileURL,
                    startupOutput: startupLogBuffer.snapshot()
                ) {
                    try await ensureDaemonRunning()
                    return
                }
                throw TorrentEngineError.startupFailed("aria2c exited before opening RPC.")
            }

            do {
                _ = try await rpcCall(method: "aria2.getVersion", params: [
                    authorizedToken()
                ], as: VersionPayload.self)
                try await applyGlobalOptions(transferSettings)
                isRetryingAfterSessionRecovery = false
                logger.info("aria2 RPC is ready")
                return
            } catch {
                logger.debug("aria2 RPC not ready yet: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        logger.error("Timed out waiting for aria2 RPC readiness")
        resetDaemon(terminateIfRunning: true)
        if try recoverCorruptSessionIfPossible(
            at: sessionFileURL,
            startupOutput: startupLogBuffer.snapshot()
        ) {
            try await ensureDaemonRunning()
            return
        }
        throw TorrentEngineError.startupFailed("Timed out waiting for aria2 RPC.")
    }

    private func recoverCorruptSessionIfPossible(
        at sessionFileURL: URL,
        startupOutput: String
    ) throws -> Bool {
        guard isRetryingAfterSessionRecovery == false,
              Self.shouldRecoverSession(from: startupOutput),
              let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return false
        }

        isRetryingAfterSessionRecovery = true
        let quarantineURL = sessionFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("aria2.session.corrupt-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sessionFileURL, to: quarantineURL)
        guard FileManager.default.createFile(atPath: sessionFileURL.path, contents: Data()) else {
            throw TorrentEngineError.startupFailed(
                String(
                    localized: "torrent.session.fileRecreationFailed",
                    defaultValue: "Couldn’t recreate the torrent session file.",
                    comment: "Torrent engine startup detail shown when a corrupt session file cannot be replaced."
                )
            )
        }
        logger.warning("Recovered from an unreadable aria2 session file")
        return true
    }

    nonisolated static func shouldRecoverSession(from startupOutput: String) -> Bool {
        let output = startupOutput.lowercased()
        return output.contains("unrecognized uri or unsupported protocol")
            || output.contains("failed to parse")
            || output.contains("parse error")
            || output.contains("error while loading session")
            || output.contains("failed to load session")
    }

    private func rpcURL() throws -> URL {
        guard let rpcPort else {
            throw TorrentEngineError.invalidResponse
        }

        return URL(string: "http://127.0.0.1:\(rpcPort)/jsonrpc")!
    }

    private func authorizedToken() throws -> String {
        guard let rpcSecret else {
            throw TorrentEngineError.invalidResponse
        }

        return "token:\(rpcSecret)"
    }

    private func prepareSessionFile() throws -> URL {
        let fileManager = FileManager.default
        let harborDirectoryURL = HarborApplicationSupport.directoryURL(fileManager: fileManager)
        let sessionFileURL = harborDirectoryURL.appendingPathComponent(
            "aria2.session",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: harborDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw TorrentEngineError.startupFailed(
                String(
                    format: String(
                        localized: "torrent.session.directoryCreationFailed",
                        defaultValue: "Couldn’t create the torrent session directory: %@",
                        comment: "Torrent engine startup detail shown when its session directory cannot be created."
                    ),
                    error.localizedDescription
                )
            )
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sessionFileURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue == false else {
                throw TorrentEngineError.startupFailed(
                    String(
                        localized: "torrent.session.pathIsDirectory",
                        defaultValue: "The torrent session path is a directory.",
                        comment: "Torrent engine startup detail shown when the session file path is occupied by a directory."
                    )
                )
            }
        } else if fileManager.createFile(atPath: sessionFileURL.path, contents: Data()) == false {
            throw TorrentEngineError.startupFailed(
                String(
                    localized: "torrent.session.fileCreationFailed",
                    defaultValue: "Couldn’t create the torrent session file.",
                    comment: "Torrent engine startup detail shown when its session file cannot be created."
                )
            )
        }

        return sessionFileURL
    }

    private func downloadOptions(
        destinationFolderPath: String,
        transferOptions: TorrentTransferOptions?
    ) -> [String: String] {
        var options = [
            "dir": destinationFolderPath,
            "pause": "false"
        ]

        Self.recoveryOptions.forEach { key, value in
            options[key] = value
        }

        Self.perDownloadOptions(
            transferSettings,
            transferOptions: transferOptions
        ).forEach { key, value in
            options[key] = value
        }

        if transferOptions?.verifyExistingData == true {
            options["check-integrity"] = "true"
            options["bt-hash-check-seed"] = "true"
            options["auto-file-renaming"] = "false"
        }

        return options
    }

    private func globalOptions(_ transferSettings: DownloadTransferSettings) -> [String: String] {
        [
            "max-concurrent-downloads": "\(transferSettings.maxConcurrentDownloads)",
            "max-overall-download-limit": Self.aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond),
            "max-overall-upload-limit": Self.aria2LimitString(transferSettings.globalUploadSpeedLimitBytesPerSecond)
        ]
    }

    nonisolated static func perDownloadOptions(
        _ transferSettings: DownloadTransferSettings,
        transferOptions: TorrentTransferOptions?
    ) -> [String: String] {
        let downloadLimit: Int64?
        let uploadLimit: Int64?

        if let transferOptions {
            downloadLimit = transferOptions.downloadLimitBytesPerSecond
            uploadLimit = transferOptions.uploadLimitBytesPerSecond
        } else {
            downloadLimit = transferSettings.perDownloadSpeedLimitBytesPerSecond
            uploadLimit = transferSettings.perDownloadUploadSpeedLimitBytesPerSecond
        }

        var options = [
            "max-download-limit": aria2LimitString(downloadLimit),
            "max-upload-limit": aria2LimitString(uploadLimit),
            "max-connection-per-server": "\(transferSettings.perDownloadConnectionCount)",
            "split": "\(transferSettings.perDownloadConnectionCount)"
        ]

        if let transferOptions {
            if transferOptions.shouldSeed {
                options["seed-ratio"] = "0.0"
            } else {
                options["seed-time"] = "0"
            }

        }

        return options
    }

    private func applyGlobalOptions(_ transferSettings: DownloadTransferSettings) async throws {
        _ = try await rpcCall(method: "aria2.changeGlobalOption", params: [
            authorizedToken(),
            globalOptions(transferSettings)
        ], as: String.self)
    }

    private func applyDownloadOptions(
        _ transferSettings: DownloadTransferSettings,
        transferOptions: TorrentTransferOptions?,
        gid: String
    ) async throws {
        _ = try await rpcCall(method: "aria2.changeOption", params: [
            authorizedToken(),
            gid,
            Self.perDownloadOptions(
                transferSettings,
                transferOptions: transferOptions
            )
        ], as: String.self)
    }

    private func persistSessionAfterMutation(_ action: String) async {
        do {
            try await saveSession()
        } catch {
            logger.warning("Failed to save aria2 session after \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func aria2LimitString(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else {
            return "0"
        }

        return "\(max(bytesPerSecond, 0))"
    }

    private func isMissingGIDError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("gid")
            && (message.contains("not found")
                || message.contains("does not exist")
                || message.contains("cannot be found"))
    }

    private func rpcCallWithDaemonRestart<Result: Decodable>(
        method: String,
        params makeParams: () throws -> [Any],
        as type: Result.Type
    ) async throws -> Result {
        try await ensureDaemonRunning()

        do {
            return try await rpcCall(method: method, params: try makeParams(), as: type)
        } catch {
            guard shouldRestartDaemon(after: error) else {
                throw error
            }

            logger.warning("Restarting aria2 after RPC failure: \(error.localizedDescription, privacy: .public)")
            resetDaemon(terminateIfRunning: true)
            try await ensureDaemonRunning()
            return try await rpcCall(method: method, params: try makeParams(), as: type)
        }
    }

    private func rpcCall<Result: Decodable>(
        method: String,
        params: [Any],
        as type: Result.Type
    ) async throws -> Result {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]

        var request = URLRequest(url: try rpcURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5

        let (data, _) = try await session.data(for: request)
        let envelope = try JSONDecoder().decode(RPCEnvelope<Result>.self, from: data)

        if let error = envelope.error {
            throw TorrentEngineError.rpc(error.message)
        }

        guard let result = envelope.result else {
            throw TorrentEngineError.invalidResponse
        }

        return result
    }

    private func shouldRestartDaemon(after error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .networkConnectionLost,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        if case TorrentEngineError.invalidResponse = error {
            return true
        }

        return false
    }

    private func resetDaemon(terminateIfRunning: Bool) {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if terminateIfRunning,
           let process,
           process.isRunning {
            terminateDaemonProcess(process)
        }

        process = nil
        rpcPort = nil
        rpcSecret = nil
        stderrPipe = nil
    }

    private nonisolated func terminateDaemonProcess(_ process: Process) {
        process.terminate()

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            logger.warning("Force killing aria2 daemon with pid \(process.processIdentifier, privacy: .public)")
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private func terminateOrphanedDaemons(matching binaryURL: URL) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let binaryPath = binaryURL.path

        for daemon in runningDaemons(matching: binaryPath) {
            guard daemon.parentPID == 1,
                  daemon.pid != currentPID,
                  process?.processIdentifier != daemon.pid else {
                continue
            }

            logger.warning("Terminating orphaned aria2 daemon with pid \(daemon.pid, privacy: .public)")
            _ = kill(daemon.pid, SIGTERM)
        }
    }

    private func runningDaemons(matching binaryPath: String) -> [RunningDaemon] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.warning("Could not inspect aria2 processes: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                daemon(from: String(line), binaryPath: binaryPath)
            }
    }

    private func daemon(from processLine: String, binaryPath: String) -> RunningDaemon? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)

        guard parts.count == 3,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]) else {
            return nil
        }

        let command = String(parts[2])
        guard command.contains("--enable-rpc=true"),
              isHarborManagedDaemon(command: command, binaryPath: binaryPath) else {
            return nil
        }

        // TODO: Replace process-list cleanup with a persisted daemon lock if Harbor later supports multiple concurrent app instances.
        return RunningDaemon(pid: pid, parentPID: parentPID, command: command)
    }

    private func isHarborManagedDaemon(command: String, binaryPath: String) -> Bool {
        command.hasPrefix(binaryPath)
            || (
                command.contains("/Harbor.app/Contents/Resources/TorrentRuntime/")
                    && command.contains("/bin/aria2c")
            )
    }

    private nonisolated func installReadabilityHandler(for pipe: Pipe) {
        let logger = self.logger
        let startupLogBuffer = self.startupLogBuffer
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  output.isEmpty == false else {
                return
            }

            startupLogBuffer.append(output)
            logger.notice("aria2: \(output, privacy: .public)")
        }
    }

    private func preferredPath(from filePaths: [String]) -> String? {
        guard filePaths.isEmpty == false else {
            return nil
        }

        if filePaths.count == 1 {
            return filePaths[0]
        }

        let splitComponents = filePaths.map {
            URL(fileURLWithPath: $0).pathComponents
        }

        guard var sharedComponents = splitComponents.first else {
            return filePaths[0]
        }

        for components in splitComponents.dropFirst() {
            while sharedComponents.isEmpty == false,
                  components.starts(with: sharedComponents) == false {
                sharedComponents.removeLast()
            }
        }

        guard sharedComponents.isEmpty == false else {
            return URL(fileURLWithPath: filePaths[0]).deletingLastPathComponent().path
        }

        let commonPath = NSString.path(withComponents: sharedComponents)
        return commonPath.isEmpty ? filePaths[0] : commonPath
    }
}
