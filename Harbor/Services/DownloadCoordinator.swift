import Foundation

private struct DirectDownloadRecoveryRestartError: LocalizedError {
    var errorDescription: String? {
        "The server did not accept the saved partial download."
    }
}

private struct DirectDownloadIncompleteResponseError: LocalizedError {
    let actualBytes: Int64
    let expectedBytes: Int64?

    var errorDescription: String? {
        if let expectedBytes {
            return "The download ended after \(actualBytes) of \(expectedBytes) bytes."
        }

        return "The server ended a ranged download without declaring the complete file length."
    }
}

private struct DirectDownloadRangeOverflowError: LocalizedError {
    let declaredEnd: Int64

    var errorDescription: String? {
        "The server sent data beyond the declared byte range ending at byte \(declaredEnd)."
    }
}

struct DirectDownloadFailure: Sendable {
    let message: String
    let urlErrorCode: URLError.Code?
    let httpStatusCode: Int?
    let resumeData: Data?
    let wasResuming: Bool
    let recoverableBytes: Int64?
    private let retryableOverride: Bool

    var isRetryable: Bool {
        DirectDownloadRetryPolicy.isRetryable(urlErrorCode)
            || DirectDownloadRetryPolicy.isRetryableHTTPStatus(httpStatusCode)
            || retryableOverride
            || (
                httpStatusCode == nil
                    && wasResuming
                    && resumeData == nil
                    && recoverableBytes == nil
            )
    }

    var requiresFreshStart: Bool {
        resumeData == nil && (recoverableBytes ?? 0) == 0
    }

    nonisolated init(
        error: Error,
        resumeData: Data?,
        wasResuming: Bool = false,
        recoverableBytes: Int64? = nil,
        httpStatusCode: Int? = nil
    ) {
        let nsError = error as NSError
        self.message = nsError.localizedDescription
        self.urlErrorCode = DirectDownloadRetryPolicy.urlErrorCode(from: nsError)
        self.httpStatusCode = httpStatusCode
        self.resumeData = resumeData
        self.wasResuming = wasResuming
        self.recoverableBytes = recoverableBytes
        self.retryableOverride = error is DirectDownloadRecoveryRestartError
            || error is DirectDownloadIncompleteResponseError
            || error is DirectDownloadRangeOverflowError
    }
}

struct DirectDownloadPauseResult: Sendable {
    let resumeData: Data?
    let ownedRecovery: DirectDownloadRecoverySnapshot?
}

struct DirectDownloadContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?
}

private struct DirectDownloadHTTPStatusError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        "The server returned HTTP \(statusCode) instead of a downloadable file."
    }
}

enum DirectDownloadRetryPolicy {
    static let delays: [Duration] = [
        .seconds(2),
        .seconds(5),
        .seconds(15),
        .seconds(30),
        .seconds(60)
    ]

    static func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, delays.indices.contains(attempt - 1) else {
            return nil
        }

        return delays[attempt - 1]
    }

    static func isRetryable(_ code: URLError.Code?) -> Bool {
        guard let code else {
            return false
        }

        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable,
             .downloadDecodingFailedMidStream:
            return true
        default:
            return false
        }
    }

    static func isRetryableHTTPStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else {
            return false
        }

        return statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || statusCode == 500
            || statusCode == 502
            || statusCode == 503
            || statusCode == 504
    }

    nonisolated static func urlErrorCode(from error: NSError) -> URLError.Code? {
        if error.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: error.code)
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return urlErrorCode(from: underlyingError)
        }

        return nil
    }
}

enum DownloadEvent: Sendable {
    case started(
        id: UUID,
        taskIdentifier: Int,
        usesOwnedPartial: Bool,
        ownedRecovery: DirectDownloadRecoverySnapshot?,
        resetReason: DirectDownloadRecoveryResetReason?
    )
    case recoveryReset(id: UUID, reason: DirectDownloadRecoveryResetReason)
    case progress(id: UUID, bytesWritten: Int64, expectedBytes: Int64, speedBytesPerSecond: Double)
    case finished(
        id: UUID,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?
    )
    case failed(id: UUID, failure: DirectDownloadFailure)
}

final class DownloadCoordinator: NSObject, @unchecked Sendable {
    typealias EventHandler = @Sendable (DownloadEvent) -> Void

    private struct TransferSample {
        var lastTotalBytesWritten: Int64
        var sampleDate: Date
        var speedBytesPerSecond: Double
    }

    private typealias TaskKey = String

    private struct OwnedPartialState {
        let sourceURL: URL
        var resumeOffset: Int64
        var bytesWritten: Int64
        var expectedBytes: Int64
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var responseRangeEnd: Int64?
        var entityTag: String?
        var lastModified: String?
        var fileHandle: FileHandle?
    }

