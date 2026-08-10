import Darwin
import CryptoKit
import Foundation
import OSLog

enum MediaDownloadEvent: Sendable {
    case started(id: UUID, processIdentifier: Int32, expectedBytes: Int64, title: String?, platform: String?)
    case progress(id: UUID, bytesWritten: Int64, expectedBytes: Int64, speedBytesPerSecond: Double)
    case paused(id: UUID)
    case cancelled(id: UUID)
    case finished(id: UUID, fileURL: URL, payloadURLs: [URL], expectedBytes: Int64)
    case failed(id: UUID, message: String)
}

struct MediaTerminalOutcome: Sendable {
    let attemptIdentifier: UUID
    let event: MediaDownloadEvent
}

nonisolated struct MediaCompletedFileManifest: Codable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

nonisolated struct MediaCompletionManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let downloadID: UUID
    let attemptIdentifier: UUID
    let sourceURL: URL
    let destinationFolderPath: String
    let fileLocationPath: String
    let payloads: [MediaCompletedFileManifest]
    let actualBytes: Int64
    let createdAt: Date

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolderPath: String,
        fileLocationPath: String,
        payloads: [MediaCompletedFileManifest],
        actualBytes: Int64,
        createdAt: Date = .now
    ) {
        self.version = Self.currentVersion
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.sourceURL = sourceURL
        self.destinationFolderPath = destinationFolderPath
        self.fileLocationPath = fileLocationPath
        self.payloads = payloads
        self.actualBytes = actualBytes
        self.createdAt = createdAt
    }
}

nonisolated enum MediaCompletionEntry: Sendable {
    case valid(MediaCompletionManifest)
    case invalid(downloadID: UUID, message: String)
    case unavailable(downloadID: UUID, message: String)
}

enum MediaDownloadError: LocalizedError {
    case runtimeNotFound
    case unsupported(String)
    case unavailable(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            MediaRuntimeResolver.installHint
        case let .unsupported(message), let .unavailable(message), let .processFailed(message):
            message
        }
    }
}

