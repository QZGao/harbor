import Foundation

private struct DirectDownloadRecoveryRestartError: LocalizedError {
    var errorDescription: String? {
        "The server did not accept the saved partial download."
    }
}

struct DirectDownloadIncompleteResponseError: LocalizedError {
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

private struct DirectDownloadBodyOverflowError: LocalizedError {
    let expectedBytes: Int64

    var errorDescription: String? {
        "The server sent data beyond its declared body length of \(expectedBytes) bytes."
    }
}

struct DirectDownloadInvalidRangeResponseError: LocalizedError {
    var errorDescription: String? {
        "The server returned an invalid or contradictory byte-range response."
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
    private let freshStartOverride: Bool

    var isRetryable: Bool {
        DirectDownloadRetryPolicy.isRetryable(urlErrorCode)
            || DirectDownloadRetryPolicy.isRetryableHTTPStatus(httpStatusCode)
            || retryableOverride
            || (
                httpStatusCode == nil
                    && urlErrorCode != nil
                    && wasResuming
                    && resumeData == nil
                    && recoverableBytes == nil
            )
    }

    var requiresFreshStart: Bool {
        freshStartOverride || (resumeData == nil && (recoverableBytes ?? 0) == 0)
    }

    nonisolated init(
        error: Error,
        resumeData: Data?,
        wasResuming: Bool = false,
        recoverableBytes: Int64? = nil,
        httpStatusCode: Int? = nil,
        forcesFreshStart: Bool = false
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
            || error is DirectDownloadBodyOverflowError
            || error is DirectDownloadInvalidRangeResponseError
        self.freshStartOverride = forcesFreshStart
            || error is DirectDownloadRecoveryRestartError
    }
}

struct DirectDownloadPauseResult: Sendable {
    let attemptIdentifier: UUID?
    let resumeData: Data?
    let ownedRecovery: DirectDownloadRecoverySnapshot?
    let recoveryUnavailableMessage: String?

    nonisolated init(
        attemptIdentifier: UUID?,
        resumeData: Data?,
        ownedRecovery: DirectDownloadRecoverySnapshot?,
        recoveryUnavailableMessage: String? = nil
    ) {
        self.attemptIdentifier = attemptIdentifier
        self.resumeData = resumeData
        self.ownedRecovery = ownedRecovery
        self.recoveryUnavailableMessage = recoveryUnavailableMessage
    }
}

struct DirectDownloadContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?
}

struct DirectDownloadHTTPStatusError: LocalizedError {
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

    nonisolated static func isRetryableHTTPStatus(_ statusCode: Int?) -> Bool {
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
        attemptIdentifier: UUID,
        taskIdentifier: Int,
        usesOwnedPartial: Bool,
        ownedRecovery: DirectDownloadRecoverySnapshot?,
        resetReason: DirectDownloadRecoveryResetReason?
    )
    case recoveryReset(id: UUID, attemptIdentifier: UUID, reason: DirectDownloadRecoveryResetReason)
    case progress(
        id: UUID,
        attemptIdentifier: UUID,
        bytesWritten: Int64,
        expectedBytes: Int64,
        speedBytesPerSecond: Double
    )
    case finished(
        id: UUID,
        attemptIdentifier: UUID,
        handoff: CompletedDownloadHandoff
    )
    case failed(id: UUID, attemptIdentifier: UUID, failure: DirectDownloadFailure)
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
        var declaredExpectedBytes: Int64?
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var responseRangeEnd: Int64?
        var entityTag: String?
        var lastModified: String?
        var fileHandle: FileHandle?
    }

    private enum TaskMode {
        case legacyDownload(
            startedFromResumeData: Bool,
            resumeOffset: Int64?,
            resumeValidator: String?
        )
        case ownedPartial(OwnedPartialState)
    }

    private struct CompletionPublicationState {
        let context: TaskContext
        var waiters: [CheckedContinuation<DirectDownloadPauseResult, Never>] = []
    }

    private struct TaskContext: @unchecked Sendable {
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
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
    private let completedHandoffStore: CompletedDownloadHandoffStore
    private let baseSessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue
    private let completionQueue = DispatchQueue(
        label: "Harbor.DownloadCompletionPublication",
        qos: .utility,
        attributes: .concurrent
    )

    private var contexts: [TaskKey: TaskContext] = [:]
    private var taskKeysByDownloadID: [UUID: TaskKey] = [:]
    private var reservedDownloadIDs: Set<UUID> = []
    private var suppressedCompletionTaskKeys: Set<TaskKey> = []
    private var completionPublications: [UUID: CompletionPublicationState] = [:]
    private var completedPublicationPauseResults: [UUID: DirectDownloadPauseResult] = [:]
    private var transferSettings: DownloadTransferSettings