    private enum TaskMode {
        case legacyDownload(startedFromResumeData: Bool)
        case ownedPartial(OwnedPartialState)
    }

    private struct TaskContext {
        let downloadID: UUID
        let session: URLSession
        let task: URLSessionTask
        var mode: TaskMode
        var speedLimitOverride: TransferLimitOverride
        var transferSample: TransferSample
        var isThrottled = false
        var throttleGeneration: UInt64 = 0
    }

    private let eventHandler: EventHandler
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private let ownedTemporaryDirectory: URL
    private let recoveryStore: DirectDownloadRecoveryStore
    private let baseSessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue

    private var contexts: [TaskKey: TaskContext] = [:]
    private var taskKeysByDownloadID: [UUID: TaskKey] = [:]
    private var suppressedCompletionTaskKeys: Set<TaskKey> = []
    private var transferSettings: DownloadTransferSettings

    init(
        transferSettings: DownloadTransferSettings = .default,
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default,
        recoveryDirectoryURL: URL? = nil,
        temporaryDirectory: URL? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.transferSettings = transferSettings
        self.ownedTemporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("HarborDownloads", isDirectory: true)
        self.recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryDirectoryURL
        )
        self.baseSessionConfiguration = sessionConfiguration
        self.delegateQueue = OperationQueue()
        self.delegateQueue.name = "DownloadCoordinatorDelegateQueue"
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    deinit {
        let activeContexts = withLock {
            Array(self.contexts.values)
        }
        for context in activeContexts {
            closeOwnedFile(in: context)
            context.session.invalidateAndCancel()
        }
    }

    func updateTransferSettings(_ transferSettings: DownloadTransferSettings) {
        let tasksToResume = withLock { () -> [URLSessionTask] in
            self.transferSettings = transferSettings
            return releaseThrottledTasksLocked()
        }
        tasksToResume.forEach { $0.resume() }
    }

    func updateSpeedLimitOverride(
        _ speedLimitOverride: TransferLimitOverride,
        for id: UUID
    ) {
        let tasksToResume = withLock { () -> [URLSessionTask] in
            guard let taskKey = taskKeysByDownloadID[id],
                  var context = contexts[taskKey] else {
                return []
            }

            context.speedLimitOverride = speedLimitOverride
            var tasks: [URLSessionTask] = []
            if context.isThrottled {
                context.isThrottled = false
                context.throttleGeneration &+= 1
                tasks.append(context.task)
            }
            contexts[taskKey] = context
            return tasks
        }
        tasksToResume.forEach { $0.resume() }
    }

    @discardableResult
    func startDownload(
        id: UUID,
        sourceURL: URL,
        resumeData: Data?,
        speedLimitOverride: TransferLimitOverride = .inherit
    ) throws -> Int {
        let session = makeSession()
        let task: URLSessionTask
        let mode: TaskMode
        let ownedRecovery: DirectDownloadRecoverySnapshot?
        let resetReason: DirectDownloadRecoveryResetReason?

        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            mode = .legacyDownload(startedFromResumeData: true)
            ownedRecovery = nil
            resetReason = nil
        } else {
            let preparation = try recoveryStore.prepareStart(id: id, sourceURL: sourceURL)
            let request = makeOwnedRequest(
                sourceURL: sourceURL,
                recovery: preparation.snapshot
            )
            task = session.dataTask(with: request)
            let recoveredBytes = preparation.snapshot?.bytesWritten ?? 0
            mode = .ownedPartial(
                OwnedPartialState(
                    sourceURL: sourceURL,
                    resumeOffset: recoveredBytes,
                    bytesWritten: recoveredBytes,
                    expectedBytes: preparation.snapshot?.metadata.expectedBytes ?? 0,
                    suggestedFilename: preparation.snapshot?.metadata.suggestedFilename,
                    responseMimeType: preparation.snapshot?.metadata.mimeType,
                    statusCode: nil,
                    responseRangeEnd: nil,
                    entityTag: preparation.snapshot?.metadata.entityTag,
                    lastModified: preparation.snapshot?.metadata.lastModified,
                    fileHandle: nil
                )
            )
            ownedRecovery = preparation.snapshot
            resetReason = preparation.resetReason
        }

        let key = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        let context = TaskContext(
            downloadID: id,
            session: session,
            task: task,
            mode: mode,
            speedLimitOverride: speedLimitOverride,
            transferSample: TransferSample(
                lastTotalBytesWritten: ownedRecovery?.bytesWritten ?? 0,
                sampleDate: .now,
                speedBytesPerSecond: 0
            )
        )