actor MediaDownloadService {
    typealias EventHandler = @Sendable (UUID, MediaDownloadEvent) -> Void

    private enum TerminationReason {
        case pause
        case cancel
    }

    private enum CompletionManifestIntegrityError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message):
                message
            }
        }
    }

    private struct RegularFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: time_t
        let modificationNanoseconds: Int64
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int64
    }

    private struct RunningDownload {
        let id: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let process: ManagedChildProcess
        let destinationFolder: URL
        let temporaryFolder: URL
        let metadata: MediaDownloadMetadata?
        var terminationReason: TerminationReason?
        var stdoutBuffer = ""
        var stderrBuffer = ""
        var expectedBytes: Int64
    }

    private struct RunningProcess {
        let pid: pid_t
        let parentPID: pid_t
        let processGroupIdentifier: pid_t
        let startSignature: String
        let command: String
    }

    nonisolated private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Harbor",
        category: "MediaEngine"
    )

    private let eventHandler: EventHandler
    private let fileManager: FileManager
    private let temporaryRoot: URL
    private var runtime: MediaRuntimeResolution?
    private var runningDownloads: [UUID: RunningDownload] = [:]
    private var terminationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var terminalOutcomes: [UUID: MediaTerminalOutcome] = [:]
    private var hasCleanedOrphans = false
    private static let completionManifestFilename = ".harbor-completion.json"

    init(
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default,
        temporaryRoot: URL? = nil
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot ?? Self.defaultTemporaryRoot(fileManager: fileManager)
    }

    func metadata(for url: URL) async throws -> MediaDownloadMetadata {
        let runtime = try resolvedRuntime()
        let output = try await runMetadataCommand(runtime: runtime, url: url)
        let metadata = try MediaDownloadMetadataParser.metadata(from: output, sourceURL: url)

        guard metadata.supportsMediaDownload else {
            throw MediaDownloadError.unsupported(
                "yt-dlp couldn’t verify downloadable media for this link."
            )
        }

        return metadata
    }

    func startDownload(
        id: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference,
        speedLimitBytesPerSecond: Int64? = nil
    ) async throws -> Int32 {
        if let existing = runningDownloads[id] {
            guard existing.attemptIdentifier == attemptIdentifier else {
                throw MediaDownloadError.unavailable(
                    "The previous media process is still stopping. Try again after it exits."
                )
            }
            return existing.process.processIdentifier
        }
        if try completionManifestExists(id: id) {
            throw MediaDownloadError.unavailable(
                "A completed media result is still awaiting durable reconciliation."
            )
        }
        terminalOutcomes.removeValue(forKey: id)

        guard metadata?.supportsMediaDownload == true else {
            throw MediaDownloadError.unsupported(
                "yt-dlp couldn’t verify downloadable media for this download."
            )
        }

        let runtime = try resolvedRuntime()
        try await cleanupOrphanedMediaProcessesIfNeeded(runtime: runtime)

        let temporaryFolder = temporaryFolder(for: id)
        try fileManager.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let arguments = try Self.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            metadata: metadata,
            formatPreference: formatPreference,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond
        )

        let environment = processEnvironment(runtime: runtime)
        let outputCapture = MediaProcessOutputCapture()
        let process = try ManagedChildProcess(
            executableURL: runtime.ytDlpURL,
            arguments: arguments,
            environment: environment,
            onStdout: { [weak self] output in
                outputCapture.appendStdout(output)
                Task {
                    await self?.handleOutput(
                        output,
                        stream: .stdout,
                        for: id,
                        attemptIdentifier: attemptIdentifier
                    )
                }
            },
            onStderr: { [weak self] output in
                outputCapture.appendStderr(output)
                Task {
                    await self?.handleOutput(
                        output,
                        stream: .stderr,
                        for: id,
                        attemptIdentifier: attemptIdentifier
                    )
                }
            },
            onTermination: { [weak self] termination in
                let capturedOutput = outputCapture.snapshot()
                Task {
                    await self?.handleTermination(
                        termination,
                        for: id,
                        attemptIdentifier: attemptIdentifier,
                        capturedStdout: capturedOutput.stdout,
                        capturedStderr: capturedOutput.stderr
                    )
                }
            }
        )

        let expectedBytes = formatPreference.initialExpectedBytes(
            metadataEstimate: metadata?.expectedBytes ?? 0
        )
        runningDownloads[id] = RunningDownload(
            id: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            process: process,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            metadata: metadata,
            expectedBytes: expectedBytes
        )

        logger.info("Started media download \(id.uuidString, privacy: .public) with pid \(process.processIdentifier, privacy: .public)")
        eventHandler(
            attemptIdentifier,
            .started(
                id: id,
                processIdentifier: process.processIdentifier,
                expectedBytes: expectedBytes,
                title: metadata?.title,
                platform: metadata?.platform
            )
        )
        return process.processIdentifier
    }

    @discardableResult
    func pause(id: UUID) -> Bool {
        guard var download = runningDownloads[id] else {
            return false
        }

        download.terminationReason = .pause
        runningDownloads[id] = download
        download.process.terminate()
        return true
    }

    @discardableResult
    func cancel(id: UUID) -> Bool {
        guard var download = runningDownloads[id] else {
            return false
        }

        download.terminationReason = .cancel
        runningDownloads[id] = download
        download.process.terminate()
        return true
    }

    func pauseAndWait(id: UUID) async {
        guard pause(id: id) else {
            return
        }

        await waitForTermination(id: id)
    }

    func discardRecoveryData(id: UUID) throws {
        guard runningDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "Harbor couldn’t clear the previous media download while it was still running."
            )
        }

        terminalOutcomes.removeValue(forKey: id)
        let folder = temporaryFolder(for: id)
        guard try itemExists(at: folder) else {
            return
        }
        try fileManager.removeItem(at: folder)
        try DurableFileSystem.synchronizeParentDirectory(of: folder)
    }

    func discardOrphanedRecoveryData(retaining retainedIDs: Set<UUID>) throws {
        guard try itemExists(at: temporaryRoot) else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Process discovery is part of the deletion precondition. If it is
        // unavailable, preserve every recovery directory rather than treating
        // an empty process list as proof that no writer still owns one.
        let runningProcessCommands = try runningProcesses().map(\.command)
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                continue
            }
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  retainedIDs.contains(id) == false,
                  runningProcessCommands.contains(where: { $0.contains(entry.path) }) == false,
                  runningDownloads[id] == nil else {
                continue
            }

            try fileManager.removeItem(at: entry)
            try DurableFileSystem.synchronizeParentDirectory(of: entry)
        }
    }

    func recoverableByteCount(id: UUID) -> Int64? {
        let folder = temporaryFolder(for: id)
        guard fileManager.fileExists(atPath: folder.path),
              let enumerator = fileManager.enumerator(
                  at: folder,
                  includingPropertiesForKeys: [
                      .fileSizeKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey
                  ],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var total: Int64 = 0
        var foundPayload = false
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() != "ytdl",
                  let values = try? url.resourceValues(
                      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0 else {
                continue
            }
            foundPayload = true
            total += Int64(size)
        }
        return foundPayload ? total : nil
    }

    func terminateOrphanedMediaProcesses() async throws {
        let resolvedRuntime = try? resolvedRuntime()
        try await cleanupOrphanedMediaProcessesIfNeeded(runtime: resolvedRuntime)
    }

    func cancelAndWait(id: UUID) async {
        guard cancel(id: id) else {
            return
        }

        await waitForTermination(id: id)
    }

    func cancelAndDiscardRecoveryData(id: UUID) async throws {
        await cancelAndWait(id: id)
        try discardRecoveryData(id: id)
    }

    func terminalOutcome(id: UUID) -> MediaTerminalOutcome? {
        terminalOutcomes[id]
    }

    func completedDownloadEntries() throws -> [MediaCompletionEntry] {
        guard try itemExists(at: temporaryRoot) else {
            return []
        }
        let folders = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [MediaCompletionEntry] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else {
                continue
            }
            let manifestURL = completionManifestURL(id: id)
            let hasManifest: Bool
            do {
                hasManifest = try itemExists(at: manifestURL)
            } catch {
                entries.append(
                    .unavailable(downloadID: id, message: error.localizedDescription)
                )
                continue
            }
            guard hasManifest else {
                continue
            }

            do {
                entries.append(.valid(try validatedCompletionManifest(id: id)))
            } catch let error as CompletionManifestIntegrityError {
                entries.append(
                    .invalid(downloadID: id, message: error.localizedDescription)
                )
            } catch {
                entries.append(
                    .unavailable(downloadID: id, message: error.localizedDescription)
                )
            }
        }
        return entries
    }

    func completedDownloadEntry(id: UUID) throws -> MediaCompletionEntry? {
        let manifestURL = completionManifestURL(id: id)
        do {
            guard try itemExists(at: manifestURL) else {
                return nil
            }
        } catch {
            return .unavailable(downloadID: id, message: error.localizedDescription)
        }

        do {
            return .valid(try validatedCompletionManifest(id: id))
        } catch let error as CompletionManifestIntegrityError {
            return .invalid(downloadID: id, message: error.localizedDescription)
        } catch {
            return .unavailable(downloadID: id, message: error.localizedDescription)
        }
    }

    func acknowledgeCompletion(id: UUID, attemptIdentifier: UUID) throws {
        guard runningDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "The media process is still active while Harbor is acknowledging completion."
            )
        }

        let manifestURL = completionManifestURL(id: id)
        if try itemExists(at: manifestURL) {
            let manifest = try validatedCompletionManifest(id: id)
            guard manifest.attemptIdentifier == attemptIdentifier else {
                throw MediaDownloadError.unavailable(
                    "A newer media completion owns this recovery directory."
                )
            }
        } else if let outcome = terminalOutcomes[id],
                  outcome.attemptIdentifier != attemptIdentifier {
            throw MediaDownloadError.unavailable(
                "A newer media attempt owns this recovery directory."
            )
        }

        terminalOutcomes.removeValue(forKey: id)
        let folder = temporaryFolder(for: id)
        if try itemExists(at: folder) {
            try fileManager.removeItem(at: folder)
            try DurableFileSystem.synchronizeParentDirectory(of: folder)
        }
    }

    func discardCompletionMarker(id: UUID) throws {
        let url = completionManifestURL(id: id)
        guard try itemExists(at: url) else {
            return
        }
        try fileManager.removeItem(at: url)
        try DurableFileSystem.synchronizeParentDirectory(of: url)
    }

    private func waitForTermination(id: UUID) async {
        await withCheckedContinuation { continuation in
            guard runningDownloads[id] != nil else {
                continuation.resume()
                return
            }

            terminationWaiters[id, default: []].append(continuation)
        }
    }

    func shutdown() async {
        let downloads = Array(runningDownloads.values)
        for download in downloads {
            var updatedDownload = download
            if updatedDownload.terminationReason == nil {
                updatedDownload.terminationReason = .pause
            }
            runningDownloads[download.id] = updatedDownload
            download.process.terminate(grace: 0.6)
        }

        for download in downloads {
            await waitForTermination(id: download.id)
        }
    }

    private enum OutputStream {
        case stdout
        case stderr
    }

    private func handleOutput(
        _ output: String,
        stream: OutputStream,
        for id: UUID,
        attemptIdentifier: UUID
    ) {
        guard var download = runningDownloads[id],
              download.attemptIdentifier == attemptIdentifier else {
            return
        }

        switch stream {
        case .stdout:
            download.stdoutBuffer += output
            let lines = completeLines(from: &download.stdoutBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id, attemptIdentifier: attemptIdentifier)
        case .stderr:
            download.stderrBuffer += output
            let lines = completeLines(from: &download.stderrBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id, attemptIdentifier: attemptIdentifier)
        }
    }

    private func process(
        lines: [String],
        for id: UUID,
        attemptIdentifier: UUID
    ) {
        for line in lines {
            if let progress = MediaDownloadProgressParser.progress(from: line) {
                apply(
                    progress: progress,
                    to: id,
                    attemptIdentifier: attemptIdentifier
                )
                continue
            }

            // Final paths are consumed from the synchronously captured output
            // only after both pipes reach EOF. That prevents termination from
            // racing an actor task carrying the process's last line.
        }
    }

    private func apply(
        progress: MediaDownloadProgress,
        to id: UUID,
        attemptIdentifier: UUID
    ) {
        guard var download = runningDownloads[id],
              download.attemptIdentifier == attemptIdentifier else {
            return
        }

        let expectedBytes = max(progress.expectedBytes, download.expectedBytes)
        download.expectedBytes = expectedBytes
        runningDownloads[id] = download

        eventHandler(
            download.attemptIdentifier,
            .progress(
                id: id,
                bytesWritten: progress.bytesWritten,
                expectedBytes: expectedBytes,
                speedBytesPerSecond: progress.speedBytesPerSecond
            )
        )
    }

    private func handleTermination(
        _ termination: ManagedChildProcessTermination,
        for id: UUID,
        attemptIdentifier: UUID,
        capturedStdout: String,
        capturedStderr: String
    ) {
        guard let current = runningDownloads[id],
              current.attemptIdentifier == attemptIdentifier else {
            return
        }
        let download = current
        runningDownloads.removeValue(forKey: id)

        let waiters = terminationWaiters.removeValue(forKey: id) ?? []
        defer {
            waiters.forEach { $0.resume() }
        }

        logger.info("Media download \(id.uuidString, privacy: .public) exited with status \(termination.waitStatus, privacy: .public)")

        var successfulCompletionError: Error?
        if termination.isSuccess {
            do {
                let event = try successfulCompletionEvent(
                    for: download,
                    capturedStdout: capturedStdout,
                    capturedStderr: capturedStderr
                )
                // Completion is not publishable until its payload manifest is
                // durable. A visible destination file alone cannot survive a
                // crash between this callback and record persistence.
                do {
                    try persistCompletionManifest(event, for: download)
                } catch {
                    // The process already produced and validated its terminal
                    // output. A simultaneous Pause or Cancel cannot turn that
                    // completed representation back into resumable partial
                    // state merely because journaling failed late.
                    emitTerminal(
                        .failed(id: id, message: error.localizedDescription),
                        for: download
                    )
                    return
                }
                emitTerminal(event, for: download)
                return
            } catch {
                successfulCompletionError = error
            }
        }

        // A process that reached a validated successful output wins a
        // simultaneous Pause/Cancel request above. If it did not publish a
        // complete output, preserve the user's termination intent here.
        switch download.terminationReason {
        case .pause:
            emitTerminal(.paused(id: id), for: download)
            return
        case .cancel:
            cleanupTemporaryFolder(download.temporaryFolder)
            emitTerminal(.cancelled(id: id), for: download)
            return
        case nil:
            break
        }

        if termination.isSuccess == false {
            emitTerminal(
                .failed(
                    id: id,
                    message: MediaDownloadErrorClassifier.message(from: capturedStderr)
                ),
                for: download
            )
            return
        }

        emitTerminal(
            .failed(
                id: id,
                message: successfulCompletionError?.localizedDescription
                    ?? "yt-dlp finished without reporting a completed file."
            ),
            for: download
        )
    }

    private func successfulCompletionEvent(
        for download: RunningDownload,
        capturedStdout: String,
        capturedStderr: String
    ) throws -> MediaDownloadEvent {
        let capturedLines = (capturedStdout + "\n" + capturedStderr)
            .components(separatedBy: .newlines)
        let reportedURLs = capturedLines.compactMap(MediaDownloadFinalPathParser.fileURL(from:))

        let fileURL: URL
        let payloadURLs: [URL]
        let actualBytes: Int64
        if download.metadata?.isCollection == true {
            fileURL = download.destinationFolder
            let validatedFiles = try reportedURLs.map {
                try validatedFinalFile(
                    $0,
                    destinationFolder: download.destinationFolder
                )
            }
            guard validatedFiles.isEmpty == false else {
                throw MediaDownloadError.processFailed(
                    "yt-dlp finished without reporting any completed files."
                )
            }
            let uniqueFiles = Dictionary(
                validatedFiles.map { ($0.url.standardizedFileURL.path, $0.byteCount) },
                uniquingKeysWith: { _, latest in latest }
            )
            payloadURLs = uniqueFiles.keys
                .sorted()
                .map { URL(fileURLWithPath: $0) }
            actualBytes = uniqueFiles.values.reduce(0) { partial, bytes in
                let (sum, overflow) = partial.addingReportingOverflow(bytes)
                return overflow ? Int64.max : sum
            }
        } else {
            guard let reportedURL = reportedURLs.last else {
                throw MediaDownloadError.processFailed(
                    "yt-dlp finished without reporting the completed file path."
                )
            }

            let validatedFile = try validatedFinalFile(
                reportedURL,
                destinationFolder: download.destinationFolder
            )
            fileURL = validatedFile.url
            payloadURLs = [validatedFile.url]
            actualBytes = validatedFile.byteCount
        }

        return .finished(
            id: download.id,
            fileURL: fileURL,
            payloadURLs: payloadURLs,
            expectedBytes: actualBytes
        )
    }

    private func emitTerminal(
        _ event: MediaDownloadEvent,
        for download: RunningDownload
    ) {
        terminalOutcomes[download.id] = MediaTerminalOutcome(
            attemptIdentifier: download.attemptIdentifier,
            event: event
        )
        eventHandler(download.attemptIdentifier, event)
    }

    private func resolvedRuntime() throws -> MediaRuntimeResolution {
        if let runtime {
            return runtime
        }

        guard let runtime = MediaRuntimeResolver.resolveRuntime() else {
            throw MediaDownloadError.runtimeNotFound
        }

        self.runtime = runtime
        return runtime
    }

    private func runMetadataCommand(
        runtime: MediaRuntimeResolution,
        url: URL
    ) async throws -> Data {
        let arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--no-warnings",
            "--socket-timeout",
            "15",
            "--retries",
            "3",
            "--extractor-retries",
            "3",
            "--retry-sleep",
            "http:linear=2:10:4",
            "--retry-sleep",
            "extractor:linear=2:10:4",
            "--dump-single-json",
            "--flat-playlist",
            "--simulate",
            "--check-all-formats",
            "--ffmpeg-location",
            runtime.ffmpegURL.deletingLastPathComponent().path,
            url.absoluteString
        ]

        let state = MetadataCommandState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let process = try ManagedChildProcess(
                        executableURL: runtime.ytDlpURL,
                        arguments: arguments,
                        environment: processEnvironment(runtime: runtime),
                        onStdout: { output in
                            state.appendStdout(output)
                        },
                        onStderr: { output in
                            state.appendStderr(output)
                        },
                        onTermination: { termination in
                            guard let result = state.finish(termination: termination) else {
                                return
                            }

                            switch result {
                            case let .success(output):
                                continuation.resume(returning: output)
                            case let .failure(error):
                                continuation.resume(throwing: error)
                            }
                        }
                    )

                    state.process = process
                    if Task.isCancelled {
                        process.terminate(grace: 0.2)
                    }

                    Task {
                        try? await Task.sleep(for: .seconds(120))
                        guard state.markTimedOut() else {
                            return
                        }

                        process.terminate(grace: 0.5)
                        continuation.resume(
                            throwing: MediaDownloadError.unavailable(
                                "Timed out while checking this media link."
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: MediaDownloadError.processFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            state.process?.terminate(grace: 0.2)
        }
    }

    nonisolated static func downloadArguments(
        runtime: MediaRuntimeResolution,
        sourceURL: URL,
        destinationFolder: URL,
        temporaryFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference,
        speedLimitBytesPerSecond: Int64?
    ) throws -> [String] {
        var arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--newline",
            "--continue",
            "--no-overwrites",
            "--socket-timeout",
            "15",
            "--retries",
            "10",
            "--fragment-retries",
            "10",
            "--file-access-retries",
            "3",
            "--extractor-retries",
            "3",
            "--retry-sleep",
            "http:exp=2:60",
            "--retry-sleep",
            "fragment:exp=2:60",
            "--retry-sleep",
            "file_access:exp=2:60",
            "--retry-sleep",
            "extractor:exp=2:60",
            "--paths",
            "home:\(destinationFolder.path)",
            "--paths",
            "temp:\(temporaryFolder.path)",
            "--output",
            "%(title).180B [%(id)s].%(ext)s",
            "--print",
            "after_move:harbor-file:%(filepath)j",
            "--progress-template",
            "download:harbor-progress:%(progress.downloaded_bytes|0)s\t%(progress.total_bytes,progress.total_bytes_estimate|0)s\t%(progress.speed|0)s",
            "--ffmpeg-location",
            runtime.ffmpegURL.deletingLastPathComponent().path
        ]

        if metadata?.isCollection != true {
            arguments.append("--no-playlist")
        }

        if let speedLimitBytesPerSecond, speedLimitBytesPerSecond > 0 {
            arguments.append(contentsOf: [
                "--limit-rate",
                "\(speedLimitBytesPerSecond)"
            ])
        }

        if case let .specific(selection) = formatPreference {
            arguments.append(contentsOf: [
                "--format",
                selection.selector
            ])

            if let mergeOutputFormat = selection.mergeOutputFormat {
                arguments.append(contentsOf: [
                    "--merge-output-format",
                    mergeOutputFormat
                ])
            }
        }

        arguments.append(sourceURL.absoluteString)
        return arguments
    }

    private func processEnvironment(runtime: MediaRuntimeResolution) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let runtimeBinPath = runtime.ytDlpURL.deletingLastPathComponent().path
        let path = environment["PATH"].map { "\(runtimeBinPath):\($0)" } ?? runtimeBinPath
        environment["PATH"] = path
        environment["PYTHONNOUSERSITE"] = "1"
        return environment
    }

    private func completeLines(from buffer: inout String) -> [String] {
        let parts = buffer.components(separatedBy: .newlines)
        guard parts.count > 1 else {
            return []
        }

        buffer = parts.last ?? ""
        return parts.dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func temporaryFolder(for id: UUID) -> URL {
        temporaryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func completionManifestURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.completionManifestFilename)
    }

    private func completionManifestExists(id: UUID) throws -> Bool {
        try itemExists(at: completionManifestURL(id: id))
    }

    private func persistCompletionManifest(
        _ event: MediaDownloadEvent,
        for download: RunningDownload
    ) throws {
        guard case let .finished(id, fileURL, payloadURLs, expectedBytes) = event,
              id == download.id,
              payloadURLs.isEmpty == false else {
            throw CompletionManifestIntegrityError.invalid(
                "The media completion event did not contain validated payloads."
            )
        }

        var payloads: [MediaCompletedFileManifest] = []
        var seenPaths = Set<String>()
        var totalBytes: Int64 = 0
        for payloadURL in payloadURLs {
            let validated = try validatedFinalFile(
                payloadURL,
                destinationFolder: download.destinationFolder
            )
            let path = validated.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                continue
            }
            try DurableFileSystem.synchronizeFile(at: validated.url)
            try DurableFileSystem.synchronizeParentDirectory(of: validated.url)
            let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(
                validated.byteCount
            )
            guard overflow == false else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media byte count overflowed."
                )
            }
            totalBytes = updatedTotal
            payloads.append(
                MediaCompletedFileManifest(
                    path: path,
                    byteCount: validated.byteCount,
                    sha256: try verifiedSHA256(
                        at: validated.url,
                        expectedBytes: validated.byteCount
                    )
                )
            )
        }
        guard payloads.isEmpty == false,
              totalBytes == expectedBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media payload size did not match its terminal event."
            )
        }

        let manifest = MediaCompletionManifest(
            downloadID: download.id,
            attemptIdentifier: download.attemptIdentifier,
            sourceURL: download.sourceURL,
            destinationFolderPath: download.destinationFolder.standardizedFileURL.path,
            fileLocationPath: fileURL.standardizedFileURL.path,
            payloads: payloads,
            actualBytes: totalBytes
        )
        try fileManager.createDirectory(
            at: download.temporaryFolder,
            withIntermediateDirectories: true
        )
        let manifestURL = completionManifestURL(id: download.id)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: manifestURL)
        try DurableFileSystem.synchronizeDirectory(at: download.temporaryFolder)
        try DurableFileSystem.synchronizeParentDirectory(of: download.temporaryFolder)
    }

    private func validatedCompletionManifest(id: UUID) throws -> MediaCompletionManifest {
        let manifestURL = completionManifestURL(id: id)
        let manifestIdentity = try regularFileIdentity(at: manifestURL)
        let values = try manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal is not a regular file."
            )
        }

        let manifest: MediaCompletionManifest
        do {
            manifest = try JSONDecoder().decode(
                MediaCompletionManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch let error as DecodingError {
            throw CompletionManifestIntegrityError.invalid(error.localizedDescription)
        }
        guard manifest.version == MediaCompletionManifest.currentVersion,
              manifest.downloadID == id,
              manifest.payloads.isEmpty == false,
              manifest.actualBytes >= 0 else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal contains invalid ownership metadata."
            )
        }

        let destinationFolder = URL(
            fileURLWithPath: manifest.destinationFolderPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let destinationPrefix = destinationFolder.path.hasSuffix("/")
            ? destinationFolder.path
            : destinationFolder.path + "/"
        var seenPaths = Set<String>()
        var totalBytes: Int64 = 0
        for payload in manifest.payloads {
            guard payload.byteCount >= 0,
                  payload.sha256.count == SHA256.byteCount * 2 else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media journal contains invalid payload metadata."
                )
            }
            let storedURL = URL(fileURLWithPath: payload.path).standardizedFileURL
            let storedValues: URLResourceValues
            do {
                storedValues = try storedURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload is missing."
                )
            }
            guard storedValues.isRegularFile == true,
                  storedValues.isSymbolicLink != true,
                  Int64(storedValues.fileSize ?? -1) == payload.byteCount else {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload no longer matches its journal."
                )
            }
            let candidate = storedURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(destinationPrefix),
                  seenPaths.insert(candidate.path).inserted,
                  try verifiedSHA256(
                    at: candidate,
                    expectedBytes: payload.byteCount
                  ) == payload.sha256 else {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload no longer matches its journal."
                )
            }
            let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(
                payload.byteCount
            )
            guard overflow == false else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media byte count overflowed."
                )
            }
            totalBytes = updatedTotal
        }
        guard totalBytes == manifest.actualBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media byte count no longer matches its journal."
            )
        }

        let fileLocation = URL(fileURLWithPath: manifest.fileLocationPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let payloadPaths = Set(manifest.payloads.map { payload in
            URL(fileURLWithPath: payload.path)
                .standardizedFileURL.resolvingSymlinksInPath().path
        })
        guard fileLocation == destinationFolder || payloadPaths.contains(fileLocation.path) else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media location is outside its destination."
            )
        }
        guard try regularFileIdentity(at: manifestURL) == manifestIdentity else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal changed while it was being verified."
            )
        }
        return manifest
    }

    private func regularFileIdentity(at url: URL) throws -> RegularFileIdentity {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        guard result == 0 else {
            if let code = POSIXErrorCode(rawValue: errno) {
                throw POSIXError(code)
            }
            throw CompletionManifestIntegrityError.invalid(
                "The completed media file could not be inspected."
            )
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0 else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media path is not a regular file."
            )
        }
        return RegularFileIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            modificationSeconds: metadata.st_mtimespec.tv_sec,
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: metadata.st_ctimespec.tv_sec,
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private func verifiedSHA256(
        at url: URL,
        expectedBytes: Int64
    ) throws -> String {
        let before = try regularFileIdentity(at: url)
        guard Int64(before.size) == expectedBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "A completed media payload no longer matches its journal."
            )
        }
        let digest = try sha256(at: url)
        guard try regularFileIdentity(at: url) == before else {
            throw CompletionManifestIntegrityError.invalid(
                "A completed media payload changed while it was being verified."
            )
        }
        return digest
    }

    private func itemExists(at url: URL) throws -> Bool {
        do {
            _ = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        }
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024),
              data.isEmpty == false {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupTemporaryFolder(_ folder: URL) {
        try? fileManager.removeItem(at: folder)
    }

    private func validatedFinalFile(
        _ reportedURL: URL,
        destinationFolder: URL
    ) throws -> (url: URL, byteCount: Int64) {
        let destination = destinationFolder.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = reportedURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationPrefix = destination.path.hasSuffix("/")
            ? destination.path
            : destination.path + "/"
        guard reportedURL.isFileURL,
              candidate.path.hasPrefix(destinationPrefix) else {
            throw MediaDownloadError.processFailed(
                "yt-dlp reported a completed file outside the selected destination folder."
            )
        }

        let values = try candidate.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw MediaDownloadError.processFailed(
                "yt-dlp reported a completed path that is not a regular file."
            )
        }
        return (candidate, Int64(fileSize))
    }

    private func cleanupOrphanedMediaProcessesIfNeeded(
        runtime: MediaRuntimeResolution?
    ) async throws {
        guard hasCleanedOrphans == false else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentProcessGroupIdentifier = getpgrp()
        let protectedPIDs = Set(runningDownloads.values.map { $0.process.processIdentifier })
        let processes = try runningProcesses()
        let orphanedGroupIdentifiers = Set(processes.compactMap { process -> pid_t? in
            guard process.parentPID == 1,
                  process.pid != currentPID,
                  process.processGroupIdentifier > 1,
                  process.processGroupIdentifier != currentProcessGroupIdentifier,
                  protectedPIDs.contains(process.pid) == false,
                  isHarborManagedMediaProcess(process.command, runtime: runtime) else {
                return nil
            }
            return process.processGroupIdentifier
        })
        let originalMembers = processes.filter { process in
            orphanedGroupIdentifiers.contains(process.processGroupIdentifier)
                && protectedPIDs.contains(process.pid) == false
                && isHarborManagedMediaProcess(process.command, runtime: runtime)
        }

        let termTargets = matchingProcesses(
            originalMembers,
            in: processes
        )
        for process in termTargets {
            logger.warning("Terminating orphaned media process with pid \(process.pid, privacy: .public)")
            _ = kill(process.pid, SIGTERM)
        }
        guard originalMembers.isEmpty == false else {
            hasCleanedOrphans = true
            return
        }

        try? await Task.sleep(for: .milliseconds(600))
        let afterTerm = try runningProcesses()
        let killTargets = matchingProcesses(originalMembers, in: afterTerm)
        for process in killTargets {
            logger.warning("Force terminating orphaned media process with pid \(process.pid, privacy: .public)")
            _ = kill(process.pid, SIGKILL)
        }
        if killTargets.isEmpty == false {
            try? await Task.sleep(for: .milliseconds(150))
        }

        let survivors = matchingProcesses(originalMembers, in: try runningProcesses())
        guard survivors.isEmpty else {
            let identifiers = survivors.map { String($0.pid) }.joined(separator: ", ")
            throw MediaDownloadError.unavailable(
                "Harbor could not confirm that orphaned media processes stopped (PIDs: \(identifiers))."
            )
        }
        hasCleanedOrphans = true
    }

    private func matchingProcesses(
        _ expected: [RunningProcess],
        in current: [RunningProcess]
    ) -> [RunningProcess] {
        current.filter { candidate in
            expected.contains { original in
                candidate.pid == original.pid
                    && candidate.processGroupIdentifier == original.processGroupIdentifier
                    && candidate.startSignature == original.startSignature
                    && candidate.command == original.command
            }
        }
    }

    private func runningProcesses() throws -> [RunningProcess] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pgid=,lstart=,command=", "-ww"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw MediaDownloadError.unavailable(
                "Harbor could not inspect active media processes: \(error.localizedDescription)"
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MediaDownloadError.unavailable(
                "Harbor could not inspect active media processes (ps exited with status \(process.terminationStatus))."
            )
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw MediaDownloadError.unavailable(
                "Harbor could not decode the active media process list."
            )
        }

        return output
            .split(separator: "\n")
            .compactMap { runningProcess(from: String($0)) }
    }

    private func runningProcess(from processLine: String) -> RunningProcess? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)

        guard parts.count == 9,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]),
              let processGroupIdentifier = pid_t(parts[2]) else {
            return nil
        }

        return RunningProcess(
            pid: pid,
            parentPID: parentPID,
            processGroupIdentifier: processGroupIdentifier,
            startSignature: parts[3 ... 7].joined(separator: " "),
            command: String(parts[8])
        )
    }

    private func isHarborManagedMediaProcess(
        _ command: String,
        runtime: MediaRuntimeResolution?
    ) -> Bool {
        if command.contains(temporaryRoot.path) {
            return true
        }

        guard command.contains("/Harbor.app/Contents/Resources/MediaRuntime/")
            || command.contains("/MediaRuntime/") else {
            return false
        }

        return runtime.map { resolution in
            command.hasPrefix(resolution.ytDlpURL.path)
                || command.hasPrefix(resolution.ffmpegURL.path)
                || command.hasPrefix(resolution.ffprobeURL.path)
        } == true
            || command.contains("/Harbor.app/Contents/Resources/MediaRuntime/")
    }

    private static func defaultTemporaryRoot(fileManager: FileManager) -> URL {
        HarborApplicationSupport.directoryURL(fileManager: fileManager)
            .appendingPathComponent("MediaDownloads", isDirectory: true)
    }
}