    init(
        transferSettings: DownloadTransferSettings = .default,
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default,
        recoveryDirectoryURL: URL? = nil,
        temporaryDirectory: URL? = nil,
        completedHandoffStore: CompletedDownloadHandoffStore? = nil,
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
        self.completedHandoffStore = completedHandoffStore
            ?? CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: temporaryDirectory
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
            closeOwnedFile(in: context, preservingRecovery: false)
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
        attemptIdentifier: UUID = UUID(),
        sourceURL: URL,
        resumeData: Data?,
        speedLimitOverride: TransferLimitOverride = .inherit
    ) throws -> Int {
        guard withLock({
            guard taskKeysByDownloadID[id] == nil,
                  reservedDownloadIDs.contains(id) == false else {
                return false
            }
            reservedDownloadIDs.insert(id)
            return true
        }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var installedContext = false
        defer {
            if installedContext == false {
                _ = withLock {
                    reservedDownloadIDs.remove(id)
                }
            }
        }

        let session = makeSession()
        defer {
            if installedContext == false {
                session.invalidateAndCancel()
            }
        }
        let task: URLSessionTask
        let mode: TaskMode
        let ownedRecovery: DirectDownloadRecoverySnapshot?
        let resetReason: DirectDownloadRecoveryResetReason?

        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            mode = .legacyDownload(
                startedFromResumeData: true,
                resumeOffset: Self.legacyResumeByteCount(from: resumeData),
                resumeValidator: Self.legacyResumeValidator(from: resumeData)
            )
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
                    declaredExpectedBytes: nil,
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
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
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
            reservedDownloadIDs.remove(id)
            suppressedCompletionTaskKeys.remove(key)
            completedPublicationPauseResults.removeValue(forKey: id)
        }
        installedContext = true

        eventHandler(
            .started(
                id: id,
                attemptIdentifier: attemptIdentifier,
                taskIdentifier: task.taskIdentifier,
                usesOwnedPartial: resumeData == nil,
                ownedRecovery: ownedRecovery,
                resetReason: resetReason
            )
        )
        // Publish ownership before the task can produce response/progress
        // callbacks. The delegate queue is serial, but its events are bridged
        // to another executor by the caller and must not overtake `.started`.
        task.resume()
        return task.taskIdentifier
    }

    /// Stops an active task and returns the resume data only after URLSession has produced it.
    ///
    /// Pause and shutdown paths await this form so persistence cannot race the
    /// asynchronous `cancel(byProducingResumeData:)` callback.
    func pauseDownloadAndWait(id: UUID) async -> DirectDownloadPauseResult {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            return await waitForCompletionPublication(id: id)
        }

