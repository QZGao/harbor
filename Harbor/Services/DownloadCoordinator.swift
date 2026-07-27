import Foundation

enum DownloadEvent: Sendable {
    case started(id: UUID, taskIdentifier: Int)
    case progress(id: UUID, bytesWritten: Int64, expectedBytes: Int64, speedBytesPerSecond: Double)
    case paused(id: UUID, resumeData: Data?)
    case cancelled(id: UUID)
    case finished(
        id: UUID,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?
    )
    case failed(id: UUID, message: String, resumeData: Data?)
}

final class DownloadCoordinator: NSObject, @unchecked Sendable {
    typealias EventHandler = @Sendable (DownloadEvent) -> Void

    private struct TransferSample {
        var lastTotalBytesWritten: Int64
        var sampleDate: Date
        var speedBytesPerSecond: Double
    }

    private typealias TaskKey = String

    private struct TaskContext {
        let downloadID: UUID
        let sourceURL: URL
        let requestHeaders: [RequestHeader]
        let session: URLSession
        let task: URLSessionDownloadTask
        var speedLimitOverride: TransferLimitOverride
        var transferSample: TransferSample
        var isThrottled = false
        var throttleGeneration: UInt64 = 0
    }

    private let eventHandler: EventHandler
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private let ownedTemporaryDirectory: URL
    private let delegateQueue: OperationQueue

    private var contexts: [TaskKey: TaskContext] = [:]
    private var taskKeysByDownloadID: [UUID: TaskKey] = [:]
    private var suppressedCompletionTaskKeys: Set<TaskKey> = []
    private var transferSettings: DownloadTransferSettings

    init(
        transferSettings: DownloadTransferSettings = .default,
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.transferSettings = transferSettings
        self.ownedTemporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDownloads", isDirectory: true)
        self.delegateQueue = OperationQueue()
        self.delegateQueue.name = "DownloadCoordinatorDelegateQueue"
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    deinit {
        withLock {
            Array(contexts.values)
        }
        .forEach { $0.session.invalidateAndCancel() }
    }

    func updateTransferSettings(_ transferSettings: DownloadTransferSettings) {
        let tasksToResume = withLock { () -> [URLSessionDownloadTask] in
            self.transferSettings = transferSettings
            return releaseThrottledTasksLocked()
        }
        tasksToResume.forEach { $0.resume() }
    }

    func updateSpeedLimitOverride(
        _ speedLimitOverride: TransferLimitOverride,
        for id: UUID
    ) {
        let tasksToResume = withLock { () -> [URLSessionDownloadTask] in
            guard let taskKey = taskKeysByDownloadID[id],
                  var context = contexts[taskKey] else {
                return []
            }

            context.speedLimitOverride = speedLimitOverride
            var tasks: [URLSessionDownloadTask] = []
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
        requestHeaders: [RequestHeader],
        resumeData: Data?,
        speedLimitOverride: TransferLimitOverride = .inherit
    ) -> Int {
        let session = makeSession()
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: sourceURL)
            requestHeaders.apply(to: &request)
            task = session.downloadTask(with: request)
        }

        let key = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        let context = TaskContext(
            downloadID: id,
            sourceURL: sourceURL,
            requestHeaders: requestHeaders,
            session: session,
            task: task,
            speedLimitOverride: speedLimitOverride,
            transferSample: TransferSample(
                lastTotalBytesWritten: 0,
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
        eventHandler(.started(id: id, taskIdentifier: task.taskIdentifier))
        return task.taskIdentifier
    }

    func pauseDownload(id: UUID) {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            return
        }

        context.task.cancel(byProducingResumeData: { [eventHandler, session = context.session] resumeData in
            session.finishTasksAndInvalidate()
            eventHandler(.paused(id: id, resumeData: resumeData))
        })
    }

    func cancelDownload(id: UUID) {
        guard let context = takeContext(forDownloadID: id, suppressCompletion: true) else {
            return
        }

        context.task.cancel()
        context.session.invalidateAndCancel()
        eventHandler(.cancelled(id: id))
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
            let suppressed = suppressedCompletionTaskKeys.remove(taskKey) != nil
            return suppressed && error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        }
    }

    private func redirectContext(
        for taskKey: TaskKey
    ) -> (sourceURL: URL, requestHeaders: [RequestHeader])? {
        withLock {
            contexts[taskKey].map { context in
                (context.sourceURL, context.requestHeaders)
            }
        }
    }

    private func makeSession() -> URLSession {
        let perDownloadConnectionCount = withLock {
            transferSettings.perDownloadConnectionCount
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
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

    private func releaseThrottledTasksLocked() -> [URLSessionDownloadTask] {
        var tasks: [URLSessionDownloadTask] = []

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

extension DownloadCoordinator: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    /// Preserves this download's request headers when URLSession follows a same-origin redirect.
    ///
    /// URLSession creates the proposed redirect request and may omit headers such as `Authorization`.
    /// Looking up the task context keeps the headers scoped to their originating download, while
    /// `apply(toSameOriginRedirect:originatingAt:)` prevents us from deliberately reapplying them
    /// after the redirect crosses an HTTP origin boundary. The completion handler must always be
    /// called; passing the resulting request allows URLSession to continue following the redirect.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        guard let context = redirectContext(for: taskKey) else {
            completionHandler(request)
            return
        }

        var redirectedRequest = request
        context.requestHeaders.apply(
            toSameOriginRedirect: &redirectedRequest,
            originatingAt: context.sourceURL
        )
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
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
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: downloadTask.taskIdentifier)
        guard let context = takeContext(forTaskKey: taskKey) else {
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
                    message: error.localizedDescription,
                    resumeData: nil
                )
            )
        }

        context.session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }

        let nsError = error as NSError
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        if shouldIgnoreCompletion(taskKey: taskKey, error: nsError) {
            return
        }

        guard let context = takeContext(forTaskKey: taskKey) else {
            return
        }

        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        eventHandler(
            .failed(
                id: context.downloadID,
                message: nsError.localizedDescription,
                resumeData: resumeData
            )
        )
        context.session.finishTasksAndInvalidate()
    }
}