private final class MetadataCommandState: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var stdoutBuffer = ""
    nonisolated(unsafe) private var stderrBuffer = ""
    nonisolated(unsafe) private var isCompleted = false
    nonisolated(unsafe) private var storedProcess: ManagedChildProcess?

    nonisolated init() {}

    nonisolated var process: ManagedChildProcess? {
        get {
            lock.withLock { storedProcess }
        }
        set {
            lock.withLock {
                storedProcess = newValue
            }
        }
    }

    nonisolated func appendStdout(_ output: String) {
        lock.withLock {
            stdoutBuffer += output
        }
    }

    nonisolated func appendStderr(_ output: String) {
        lock.withLock {
            stderrBuffer += output
        }
    }

    nonisolated func markTimedOut() -> Bool {
        lock.withLock {
            guard isCompleted == false else {
                return false
            }

            isCompleted = true
            return true
        }
    }

    nonisolated func finish(termination: ManagedChildProcessTermination) -> Result<Data, Error>? {
        lock.withLock {
            guard isCompleted == false else {
                return nil
            }

            isCompleted = true

            if termination.isSuccess {
                return .success(Data(stdoutBuffer.utf8))
            }

            return .failure(
                MediaDownloadError.unsupported(
                    MediaDownloadErrorClassifier.message(from: stderrBuffer)
                )
            )
        }
    }
}