        withLock {
            contexts[key] = context
            taskKeysByDownloadID[id] = key
            suppressedCompletionTaskKeys.remove(key)
        }

        task.resume()
        eventHandler(
            .started(
                id: id,
                taskIdentifier: task.taskIdentifier,
                usesOwnedPartial: resumeData == nil,
                ownedRecovery: ownedRecovery,
                resetReason: resetReason
            )
        )
        return task.taskIdentifier
    }

    /// Stops an active task and returns the resume data only after URLSession has produced it.
    ///
    /// Pause and shutdown paths await this form so persistence cannot race the
    /// asynchronous `cancel(byProducingResumeData:)` callback.
    func pauseDownloadAndWait(id: UUID) async -> DirectDownloadPauseResult {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            return DirectDownloadPauseResult(resumeData: nil, ownedRecovery: nil)
        }

        switch context.mode {
        case .legacyDownload:
            guard let downloadTask = context.task as? URLSessionDownloadTask else {
                context.task.cancel()
                context.session.finishTasksAndInvalidate()
                return DirectDownloadPauseResult(resumeData: nil, ownedRecovery: nil)
            }

            return await withCheckedContinuation { continuation in
                downloadTask.cancel(byProducingResumeData: { [session = context.session] resumeData in
                    session.finishTasksAndInvalidate()
                    continuation.resume(
                        returning: DirectDownloadPauseResult(
                            resumeData: resumeData,
                            ownedRecovery: nil
                        )
                    )
                })
            }

        case let .ownedPartial(state):
            try? state.fileHandle?.close()
            context.task.cancel()
            context.session.finishTasksAndInvalidate()
            return DirectDownloadPauseResult(
                resumeData: nil,
                ownedRecovery: recoveryStore.snapshot(id: id, sourceURL: state.sourceURL)
            )
        }
    }

    func cancelDownload(id: UUID) {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            recoveryStore.discard(id: id)
            return
        }

        closeOwnedFile(in: context)
        context.task.cancel()
        context.session.invalidateAndCancel()
        recoveryStore.discard(id: id)
    }

    func discardRecoveryData(id: UUID) {
        recoveryStore.discard(id: id)
    }

    func discardOrphanedRecoveryData(retaining retainedIDs: Set<UUID>) {
        recoveryStore.discardOrphans(retaining: retainedIDs)
    }

    func discardOrphanedTemporaryFiles() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: ownedTemporaryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents {
            guard url.pathExtension == "download",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    func recoverySnapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        recoveryStore.snapshot(id: id, sourceURL: sourceURL)
    }

    private func takeContext(forDownloadID id: UUID, suppressCompletion: Bool) -> TaskContext? {
        withLock {
            guard let taskKey = taskKeysByDownloadID.removeValue(forKey: id),
                  let context = contexts.removeValue(forKey: taskKey) else {
                return nil
            }

            if suppressCompletion {
                suppressedCompletionTaskKeys.insert(taskKey)
            }

            return context
        }
    }

    private func takeContext(forTaskKey taskKey: TaskKey) -> TaskContext? {
        withLock {
            guard let context = contexts.removeValue(forKey: taskKey) else {
                return nil
            }

            taskKeysByDownloadID.removeValue(forKey: context.downloadID)
            return context
        }
    }

    private func updateContext(
        for taskKey: TaskKey,
        _ update: (inout TaskContext) -> Void
    ) -> TaskContext? {
        withLock {
            guard var context = contexts[taskKey] else {
                return nil
            }

            update(&context)
            contexts[taskKey] = context
            return context
        }
    }

    private func shouldIgnoreCompletion(taskKey: TaskKey, error: NSError) -> Bool {
        withLock {
            suppressedCompletionTaskKeys.remove(taskKey) != nil
        }
    }

    private func makeSession() -> URLSession {
        let perDownloadConnectionCount = withLock {
            transferSettings.perDownloadConnectionCount
        }

        let configuration = baseSessionConfiguration.copy() as! URLSessionConfiguration
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = perDownloadConnectionCount
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true

        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }

    private func makeTaskKey(session: URLSession, taskIdentifier: Int) -> TaskKey {
        "\(ObjectIdentifier(session))-\(taskIdentifier)"
    }

    nonisolated static func ownedDownloadRequest(
        sourceURL: URL,
        recovery: DirectDownloadRecoverySnapshot?
    ) -> URLRequest {
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let recovery,
           let validator = recovery.metadata.ifRangeValidator {
            request.setValue(
                "bytes=\(recovery.bytesWritten)-",
                forHTTPHeaderField: "Range"
            )
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        return request
    }

    nonisolated static func contentRange(
        from value: String?
    ) -> DirectDownloadContentRange? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }

        let payload = trimmed.dropFirst("bytes ".count)
        let components = payload.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else {
            return nil
        }

        let rangeComponents = components[0].split(separator: "-", maxSplits: 1)
        guard rangeComponents.count == 2,
              let start = Int64(rangeComponents[0]),
              let end = Int64(rangeComponents[1]),
              start >= 0,
              end >= start else {
            return nil
        }

        let total: Int64?
        if components[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = Int64(components[1]), parsedTotal > end else {
                return nil
            }
            total = parsedTotal
        }

        return DirectDownloadContentRange(start: start, end: end, total: total)
    }

    nonisolated static func unsatisfiedContentRangeTotal(
        from value: String?
    ) -> Int64? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes */") else {
            return nil
        }

        return Int64(trimmed.dropFirst("bytes */".count))
    }

    private func makeOwnedRequest(
        sourceURL: URL,
        recovery: DirectDownloadRecoverySnapshot?
    ) -> URLRequest {
        Self.ownedDownloadRequest(sourceURL: sourceURL, recovery: recovery)
    }

    private func expectedByteCount(for response: HTTPURLResponse) -> Int64 {
        if let contentRange = Self.contentRange(
            from: response.value(forHTTPHeaderField: "Content-Range")
        ), let total = contentRange.total {
            return total
        }

        // A 206 Content-Length covers only this response body. Without a
        // concrete Content-Range total, it cannot replace the saved whole-file
        // length or prove that a ranged download is complete.
        guard response.statusCode != 206,
              response.expectedContentLength > 0 else {
            return 0
        }

        return response.expectedContentLength
    }

    private func recoveryMetadata(
        for response: HTTPURLResponse,
        state: OwnedPartialState
    ) -> DirectDownloadRecoveryMetadata {
        DirectDownloadRecoveryMetadata(
            sourceURL: state.sourceURL,
            entityTag: response.value(forHTTPHeaderField: "ETag") ?? state.entityTag,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? state.lastModified,
            expectedBytes: state.expectedBytes,
            suggestedFilename: response.suggestedFilename ?? state.suggestedFilename,
            mimeType: response.mimeType ?? state.responseMimeType
        )
    }

    private static func responseDoesNotContradictSavedValidator(
        _ response: HTTPURLResponse,
        state: OwnedPartialState
    ) -> Bool {
        let savedMetadata = DirectDownloadRecoveryMetadata(
            sourceURL: state.sourceURL,
            entityTag: state.entityTag,
            lastModified: state.lastModified,
            expectedBytes: state.expectedBytes,
            suggestedFilename: state.suggestedFilename,
            mimeType: state.responseMimeType
        )
        guard let savedValidator = savedMetadata.ifRangeValidator else {
            return false
        }

        let responseHeader = savedValidator.hasPrefix("\"") ? "ETag" : "Last-Modified"
        guard let responseValidator = response.value(forHTTPHeaderField: responseHeader)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            // A 206 response means the origin accepted If-Range. Some origins do
            // not repeat the selected validator, so absence alone is not a
            // contradiction; an explicit mismatch is.
            return true
        }

        return responseValidator == savedValidator
    }

    nonisolated static func legacyDownloadHTTPFailure(
        statusCode: Int?,
        startedFromResumeData: Bool
    ) -> DirectDownloadFailure? {
        guard let statusCode, (200 ... 299).contains(statusCode) == false else {
            return nil
        }

        return DirectDownloadFailure(
            error: DirectDownloadHTTPStatusError(statusCode: statusCode),
            resumeData: nil,
            wasResuming: startedFromResumeData,
            httpStatusCode: statusCode
        )
    }

    private func closeOwnedFile(in context: TaskContext) {
        guard case let .ownedPartial(state) = context.mode else {
            return
        }
        try? state.fileHandle?.close()
    }

    private func recoverableOwnedByteCount(in context: TaskContext) -> Int64 {
        guard case let .ownedPartial(state) = context.mode else {
            return 0
        }

        if let snapshot = recoveryStore.snapshot(
            id: context.downloadID,
            sourceURL: state.sourceURL
        ) {
            return snapshot.bytesWritten
        }

        recoveryStore.discard(id: context.downloadID)
        return 0
    }

    private func claimedOwnedPartialURL(downloadID: UUID) throws -> URL {
        let claimedURL = ownedTemporaryDirectory
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")
        try recoveryStore.takeCompletedFile(id: downloadID, destinationURL: claimedURL)
        return claimedURL
    }

    nonisolated static func throttleDelay(
        deltaBytes: Int64,
        elapsed: TimeInterval,
        activeTransferCount: Int,
        transferSettings: DownloadTransferSettings,
        speedLimitOverride: TransferLimitOverride
    ) -> TimeInterval? {
        guard elapsed > 0,
              deltaBytes > 0,
              let effectiveLimit = effectiveSpeedLimit(
                activeTransferCount: activeTransferCount,
                transferSettings: transferSettings,
                speedLimitOverride: speedLimitOverride
              ),
              effectiveLimit > 0 else {
            return nil
        }

        let desiredElapsed = Double(deltaBytes) / Double(effectiveLimit)
        let delay = desiredElapsed - elapsed
        guard delay > 0 else {
            return nil
        }

        return max(delay, 0.1)
    }

    nonisolated static func effectiveSpeedLimit(
        activeTransferCount: Int,
        transferSettings: DownloadTransferSettings,
        speedLimitOverride: TransferLimitOverride
    ) -> Int64? {
        var limits: [Int64] = []

        if let globalSpeedLimit = transferSettings.globalSpeedLimitBytesPerSecond {
            limits.append(max(globalSpeedLimit / Int64(max(activeTransferCount, 1)), 1))
        }

        if let perDownloadSpeedLimit = speedLimitOverride.resolvedBytesPerSecond(
            inheriting: transferSettings.perDownloadSpeedLimitBytesPerSecond
        ) {
            limits.append(perDownloadSpeedLimit)
        }

        return limits.min()
    }

    private func suspendForThrottle(taskKey: TaskKey, delay: TimeInterval) {
        var shouldSuspend = false
        var throttleGeneration: UInt64?
        let task = updateContext(for: taskKey) { context in
            guard context.isThrottled == false else {
                return
            }

            context.isThrottled = true
            context.throttleGeneration &+= 1
            throttleGeneration = context.throttleGeneration
            shouldSuspend = true
        }?.task

        guard shouldSuspend, let task, let throttleGeneration else {
            return
        }

        task.suspend()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.resumeThrottledTask(
                taskKey: taskKey,
                throttleGeneration: throttleGeneration
            )
        }
    }

    private func resumeThrottledTask(
        taskKey: TaskKey,
        throttleGeneration: UInt64
    ) {
        var shouldResume = false
        let task = updateContext(for: taskKey) { context in
            guard context.isThrottled,
                  context.throttleGeneration == throttleGeneration else {
                return
            }

            context.isThrottled = false
            shouldResume = true
        }?.task

        if shouldResume {
            task?.resume()
        }
    }

    private func releaseThrottledTasksLocked() -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []

        for taskKey in Array(contexts.keys) {
            guard var context = contexts[taskKey], context.isThrottled else {
                continue
            }

            context.isThrottled = false
            context.throttleGeneration &+= 1
            contexts[taskKey] = context
            tasks.append(context.task)
        }

        return tasks
    }

    private func withLock<T>(_ work: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return work()
    }

    private func claimTemporaryDownload(
        at location: URL,
        downloadID: UUID
    ) throws -> URL {
        try fileManager.createDirectory(
            at: ownedTemporaryDirectory,
            withIntermediateDirectories: true
        )

        let claimedURL = ownedTemporaryDirectory
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")

        if fileManager.fileExists(atPath: claimedURL.path) {
            try fileManager.removeItem(at: claimedURL)
        }

        try fileManager.moveItem(at: location, to: claimedURL)
        return claimedURL
    }
}