        switch context.mode {
        case .legacyDownload:
            guard let downloadTask = context.task as? URLSessionDownloadTask else {
                context.task.cancel()
                context.session.finishTasksAndInvalidate()
                return DirectDownloadPauseResult(
                    attemptIdentifier: context.attemptIdentifier,
                    resumeData: nil,
                    ownedRecovery: nil
                )
            }

            return await withCheckedContinuation { continuation in
                downloadTask.cancel(byProducingResumeData: { [session = context.session] resumeData in
                    session.finishTasksAndInvalidate()
                    continuation.resume(
                        returning: DirectDownloadPauseResult(
                            attemptIdentifier: context.attemptIdentifier,
                            resumeData: resumeData,
                            ownedRecovery: nil
                        )
                    )
                })
            }

        case let .ownedPartial(state):
            let didPreserveRecovery = closeOwnedFile(
                in: context,
                preservingRecovery: true
            )
            context.task.cancel()
            context.session.finishTasksAndInvalidate()
            let lookup = didPreserveRecovery
                ? recoveryStore.lookup(id: id, sourceURL: state.sourceURL)
                : .absent
            let ownedRecovery: DirectDownloadRecoverySnapshot?
            let unavailableMessage: String?
            switch lookup {
            case let .available(snapshot):
                ownedRecovery = snapshot
                unavailableMessage = nil
            case .absent:
                ownedRecovery = nil
                unavailableMessage = nil
            case let .unavailable(message):
                ownedRecovery = nil
                unavailableMessage = message
            }
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                resumeData: nil,
                ownedRecovery: ownedRecovery,
                recoveryUnavailableMessage: unavailableMessage
            )
        }
    }

    func cancelDownload(id: UUID) {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            let ownsCompletion = withLock {
                completionPublications[id] != nil
                    || completedPublicationPauseResults[id]?.attemptIdentifier != nil
            }
            guard ownsCompletion == false else {
                return
            }
            recoveryStore.discard(id: id)
            return
        }

        closeOwnedFile(in: context, preservingRecovery: false)
        context.task.cancel()
        context.session.invalidateAndCancel()
        recoveryStore.discard(id: id)
    }

    func discardRecoveryData(id: UUID) {
        try? discardRecoveryDataOrThrow(id: id)
    }

    func discardRecoveryDataOrThrow(id: UUID) throws {
        withLock {
            completedPublicationPauseResults.removeValue(forKey: id)
        }
        try recoveryStore.discardThrowing(id: id)
        try completedHandoffStore.discardThrowing(downloadID: id)
    }

    func acknowledgeTerminalOutcome(
        id: UUID,
        attemptIdentifier: UUID
    ) {
        _ = withLock {
            guard completedPublicationPauseResults[id]?.attemptIdentifier
                    == attemptIdentifier else {
                return
            }
            completedPublicationPauseResults.removeValue(forKey: id)
        }
    }

    func discardOwnedRecoveryData(id: UUID) {
        try? discardOwnedRecoveryDataOrThrow(id: id)
    }

    func discardOwnedRecoveryDataOrThrow(id: UUID) throws {
        _ = withLock {
            completedPublicationPauseResults.removeValue(forKey: id)
        }
        try recoveryStore.discardThrowing(id: id)
    }

    func discardOrphanedRecoveryData(retaining retainedIDs: Set<UUID>) {
        recoveryStore.discardOrphans(retaining: retainedIDs)
    }

    func discardOrphanedTemporaryFiles() {
        completedHandoffStore.discardLegacyUnvalidatedFiles(
            in: ownedTemporaryDirectory
        )
    }

    func recoverySnapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        recoveryStore.snapshot(id: id, sourceURL: sourceURL)
    }

    func recoveryLookup(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoveryLookup {
        recoveryStore.lookup(id: id, sourceURL: sourceURL)
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

            if taskKeysByDownloadID[context.downloadID] == taskKey {
                taskKeysByDownloadID.removeValue(forKey: context.downloadID)
            }
            return context
        }
    }

    private func beginCompletionPublication(forTaskKey taskKey: TaskKey) -> TaskContext? {
        withLock {
            guard let context = contexts.removeValue(forKey: taskKey),
                  completionPublications[context.downloadID] == nil else {
                return nil
            }
            if taskKeysByDownloadID[context.downloadID] == taskKey {
                taskKeysByDownloadID.removeValue(forKey: context.downloadID)
            }
            completionPublications[context.downloadID] = CompletionPublicationState(
                context: context
            )
            return context
        }
    }

    private func finishCompletionPublication(
        context: TaskContext,
        resumeData: Data? = nil,
        ownedRecovery: DirectDownloadRecoverySnapshot? = nil,
        recoveryUnavailableMessage: String?
    ) {
        let result = DirectDownloadPauseResult(
            attemptIdentifier: context.attemptIdentifier,
            resumeData: resumeData,
            ownedRecovery: ownedRecovery,
            recoveryUnavailableMessage: recoveryUnavailableMessage
        )
        let waiters = withLock { () -> [CheckedContinuation<DirectDownloadPauseResult, Never>] in
            guard let publication = completionPublications[context.downloadID],
                  publication.context.attemptIdentifier == context.attemptIdentifier else {
                return []
            }
            completionPublications.removeValue(forKey: context.downloadID)
            completedPublicationPauseResults[context.downloadID] = result
            return publication.waiters
        }
        waiters.forEach { $0.resume(returning: result) }
    }

    private func ownedPauseResult(
        for context: TaskContext,
        didPreserveRecovery: Bool
    ) -> DirectDownloadPauseResult {
        guard case let .ownedPartial(state) = context.mode,
              didPreserveRecovery else {
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                resumeData: nil,
                ownedRecovery: nil
            )
        }
        switch recoveryStore.lookup(id: context.downloadID, sourceURL: state.sourceURL) {
        case let .available(snapshot):
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                resumeData: nil,
                ownedRecovery: snapshot
            )
        case .absent:
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                resumeData: nil,
                ownedRecovery: nil
            )
        case let .unavailable(message):
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                resumeData: nil,
                ownedRecovery: nil,
                recoveryUnavailableMessage: message
            )
        }
    }

    private func waitForCompletionPublication(
        id: UUID
    ) async -> DirectDownloadPauseResult {
        if let completed = withLock({
            completedPublicationPauseResults.removeValue(forKey: id)
        }) {
            return completed
        }

        return await withCheckedContinuation { continuation in
            let shouldReturnNil = withLock { () -> Bool in
                if let completed = completedPublicationPauseResults.removeValue(forKey: id) {
                    continuation.resume(returning: completed)
                    return false
                }
                guard var publication = completionPublications[id] else {
                    return true
                }
                publication.waiters.append(continuation)
                completionPublications[id] = publication
                return false
            }
            if shouldReturnNil {
                continuation.resume(
                    returning: DirectDownloadPauseResult(
                        attemptIdentifier: nil,
                        resumeData: nil,
                        ownedRecovery: nil
                    )
                )
            }
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

        guard let total = Int64(trimmed.dropFirst("bytes */".count)), total >= 0 else {
            return nil
        }
        return total
    }

    private func makeOwnedRequest(
        sourceURL: URL,
        recovery: DirectDownloadRecoverySnapshot?
    ) -> URLRequest {
        Self.ownedDownloadRequest(sourceURL: sourceURL, recovery: recovery)
    }

    private func expectedByteCount(for response: HTTPURLResponse) throws -> Int64? {
        if let contentRange = Self.contentRange(
            from: response.value(forHTTPHeaderField: "Content-Range")
        ), let total = contentRange.total {
            return total
        }

        // A 206 Content-Length covers only this response body. Without a
        // concrete Content-Range total, it cannot replace the saved whole-file
        // length or prove that a ranged download is complete.
        guard response.statusCode != 206 else {
            return nil
        }
        return try Self.declaredContentLength(response)
            ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
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

    private static func responseMatchesSavedValidator(
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
            return false
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

    nonisolated static func legacyResumeByteCount(from resumeData: Data) -> Int64? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: resumeData,
            options: [],
            format: nil
        ),
        let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        let keys = [
            "NSURLSessionResumeBytesReceived",
            "NSURLSessionResumeInfoBytesReceived"
        ]
        for key in keys {
            if let number = dictionary[key] as? NSNumber,
               number.int64Value >= 0 {
                return number.int64Value
            }
            if let text = dictionary[key] as? String,
               let value = Int64(text), value >= 0 {
                return value
            }
        }
        return nil
    }

    nonisolated static func legacyResumeValidator(from resumeData: Data) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: resumeData,
            options: [],
            format: nil
        ), let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        for key in ["NSURLSessionResumeEntityTag", "NSURLSessionResumeInfoEntityTag"] {
            guard let raw = dictionary[key] as? String else {
                continue
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty == false,
               value.uppercased().hasPrefix("W/") == false,
               value.first == "\"",
               value.last == "\"" {
                return value
            }
        }
        for key in ["NSURLSessionResumeLastModified", "NSURLSessionResumeInfoLastModified"] {
            if let raw = dictionary[key] as? String {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty == false {
                    return value
                }
            }
        }
        return nil
    }

    @discardableResult
    private func closeOwnedFile(
        in context: TaskContext,
        preservingRecovery: Bool
    ) -> Bool {
        guard case let .ownedPartial(state) = context.mode else {
            return true
        }
        guard let fileHandle = state.fileHandle else {
            return true
        }

        do {
            if preservingRecovery {
                try fileHandle.synchronize()
            }
            try fileHandle.close()
            return true
        } catch {
            try? fileHandle.close()
            if preservingRecovery {
                recoveryStore.discard(id: context.downloadID)
            }
            return false
        }
    }

    private func sealOwnedFile(in context: TaskContext) throws {
        guard case let .ownedPartial(state) = context.mode,
              let fileHandle = state.fileHandle else {
            return
        }
        do {
            try fileHandle.synchronize()
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            recoveryStore.discard(id: context.downloadID)
            throw error
        }
    }

    private func recoverableOwnedByteCount(in context: TaskContext) -> Int64? {
        guard case let .ownedPartial(state) = context.mode else {
            return nil
        }

        switch recoveryStore.lookup(
            id: context.downloadID,
            sourceURL: state.sourceURL
        ) {
        case let .available(snapshot):
            return snapshot.bytesWritten
        case .absent:
            return 0
        case .unavailable:
            // The file handle was synchronized before this lookup. Preserve
            // the last byte count instead of converting a transient lookup
            // failure into a destructive fresh retry.
            return state.bytesWritten > 0 ? state.bytesWritten : nil
        }
    }

    private func publishOwnedPartial(
        context: TaskContext,
        state: OwnedPartialState
    ) throws -> CompletedDownloadHandoff {
        try recoveryStore.publishCompletedPayload(
            id: context.downloadID,
            expectedBytes: state.expectedBytes
        ) { payloadURL in
            let actualBytes = try fileSize(at: payloadURL)
            return try completedHandoffStore.publish(
                payloadAt: payloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    owner: .direct,
                    sourceURL: context.sourceURL,
                    statusCode: state.statusCode,
                    mimeType: state.responseMimeType,
                    suggestedFilename: state.suggestedFilename,
                    actualBytes: actualBytes,
                    expectedBytes: state.expectedBytes
                )
            )
        }
    }

    private func claimOwnedPartial(
        context: TaskContext,
        state: OwnedPartialState
    ) throws -> CompletedDownloadHandoffClaim {
        try recoveryStore.publishCompletedPayload(
            id: context.downloadID,
            expectedBytes: state.expectedBytes
        ) { payloadURL in
            let actualBytes = try fileSize(at: payloadURL)
            return try completedHandoffStore.claim(
                payloadAt: payloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    owner: .direct,
                    sourceURL: context.sourceURL,
                    statusCode: state.statusCode,
                    mimeType: state.responseMimeType,
                    suggestedFilename: state.suggestedFilename,
                    actualBytes: actualBytes,
                    expectedBytes: state.expectedBytes
                )
            )
        }
    }

    private func claimLegacyDownload(
        at location: URL,
        context: TaskContext,
        response: HTTPURLResponse,
        startedFromResumeData: Bool,
        resumeOffset: Int64?,
        resumeValidator: String?
    ) throws -> CompletedDownloadHandoffClaim {
        let actualBytes = try fileSize(at: location)
        let expectedBytes = try Self.validatedCompletedByteCount(
            response: response,
            actualBytes: actualBytes,
            startedFromResumeData: startedFromResumeData,
            resumeOffset: resumeOffset,
            resumeValidator: resumeValidator
        )
        return try completedHandoffStore.claim(
            payloadAt: location,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                owner: .direct,
                sourceURL: context.sourceURL,
                statusCode: response.statusCode,
                mimeType: response.mimeType,
                suggestedFilename: response.suggestedFilename,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
        )
    }

    private func finalizeCompletionClaim(
        _ claim: CompletedDownloadHandoffClaim,
        context: TaskContext,
        wasResuming: Bool,
        httpStatusCode: Int?
    ) {
        completionQueue.async { [self] in
            var publicationFailureMessage: String?
            do {
                let handoff = try completedHandoffStore.finalize(claim)
                eventHandler(
                    .finished(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        handoff: handoff
                    )
                )
            } catch {
                if completedHandoffStore.ownsAttempt(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                ) {
                    publicationFailureMessage = error.localizedDescription
                }
                eventHandler(
                    .failed(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: wasResuming,
                            recoverableBytes: 0,
                            httpStatusCode: httpStatusCode
                        )
                    )
                )
            }
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: publicationFailureMessage
            )
            context.session.finishTasksAndInvalidate()
        }
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

    private func publishLegacyDownload(
        at location: URL,
        context: TaskContext,
        response: HTTPURLResponse,
        startedFromResumeData: Bool,
        resumeOffset: Int64?,
        resumeValidator: String?
    ) throws -> CompletedDownloadHandoff {
        let actualBytes = try fileSize(at: location)
        let expectedBytes = try Self.validatedCompletedByteCount(
            response: response,
            actualBytes: actualBytes,
            startedFromResumeData: startedFromResumeData,
            resumeOffset: resumeOffset,
            resumeValidator: resumeValidator
        )
        return try completedHandoffStore.publish(
            payloadAt: location,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                owner: .direct,
                sourceURL: context.sourceURL,
                statusCode: response.statusCode,
                mimeType: response.mimeType,
                suggestedFilename: response.suggestedFilename,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
        )
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Int64(size)
    }

    nonisolated static func validatedCompletedByteCount(
        response: HTTPURLResponse,
        actualBytes: Int64,
        startedFromResumeData: Bool,
        resumeOffset: Int64?,
        resumeValidator: String? = nil
    ) throws -> Int64 {
        guard actualBytes >= 0 else {
            throw URLError(.badServerResponse)
        }
        guard responseUsesIdentityEncoding(response) else {
            throw URLError(.cannotDecodeContentData)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw DirectDownloadHTTPStatusError(statusCode: response.statusCode)
        }

        if response.statusCode == 206 {
            let range = try validatedPartialContentRange(response)
            guard startedFromResumeData,
                  let resumeOffset,
                  let resumeValidator,
                  range.start == resumeOffset,
                  let total = range.total,
                  range.start > 0,
                  range.end == total - 1,
                  total == actualBytes,
                  responseValidator(response, matching: resumeValidator) else {
                throw DirectDownloadIncompleteResponseError(
                    actualBytes: actualBytes,
                    expectedBytes: contentRange(
                        from: response.value(forHTTPHeaderField: "Content-Range")
                    )?.total
                )
            }
            return total
        }

        guard response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw URLError(.badServerResponse)
        }
        let declaredLength = try declaredContentLength(response)
            ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        if let declaredLength, declaredLength != actualBytes {
            throw DirectDownloadIncompleteResponseError(
                actualBytes: actualBytes,
                expectedBytes: declaredLength
            )
        }
        return actualBytes
    }

    private nonisolated static func responseValidator(
        _ response: HTTPURLResponse,
        matching savedValidator: String
    ) -> Bool {
        let headerName = savedValidator.hasPrefix("\"") ? "ETag" : "Last-Modified"
        guard let value = response.value(forHTTPHeaderField: headerName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return value == savedValidator
    }

    nonisolated static func validatedPartialContentRange(
        _ response: HTTPURLResponse
    ) throws -> DirectDownloadContentRange {
        guard responseUsesIdentityEncoding(response),
              let range = contentRange(
                  from: response.value(forHTTPHeaderField: "Content-Range")
              ),
              range.total != nil else {
            throw DirectDownloadInvalidRangeResponseError()
        }

        let bodyLength = range.end - range.start + 1
        if let declaredLength = try declaredContentLength(response),
           declaredLength != bodyLength {
            throw DirectDownloadInvalidRangeResponseError()
        }
        return range
    }

    nonisolated static func declaredContentLength(
        _ response: HTTPURLResponse
    ) throws -> Int64? {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(trimmed), value >= 0 else {
            throw URLError(.badServerResponse)
        }
        return value
    }

    nonisolated static func responseUsesIdentityEncoding(
        _ response: HTTPURLResponse
    ) -> Bool {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Encoding") else {
            return true
        }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("identity") == .orderedSame
    }

    private nonisolated static func isInvalidResumeProtocolResponse(
        _ error: Error
    ) -> Bool {
        if error is DirectDownloadInvalidRangeResponseError {
            return true
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        return code == .badServerResponse || code == .cannotDecodeContentData
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
                attemptIdentifier: context.attemptIdentifier,
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
        var responseRequiresFreshStart = false

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
                   Self.responseMatchesSavedValidator(
                       httpResponse,
                       state: state
                   ) {
                    state.expectedBytes = total ?? state.resumeOffset
                    state.declaredExpectedBytes = total
                    state.statusCode = 206
                    context.mode = .ownedPartial(state)
                    shouldFinishExistingPartial = true
                    return
                }

                responseRequiresFreshStart = true
                do {
                    try recoveryStore.discardThrowing(id: context.downloadID)
                    responseError = DirectDownloadRecoveryRestartError()
                } catch {
                    responseError = error
                }
                state.resumeOffset = 0
                state.bytesWritten = 0
                state.declaredExpectedBytes = nil
                context.mode = .ownedPartial(state)
                return
            }

            guard (200 ... 299).contains(statusCode) else {
                responseError = DirectDownloadHTTPStatusError(statusCode: statusCode)
                return
            }

            do {
                guard statusCode == 200 || statusCode == 206,
                      Self.responseUsesIdentityEncoding(httpResponse) else {
                    throw URLError(.badServerResponse)
                }
                let contentRange: DirectDownloadContentRange?
                if statusCode == 206 {
                    contentRange = try Self.validatedPartialContentRange(httpResponse)
                } else {
                    guard httpResponse.value(forHTTPHeaderField: "Content-Range") == nil else {
                        throw URLError(.badServerResponse)
                    }
                    _ = try Self.declaredContentLength(httpResponse)
                    contentRange = nil
                }
                if responseWasResuming {
                    if statusCode == 206 {
                        let matchesSavedTotal = state.expectedBytes <= 0
                            || contentRange?.total == state.expectedBytes
                        guard let contentRange,
                              contentRange.start == state.resumeOffset,
                              matchesSavedTotal,
                              Self.responseMatchesSavedValidator(
                                  httpResponse,
                                  state: state
                              ) else {
                            responseRequiresFreshStart = true
                            do {
                                try recoveryStore.discardThrowing(id: context.downloadID)
                                responseError = DirectDownloadRecoveryRestartError()
                            } catch {
                                responseError = error
                            }
                            state.resumeOffset = 0
                            state.bytesWritten = 0
                            state.declaredExpectedBytes = nil
                            context.mode = .ownedPartial(state)
                            return
                        }

                        state.fileHandle = try recoveryStore.openFileForAppending(
                            id: context.downloadID,
                            expectedOffset: state.resumeOffset
                        )
                    } else if statusCode == 200 {
                        responseRequiresFreshStart = true
                        do {
                            try recoveryStore.discardThrowing(id: context.downloadID)
                        } catch {
                            responseError = error
                            context.mode = .ownedPartial(state)
                            return
                        }
                        state.resumeOffset = 0
                        state.bytesWritten = 0
                        state.declaredExpectedBytes = nil
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
                        responseRequiresFreshStart = true
                        do {
                            try recoveryStore.discardThrowing(id: context.downloadID)
                            responseError = DirectDownloadRecoveryRestartError()
                        } catch {
                            responseError = error
                        }
                        state.resumeOffset = 0
                        state.bytesWritten = 0
                        context.mode = .ownedPartial(state)
                        return
                    }
                } else {
                    if statusCode == 206 {
                        guard contentRange?.start == 0 else {
                            throw URLError(.badServerResponse)
                        }
                    }
                    state.fileHandle = try recoveryStore.openFreshFile(id: context.downloadID)
                }

                let responseExpectedBytes = try expectedByteCount(for: httpResponse)
                state.declaredExpectedBytes = responseExpectedBytes
                if let responseExpectedBytes {
                    state.expectedBytes = responseExpectedBytes
                } else if resetReason != nil {
                    state.expectedBytes = 0
                }
                state.suggestedFilename = httpResponse.suggestedFilename ?? state.suggestedFilename
                state.responseMimeType = httpResponse.mimeType ?? state.responseMimeType
                state.statusCode = statusCode
                state.responseRangeEnd = statusCode == 206 ? contentRange?.end : nil
                state.entityTag = httpResponse.value(forHTTPHeaderField: "ETag") ?? state.entityTag
                state.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? state.lastModified
                context.mode = .ownedPartial(state)

                try recoveryStore.saveMetadata(
                    recoveryMetadata(for: httpResponse, state: state),
                    id: context.downloadID
                )
            } catch {
                context.mode = .ownedPartial(state)
                if responseWasResuming,
                   Self.isInvalidResumeProtocolResponse(error) {
                    responseRequiresFreshStart = true
                    do {
                        try recoveryStore.discardThrowing(id: context.downloadID)
                        responseError = DirectDownloadRecoveryRestartError()
                    } catch {
                        responseError = error
                    }
                } else {
                    responseError = error
                }
            }
        }) else {
            completionHandler(.cancel)
            return
        }

        if shouldFinishExistingPartial {
            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            completionHandler(.cancel)

            do {
                try sealOwnedFile(in: context)
                guard case let .ownedPartial(state) = context.mode else {
                    throw URLError(.badServerResponse)
                }
                let claim = try claimOwnedPartial(context: context, state: state)
                finalizeCompletionClaim(
                    claim,
                    context: context,
                    wasResuming: true,
                    httpStatusCode: state.statusCode
                )
                return
            } catch {
                var publicationFailureMessage: String?
                if completedHandoffStore.ownsAttempt(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                ) {
                    publicationFailureMessage = error.localizedDescription
                }
                eventHandler(
                    .failed(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: true,
                            recoverableBytes: recoverableOwnedByteCount(in: context)
                        )
                    )
                )
                finishCompletionPublication(
                    context: context,
                    recoveryUnavailableMessage: publicationFailureMessage
                )
                context.session.finishTasksAndInvalidate()
            }
            return
        }

        if let responseError {
            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            let didPreserveRecovery = closeOwnedFile(
                in: context,
                preservingRecovery: true
            )
            let pauseResult = ownedPauseResult(
                for: context,
                didPreserveRecovery: didPreserveRecovery
            )
            completionHandler(.cancel)
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: responseError,
                        resumeData: nil,
                        wasResuming: responseWasResuming,
                        recoverableBytes: didPreserveRecovery
                            ? recoverableOwnedByteCount(in: context)
                            : 0,
                        httpStatusCode: responseStatusCode,
                        forcesFreshStart: responseRequiresFreshStart
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        if let resetReason {
            eventHandler(
                .recoveryReset(
                    id: updatedContext.downloadID,
                    attemptIdentifier: updatedContext.attemptIdentifier,
                    reason: resetReason
                )
            )
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
        var progress: (
            id: UUID,
            attemptIdentifier: UUID,
            bytesWritten: Int64,
            expectedBytes: Int64,
            speed: Double
        )?

        guard let context = updateContext(for: taskKey, { context in
            guard case var .ownedPartial(state) = context.mode,
                  let fileHandle = state.fileHandle else {
                writeError = CocoaError(.fileWriteUnknown)
                return
            }

            do {
                let receivedByteCount = Int64(data.count)
                if receivedByteCount > 0 {
                    let rangeLimit = state.responseRangeEnd.flatMap { end in
                        end == Int64.max ? nil : end + 1
                    }
                    let absoluteByteLimit: Int64?
                    switch (rangeLimit, state.declaredExpectedBytes) {
                    case let (range?, declared?):
                        absoluteByteLimit = min(range, declared)
                    case let (range?, nil):
                        absoluteByteLimit = range
                    case let (nil, declared?):
                        absoluteByteLimit = declared
                    case (nil, nil):
                        absoluteByteLimit = nil
                    }
                    if let absoluteByteLimit {
                        let permittedByteCount = max(absoluteByteLimit - state.bytesWritten, 0)
                        let exceedsDeclaredBody = state.bytesWritten > absoluteByteLimit
                            || receivedByteCount > permittedByteCount
                        if exceedsDeclaredBody {
                            if permittedByteCount > 0 {
                                try fileHandle.write(
                                    contentsOf: Data(data.prefix(Int(permittedByteCount)))
                                )
                                state.bytesWritten += permittedByteCount
                            }
                            if let responseRangeEnd = state.responseRangeEnd,
                               absoluteByteLimit == rangeLimit {
                                writeError = DirectDownloadRangeOverflowError(
                                    declaredEnd: responseRangeEnd
                                )
                            } else {
                                writeError = DirectDownloadBodyOverflowError(
                                    expectedBytes: absoluteByteLimit
                                )
                            }
                            context.mode = .ownedPartial(state)
                            return
                        }
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
                    attemptIdentifier: context.attemptIdentifier,
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
            guard let failedContext = beginCompletionPublication(forTaskKey: taskKey) else {
                return
            }
            _ = withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            let didPreserveRecovery = closeOwnedFile(
                in: failedContext,
                preservingRecovery: true
            )
            let pauseResult = ownedPauseResult(
                for: failedContext,
                didPreserveRecovery: didPreserveRecovery
            )
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
                    attemptIdentifier: failedContext.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: writeError,
                        resumeData: nil,
                        wasResuming: wasResuming,
                        recoverableBytes: didPreserveRecovery
                            ? recoverableOwnedByteCount(in: failedContext)
                            : 0
                    )
                )
            )
            finishCompletionPublication(
                context: failedContext,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            return
        }

        if let progress {
            eventHandler(
                .progress(
                    id: progress.id,
                    attemptIdentifier: progress.attemptIdentifier,
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
        guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
            return
        }

        let startedFromResumeData: Bool
        let resumeOffset: Int64?
        let resumeValidator: String?
        if case let .legacyDownload(started, savedOffset, savedValidator) = context.mode {
            startedFromResumeData = started
            resumeOffset = savedOffset
            resumeValidator = savedValidator
        } else {
            startedFromResumeData = false
            resumeOffset = nil
            resumeValidator = nil
        }
        let responseStatusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let claim = try claimLegacyDownload(
                at: location,
                context: context,
                response: response,
                startedFromResumeData: startedFromResumeData,
                resumeOffset: resumeOffset,
                resumeValidator: resumeValidator
            )

            finalizeCompletionClaim(
                claim,
                context: context,
                wasResuming: startedFromResumeData,
                httpStatusCode: responseStatusCode
            )
            return
        } catch {
            var publicationFailureMessage: String?
            if completedHandoffStore.ownsAttempt(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier
            ) {
                publicationFailureMessage = error.localizedDescription
            }
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: startedFromResumeData,
                        httpStatusCode: responseStatusCode
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: publicationFailureMessage
            )
            context.session.finishTasksAndInvalidate()
        }
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

            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                return
            }

            let didPreserveRecovery = closeOwnedFile(
                in: context,
                preservingRecovery: true
            )
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let wasResuming: Bool
            let recoverableBytes: Int64?
            let pauseResult: DirectDownloadPauseResult
            switch context.mode {
            case let .legacyDownload(startedFromResumeData, _, _):
                wasResuming = startedFromResumeData
                recoverableBytes = nil
                pauseResult = DirectDownloadPauseResult(
                    attemptIdentifier: context.attemptIdentifier,
                    resumeData: resumeData,
                    ownedRecovery: nil
                )
            case let .ownedPartial(state):
                wasResuming = state.resumeOffset > 0
                recoverableBytes = didPreserveRecovery
                    ? recoverableOwnedByteCount(in: context)
                    : 0
                pauseResult = ownedPauseResult(
                    for: context,
                    didPreserveRecovery: didPreserveRecovery
                )
            }

            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: nsError,
                        resumeData: resumeData,
                        wasResuming: wasResuming,
                        recoverableBytes: recoverableBytes
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                resumeData: pauseResult.resumeData,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        guard let context = beginCompletionPublication(forTaskKey: taskKey),
              case let .ownedPartial(state) = context.mode else {
            return
        }

        do {
            try sealOwnedFile(in: context)
        } catch {
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: nil
            )
            context.session.finishTasksAndInvalidate()
            return
        }
        let actualBytes = recoveryStore.recoveredByteCount(id: context.downloadID)
            ?? state.bytesWritten
        let matchesDeclaredRange = state.responseRangeEnd.map {
            actualBytes > 0 && actualBytes - 1 == $0
        } ?? true
        let matchesDeclaredTotal = state.declaredExpectedBytes.map {
            actualBytes == $0
        } ?? true
        let hasVerifiableCompleteLength = state.statusCode != 206
            || state.declaredExpectedBytes != nil

        guard matchesDeclaredRange,
              matchesDeclaredTotal,
              hasVerifiableCompleteLength else {
            let expectedBytes = state.declaredExpectedBytes
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
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
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: nil
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        do {
            let claim = try claimOwnedPartial(context: context, state: state)
            finalizeCompletionClaim(
                claim,
                context: context,
                wasResuming: state.resumeOffset > 0,
                httpStatusCode: state.statusCode
            )
            return
        } catch {
            var publicationFailureMessage: String?
            if completedHandoffStore.ownsAttempt(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier
            ) {
                publicationFailureMessage = error.localizedDescription
            }
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: publicationFailureMessage
            )
            context.session.finishTasksAndInvalidate()
        }
    }
}