private final class MediaProcessOutputCapture: @unchecked Sendable {
    nonisolated private static let maximumCapturedBytes = 1_048_576
    nonisolated private static let retainedCharacterCount = 200_000

    struct Snapshot: Sendable {
        let stdout: String
        let stderr: String
    }

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var stdout = ""
    nonisolated(unsafe) private var stderr = ""
    nonisolated(unsafe) private var stdoutByteCount = 0
    nonisolated(unsafe) private var stderrByteCount = 0

    nonisolated init() {}

    nonisolated func appendStdout(_ output: String) {
        lock.withLock {
            stdout += output
            stdoutByteCount += output.utf8.count
            if stdoutByteCount > Self.maximumCapturedBytes {
                stdout = String(stdout.suffix(Self.retainedCharacterCount))
                stdoutByteCount = stdout.utf8.count
            }
        }
    }

    nonisolated func appendStderr(_ output: String) {
        lock.withLock {
            stderr += output
            stderrByteCount += output.utf8.count
            if stderrByteCount > Self.maximumCapturedBytes {
                stderr = String(stderr.suffix(Self.retainedCharacterCount))
                stderrByteCount = stderr.utf8.count
            }
        }
    }

    nonisolated func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(stdout: stdout, stderr: stderr)
        }
    }
}