extension DownloadCoordinator: URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode,
           (200 ... 299).contains(statusCode) == false {
            return
        }

        let taskKey = makeTaskKey(session: session, taskIdentifier: downloadTask.taskIdentifier)
        var throttleDelay: TimeInterval?

        guard let context = updateContext(for: taskKey, { context in
            let now = Date()
            let elapsed = now.timeIntervalSince(context.transferSample.sampleDate)
            guard elapsed >= 0.35 else {
                return
            }

            let deltaBytes = totalBytesWritten - context.transferSample.lastTotalBytesWritten
            let speed = elapsed > 0 ? Double(deltaBytes) / elapsed : context.transferSample.speedBytesPerSecond
            throttleDelay = Self.throttleDelay(
                deltaBytes: deltaBytes,
                elapsed: elapsed,
                activeTransferCount: contexts.count,
                transferSettings: transferSettings,
                speedLimitOverride: context.speedLimitOverride
            )
            context.transferSample = TransferSample(
                lastTotalBytesWritten: totalBytesWritten,
                sampleDate: now,
                speedBytesPerSecond: speed
            )
        }) else {
            return
        }

        eventHandler(
            .progress(
                id: context.downloadID,
                bytesWritten: totalBytesWritten,
                expectedBytes: totalBytesExpectedToWrite,
                speedBytesPerSecond: context.transferSample.speedBytesPerSecond
            )
        )

        if let throttleDelay {
            suspendForThrottle(taskKey: taskKey, delay: throttleDelay)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: dataTask.taskIdentifier)
        var responseError: Error?
        var responseStatusCode: Int?
        var responseWasResuming = false
        var resetReason: DirectDownloadRecoveryResetReason?
        var shouldFinishExistingPartial = false

        guard let updatedContext = updateContext(for: taskKey, { context in
            guard case var .ownedPartial(state) = context.mode else {
                responseError = URLError(.badServerResponse)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                responseError = URLError(.badServerResponse)
                return
            }

            let statusCode = httpResponse.statusCode
            responseStatusCode = statusCode
            responseWasResuming = state.resumeOffset > 0

            if responseWasResuming, statusCode == 416 {
                let total = Self.unsatisfiedContentRangeTotal(
                    from: httpResponse.value(forHTTPHeaderField: "Content-Range")
                )
                let matchesSavedTotal = state.expectedBytes <= 0
                    || total == state.expectedBytes
                if total == state.resumeOffset,
                   matchesSavedTotal,
                   Self.responseDoesNotContradictSavedValidator(
                       httpResponse,
                       state: state
                   ) {
                    state.expectedBytes = total ?? state.resumeOffset
                    state.statusCode = 206
                    context.mode = .ownedPartial(state)
                    shouldFinishExistingPartial = true
                    return
                }

                recoveryStore.discard(id: context.downloadID)
                responseError = DirectDownloadRecoveryRestartError()
                state.resumeOffset = 0
                state.bytesWritten = 0
                context.mode = .ownedPartial(state)
                return
            }

            guard (200 ... 299).contains(statusCode) else {
                responseError = DirectDownloadHTTPStatusError(statusCode: statusCode)
                return
            }

            do {
                let contentRange = Self.contentRange(
                    from: httpResponse.value(forHTTPHeaderField: "Content-Range")
                )
                if responseWasResuming {
                    if statusCode == 206 {
                        let matchesSavedTotal = state.expectedBytes <= 0
                            || contentRange?.total == nil
                            || contentRange?.total == state.expectedBytes
                        guard let contentRange,
                              contentRange.start == state.resumeOffset,
                              matchesSavedTotal,
                              Self.responseDoesNotContradictSavedValidator(
                                  httpResponse,
                                  state: state
                              ) else {
                            recoveryStore.discard(id: context.downloadID)
                            responseError = DirectDownloadRecoveryRestartError()
                            state.resumeOffset = 0
                            state.bytesWritten = 0
                            context.mode = .ownedPartial(state)
                            return
                        }

                        state.fileHandle = try recoveryStore.openFileForAppending(
                            id: context.downloadID,
                            expectedOffset: state.resumeOffset
                        )
                    } else if statusCode == 200 {
                        recoveryStore.discard(id: context.downloadID)
                        state.resumeOffset = 0
                        state.bytesWritten = 0
                        state.entityTag = nil
                        state.lastModified = nil
                        state.suggestedFilename = nil
                        state.responseMimeType = nil
                        state.fileHandle = try recoveryStore.openFreshFile(id: context.downloadID)
                        context.transferSample = TransferSample(
                            lastTotalBytesWritten: 0,
                            sampleDate: .now,
                            speedBytesPerSecond: 0
                        )
                        resetReason = .serverRejectedRange
                    } else {
                        recoveryStore.discard(id: context.downloadID)
                        responseError = DirectDownloadRecoveryRestartError()
                        state.resumeOffset = 0
                        state.bytesWritten = 0
                        context.mode = .ownedPartial(state)
                        return
                    }
                } else {
                    if statusCode == 206,
                       contentRange?.start != 0 {
                        responseError = URLError(.badServerResponse)
                        return
                    }
                    state.fileHandle = try recoveryStore.openFreshFile(id: context.downloadID)
                }

                let responseExpectedBytes = expectedByteCount(for: httpResponse)
                if responseExpectedBytes > 0 {
                    state.expectedBytes = responseExpectedBytes
                } else if resetReason != nil {
                    state.expectedBytes = 0
                }
                state.suggestedFilename = httpResponse.suggestedFilename ?? state.suggestedFilename
                state.responseMimeType = httpResponse.mimeType ?? state.responseMimeType
                state.statusCode = statusCode
                state.responseRangeEnd = contentRange?.end
                state.entityTag = httpResponse.value(forHTTPHeaderField: "ETag") ?? state.entityTag
                state.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? state.lastModified
                context.mode = .ownedPartial(state)

                try recoveryStore.saveMetadata(
                    recoveryMetadata(for: httpResponse, state: state),
                    id: context.downloadID
                )
            } catch {
                try? state.fileHandle?.close()
                state.fileHandle = nil
                context.mode = .ownedPartial(state)
                responseError = error
            }
        }) else {
            completionHandler(.cancel)
            return
        }

        if shouldFinishExistingPartial {
            guard let context = takeContext(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            closeOwnedFile(in: context)
            completionHandler(.cancel)

            do {
                let claimedURL = try claimedOwnedPartialURL(downloadID: context.downloadID)
                guard case let .ownedPartial(state) = context.mode else {
                    throw URLError(.badServerResponse)
                }
                eventHandler(
                    .finished(
                        id: context.downloadID,
                        temporaryURL: claimedURL,
                        suggestedFilename: state.suggestedFilename,
                        responseMimeType: state.responseMimeType,
                        statusCode: state.statusCode
                    )
                )
            } catch {
                eventHandler(
                    .failed(
                        id: context.downloadID,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: true,
                            recoverableBytes: recoverableOwnedByteCount(in: context)
                        )
                    )
                )
            }
            context.session.finishTasksAndInvalidate()
            return
        }

        if let responseError {
            guard let context = takeContext(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            closeOwnedFile(in: context)
            completionHandler(.cancel)
            eventHandler(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: responseError,
                        resumeData: nil,
                        wasResuming: responseWasResuming,
                        recoverableBytes: recoverableOwnedByteCount(in: context),
                        httpStatusCode: responseStatusCode
                    )
                )
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        if let resetReason {
            eventHandler(.recoveryReset(id: updatedContext.downloadID, reason: resetReason))
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: dataTask.taskIdentifier)
        var writeError: Error?
        var throttleDelay: TimeInterval?
        var progress: (id: UUID, bytesWritten: Int64, expectedBytes: Int64, speed: Double)?

        guard let context = updateContext(for: taskKey, { context in
            guard case var .ownedPartial(state) = context.mode,
                  let fileHandle = state.fileHandle else {
                writeError = CocoaError(.fileWriteUnknown)
                return
            }

            do {
                let receivedByteCount = Int64(data.count)
                if let responseRangeEnd = state.responseRangeEnd,
                   receivedByteCount > 0 {
                    let startsBeyondDeclaredRange = state.bytesWritten > responseRangeEnd
                        || state.bytesWritten == Int64.max
                    let exceedsDeclaredRange = startsBeyondDeclaredRange
                        || receivedByteCount - 1 > responseRangeEnd - state.bytesWritten
                    if exceedsDeclaredRange {
                        let permittedByteCount = startsBeyondDeclaredRange
                            ? 0
                            : responseRangeEnd - state.bytesWritten + 1
                        if permittedByteCount > 0 {
                            try fileHandle.write(
                                contentsOf: Data(data.prefix(Int(permittedByteCount)))
                            )
                            state.bytesWritten += permittedByteCount
                        }
                        writeError = DirectDownloadRangeOverflowError(
                            declaredEnd: responseRangeEnd
                        )
                        context.mode = .ownedPartial(state)
                        return
                    }
                }

                try fileHandle.write(contentsOf: data)
                state.bytesWritten += receivedByteCount

                let now = Date()
                let elapsed = now.timeIntervalSince(context.transferSample.sampleDate)
                if elapsed >= 0.35 {
                    let deltaBytes = state.bytesWritten - context.transferSample.lastTotalBytesWritten
                    let speed = elapsed > 0
                        ? Double(deltaBytes) / elapsed
                        : context.transferSample.speedBytesPerSecond
                    throttleDelay = Self.throttleDelay(
                        deltaBytes: deltaBytes,
                        elapsed: elapsed,
                        activeTransferCount: contexts.count,
                        transferSettings: transferSettings,
                        speedLimitOverride: context.speedLimitOverride
                    )
                    context.transferSample = TransferSample(
                        lastTotalBytesWritten: state.bytesWritten,
                        sampleDate: now,
                        speedBytesPerSecond: speed
                    )
                }

                progress = (
                    id: context.downloadID,
                    bytesWritten: state.bytesWritten,
                    expectedBytes: state.expectedBytes,
                    speed: context.transferSample.speedBytesPerSecond
                )
                context.mode = .ownedPartial(state)
            } catch {
                writeError = error
                context.mode = .ownedPartial(state)
            }
        }) else {
            return
        }

        if let writeError {
            guard let failedContext = takeContext(forTaskKey: taskKey) else {
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            closeOwnedFile(in: failedContext)
            failedContext.task.cancel()
            failedContext.session.finishTasksAndInvalidate()
            let wasResuming: Bool
            if case let .ownedPartial(state) = failedContext.mode {
                wasResuming = state.resumeOffset > 0
            } else {
                wasResuming = false
            }
            eventHandler(
                .failed(
                    id: failedContext.downloadID,
                    failure: DirectDownloadFailure(
                        error: writeError,
                        resumeData: nil,
                        wasResuming: wasResuming,
                        recoverableBytes: recoverableOwnedByteCount(in: failedContext)
                    )
                )
            )
            return
        }

        if let progress {
            eventHandler(
                .progress(
                    id: progress.id,
                    bytesWritten: progress.bytesWritten,
                    expectedBytes: progress.expectedBytes,
                    speedBytesPerSecond: progress.speed
                )
            )
        }

        if let throttleDelay {
            suspendForThrottle(taskKey: taskKey, delay: throttleDelay)
        }
        _ = context
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: downloadTask.taskIdentifier)
        guard let context = takeContext(forTaskKey: taskKey) else {
            return
        }

        let startedFromResumeData: Bool
        if case let .legacyDownload(started) = context.mode {
            startedFromResumeData = started
        } else {
            startedFromResumeData = false
        }

        if let failure = Self.legacyDownloadHTTPFailure(
            statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode,
            startedFromResumeData: startedFromResumeData
        ) {
            eventHandler(.failed(id: context.downloadID, failure: failure))
            context.session.finishTasksAndInvalidate()
            return
        }

        do {
            let claimedURL = try claimTemporaryDownload(
                at: location,
                downloadID: context.downloadID
            )

            eventHandler(
                .finished(
                    id: context.downloadID,
                    temporaryURL: claimedURL,
                    suggestedFilename: downloadTask.response?.suggestedFilename,
                    responseMimeType: downloadTask.response?.mimeType,
                    statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode
                )
            )
        } catch {
            eventHandler(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: startedFromResumeData
                    )
                )
            )
        }

        context.session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        guard let context = withLock({ contexts[taskKey] }),
              case let .ownedPartial(state) = context.mode else {
            completionHandler(request)
            return
        }

        var redirectedRequest = request
        redirectedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if state.resumeOffset > 0 {
            redirectedRequest.setValue(
                "bytes=\(state.resumeOffset)-",
                forHTTPHeaderField: "Range"
            )
            let validator = DirectDownloadRecoveryMetadata(
                sourceURL: state.sourceURL,
                entityTag: state.entityTag,
                lastModified: state.lastModified,
                expectedBytes: state.expectedBytes,
                suggestedFilename: state.suggestedFilename,
                mimeType: state.responseMimeType
            ).ifRangeValidator
            redirectedRequest.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        if let error {
            let nsError = error as NSError
            if shouldIgnoreCompletion(taskKey: taskKey, error: nsError) {
                return
            }

            guard let context = takeContext(forTaskKey: taskKey) else {
                return
            }

            closeOwnedFile(in: context)
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let wasResuming: Bool
            let recoverableBytes: Int64?
            switch context.mode {
            case let .legacyDownload(startedFromResumeData):
                wasResuming = startedFromResumeData
                recoverableBytes = nil
            case let .ownedPartial(state):
                wasResuming = state.resumeOffset > 0
                recoverableBytes = recoverableOwnedByteCount(in: context)
            }

            eventHandler(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: nsError,
                        resumeData: resumeData,
                        wasResuming: wasResuming,
                        recoverableBytes: recoverableBytes
                    )
                )
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        guard let context = takeContext(forTaskKey: taskKey),
              case let .ownedPartial(state) = context.mode else {
            return
        }

        closeOwnedFile(in: context)
        let actualBytes = recoveryStore.recoveredByteCount(id: context.downloadID)
            ?? state.bytesWritten
        let matchesDeclaredRange = state.responseRangeEnd.map {
            actualBytes > 0 && actualBytes - 1 == $0
        } ?? true
        let matchesDeclaredTotal = state.expectedBytes <= 0
            || actualBytes == state.expectedBytes
        let hasVerifiableCompleteLength = state.statusCode != 206
            || state.expectedBytes > 0

        guard matchesDeclaredRange,
              matchesDeclaredTotal,
              hasVerifiableCompleteLength else {
            let expectedBytes = state.expectedBytes > 0 ? state.expectedBytes : nil
            eventHandler(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: DirectDownloadIncompleteResponseError(
                            actualBytes: actualBytes,
                            expectedBytes: expectedBytes
                        ),
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        do {
            let claimedURL = try claimedOwnedPartialURL(downloadID: context.downloadID)
            eventHandler(
                .finished(
                    id: context.downloadID,
                    temporaryURL: claimedURL,
                    suggestedFilename: state.suggestedFilename,
                    responseMimeType: state.responseMimeType,
                    statusCode: state.statusCode
                )
            )
        } catch {
            eventHandler(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
        }
        context.session.finishTasksAndInvalidate()
    }
}