struct MediaDownloadProgress: Equatable, Sendable {
    let bytesWritten: Int64
    let expectedBytes: Int64
    let speedBytesPerSecond: Double
}

enum MediaDownloadProgressParser {
    nonisolated static func progress(from line: String) -> MediaDownloadProgress? {
        guard line.hasPrefix("harbor-progress:") else {
            return nil
        }

        let payload = line.dropFirst("harbor-progress:".count)
        let parts = payload.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return nil
        }

        let bytesWritten = Int64(parts[0]) ?? 0
        let expectedBytes = Int64(parts[1]) ?? 0
        let speedBytesPerSecond = Double(parts[2]) ?? 0
        return MediaDownloadProgress(
            bytesWritten: bytesWritten,
            expectedBytes: expectedBytes,
            speedBytesPerSecond: speedBytesPerSecond
        )
    }
}

enum MediaDownloadFinalPathParser {
    nonisolated static func fileURL(from line: String) -> URL? {
        guard line.hasPrefix("harbor-file:") else {
            return nil
        }

        let payload = line.dropFirst("harbor-file:".count)
        if let data = payload.data(using: .utf8),
           let path = try? JSONDecoder().decode(String.self, from: data),
           path.isEmpty == false {
            return URL(fileURLWithPath: path)
        }

        let path = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

enum MediaDownloadErrorClassifier {
    nonisolated static let selectedFormatUnavailableMessage =
        "The selected media format is no longer available."

    nonisolated static func message(from stderr: String) -> String {
        let normalized = stderr.lowercased()

        if normalized.contains("unsupported url") || normalized.contains("no suitable extractor") {
            return "Harbor doesn’t support this media link yet."
        }

        if normalized.contains("login")
            || normalized.contains("sign in")
            || normalized.contains("private")
            || normalized.contains("authentication") {
            return "yt-dlp couldn’t access this link. It may need sign-in, be private, or be blocked by the platform."
        }

        if normalized.contains("copyright") || normalized.contains("drm") {
            return "yt-dlp couldn’t access a downloadable media stream for this link."
        }

        if normalized.contains("requested format is not available") {
            return selectedFormatUnavailableMessage
        }

        if normalized.contains("no video formats found")
            || normalized.contains("no formats found") {
            return "No downloadable media format was available for this link."
        }

        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }

        return "The media download failed."
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
