import CryptoKit
import Foundation
import Observation
import WebKit

enum BrowserDownloadEvent: Sendable {
    case started(
        id: UUID,
        attemptIdentifier: UUID,
        suggestedFilename: String?,
        expectedBytes: Int64,
        responseMimeType: String?,
        statusCode: Int?,
        isResumed: Bool
    )
    case finished(
        id: UUID,
        attemptIdentifier: UUID,
        handoff: CompletedDownloadHandoff
    )
    case failed(id: UUID, attemptIdentifier: UUID, failure: DirectDownloadFailure)
    case dismissed(id: UUID, attemptIdentifier: UUID, resumeData: Data?)
    case completionUnavailable(id: UUID, attemptIdentifier: UUID, message: String)
    case quiescenceFailed(id: UUID, attemptIdentifier: UUID, message: String)
    case quiescedAfterTimeout(
        id: UUID,
        attemptIdentifier: UUID,
        resumeData: Data?,
        wasCancelling: Bool
    )
}

struct BrowserDownloadQuiescence: Sendable {
    let attemptIdentifier: UUID
    let resumeData: Data?
    let completionUnavailableMessage: String?
    let writerQuiescenceUnavailableMessage: String?

    init(
        attemptIdentifier: UUID,
        resumeData: Data?,
        completionUnavailableMessage: String? = nil,
        writerQuiescenceUnavailableMessage: String? = nil
    ) {
        self.attemptIdentifier = attemptIdentifier
        self.resumeData = resumeData
        self.completionUnavailableMessage = completionUnavailableMessage
        self.writerQuiescenceUnavailableMessage = writerQuiescenceUnavailableMessage
    }
}

nonisolated struct BrowserCompletedTemporaryManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let handoff: CompletedDownloadHandoffManifest

    init(handoff: CompletedDownloadHandoffManifest) {
        self.version = Self.currentVersion
        self.handoff = handoff
    }
}

@MainActor
@Observable
final class BrowserDownloadSession: Identifiable {
    let id = UUID()
    let downloadID: UUID
    let attemptIdentifier: UUID
    let sourceURL: URL
    let displayName: String

    @ObservationIgnored let webView: WKWebView

    var currentURL: URL?
    var pageTitle: String?
    var statusMessage = "Complete any required sign-in or verification. Harbor will capture the file automatically."
    var isLoading = true

    fileprivate var hasStartedDownload = false

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        displayName: String,
        webView: WKWebView
    ) {
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.webView = webView
        self.currentURL = sourceURL
    }
}

@MainActor
final class BrowserDownloadCoordinator: NSObject {
    typealias ResumeCompletion = @MainActor @Sendable (WKDownload) -> Void
    typealias ResumeDownload = @MainActor (
        WKWebView,
        Data,
        @escaping ResumeCompletion
    ) -> Void
    typealias CancelUnownedDownload = @MainActor (WKDownload) -> Void

    private enum TerminationReason {
        case pause
        case cancel
    }

    private struct DownloadContext {
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let webView: WKWebView
        let isResumeAttempt: Bool
        let originalResumeData: Data?
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var httpResponse: HTTPURLResponse?
        var expectedBytes: Int64
        var temporaryURL: URL?
        var terminationReason: TerminationReason?
        var rejectionError: Error?
    }

    private struct PendingResume {
        let session: BrowserDownloadSession
        let resumeData: Data
    }

    private struct CompletionPublication {
        let attemptIdentifier: UUID
        let task: Task<BrowserDownloadEvent, Never>
    }

    private struct PendingNavigationStop {
        let session: BrowserDownloadSession
        let reason: TerminationReason
        var waiters: [(Data?) -> Void]
    }

    private struct ActiveDownloadStopResult {
        let resumeData: Data?
        let writerQuiescenceUnavailableMessage: String?
    }

    private struct ActiveDownloadStopFailure {
        let attemptIdentifier: UUID
        let message: String
    }

    private struct ActiveDownloadHandle {
        let owner: AnyObject
        let identity: ObjectIdentifier
        let cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    }

    nonisolated private static let completedTemporaryManifestExtension = "completion"

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let completedHandoffStore: CompletedDownloadHandoffStore
    private let onEvent: @MainActor (BrowserDownloadEvent) -> Void
    private let resumeDownload: ResumeDownload
    private let cancelUnownedDownload: CancelUnownedDownload

    private var activeSession: BrowserDownloadSession?
    private var pendingResumes: [UUID: PendingResume] = [:]
    private var pendingResumeTerminationReasons: [UUID: TerminationReason] = [:]
    private var pendingResumeStopWaiters: [UUID: [(Data?) -> Void]] = [:]
    private var pendingNavigationConversions: [UUID: BrowserDownloadSession] = [:]
    private var pendingNavigationStops: [UUID: PendingNavigationStop] = [:]
    private var downloadContexts: [ObjectIdentifier: DownloadContext] = [:]
    private var activeDownloadsByID: [UUID: ActiveDownloadHandle] = [:]
    private var resumableWebViews: [UUID: WKWebView] = [:]
    private var stopWaiters: [UUID: [(ActiveDownloadStopResult) -> Void]] = [:]
    private var activeDownloadStopFailures: [UUID: ActiveDownloadStopFailure] = [:]
    private var completedActiveStopResults: [UUID: (UUID, ActiveDownloadStopResult)] = [:]
    private var completionPublications: [UUID: CompletionPublication] = [:]
    private var completionPublicationFailures: [UUID: (UUID, String)] = [:]
    private var acceptsResumeCallbacks = true
    private var isQuiescingForShutdown = false

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        completedHandoffStore: CompletedDownloadHandoffStore? = nil,
        resumeDownload: @escaping ResumeDownload = { webView, resumeData, completion in
            webView.resumeDownload(fromResumeData: resumeData, completionHandler: completion)
        },
        cancelUnownedDownload: @escaping CancelUnownedDownload = { download in
            download.cancel { _ in }
        },
        onEvent: @escaping @MainActor (BrowserDownloadEvent) -> Void
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("BrowserDownloadRecovery", isDirectory: true)
        self.resumeDownload = resumeDownload
        self.cancelUnownedDownload = cancelUnownedDownload
        self.onEvent = onEvent
        self.completedHandoffStore = completedHandoffStore
            ?? CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: temporaryDirectory
            )

        super.init()

        try? fileManager.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    func startSession(
        downloadID: UUID,
        attemptIdentifier: UUID = UUID(),
        sourceURL: URL,
        displayName: String,
        resumeData: Data? = nil
    ) -> BrowserDownloadSession {
        acceptsResumeCallbacks = true

        if completedActiveStopResults[downloadID]?.0 != attemptIdentifier {
            completedActiveStopResults.removeValue(forKey: downloadID)
        }

        if let activeSession,
           activeSession.downloadID == downloadID,
           activeSession.attemptIdentifier == attemptIdentifier {
            return activeSession
        }

        if let pending = pendingResumes[downloadID] {
            if pending.session.attemptIdentifier == attemptIdentifier {
                cancelSession()
                activeSession = pending.session
                return pending.session
            }

            // A new DownloadCenter attempt must never inherit a WebKit
            // callback that was registered for a retired token. Detach the
            // old callback now; if WebKit invokes it later, ownership checks
            // cancel the resulting WKDownload as unowned.
            abandonPendingResume(downloadID: downloadID, pending: pending)
        }

        cancelSession()

        let webView: WKWebView
        if resumeData != nil, let resumableWebView = resumableWebViews[downloadID] {
            webView = resumableWebView
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: configuration)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let session = BrowserDownloadSession(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: displayName,
            webView: webView
        )

        activeSession = session

        if let resumeData {
            resumableWebViews[downloadID] = webView
            session.statusMessage = "Resuming secure browser-backed download…"
            session.isLoading = false
            pendingResumes[downloadID] = PendingResume(
                session: session,
                resumeData: resumeData
            )
            resumeDownload(webView, resumeData) { [weak self, weak session, weak webView] download in
                guard let self, let session, let webView else {
                    download.cancel { _ in }
                    return
                }

                if self.cancelPendingResumeDownloadIfNeeded(
                    download,
                    downloadID: downloadID,
                    attemptIdentifier: attemptIdentifier,
                    session: session,
                    webView: webView
                ) {
                    return
                }

                guard self.acceptsResumeCallbacks,
                      self.claimPendingResume(
                        downloadID: downloadID,
                        attemptIdentifier: attemptIdentifier,
                        session: session,
                        webView: webView
                      ) else {
                    self.cancelUnownedDownload(download)
                    return
                }

                self.track(
                    download: download,
                    for: session,
                    isResumeAttempt: true,
                    originalResumeData: resumeData
                )
            }
        } else {
            webView.load(URLRequest(url: sourceURL))
        }
        return session
    }

    func claimPendingResume(
        downloadID: UUID,
        attemptIdentifier: UUID? = nil,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        guard let pending = pendingResumes[downloadID],
              pending.session.id == session.id,
              pendingResumeTerminationReasons[downloadID] == nil,
              attemptIdentifier == nil
                || pending.session.attemptIdentifier == attemptIdentifier else {
            return false
        }

        pendingResumes.removeValue(forKey: downloadID)
        return activeSession?.id == session.id
            && activeSession?.webView === webView
            && session.webView === webView
    }

    func cancelSession() {
        if let session = activeSession {
            pendingNavigationConversions.removeValue(forKey: session.downloadID)
            pendingNavigationStops.removeValue(forKey: session.downloadID)
        }
        activeSession?.webView.stopLoading()
        activeSession = nil
    }

    func hasActiveDownload(id: UUID) -> Bool {
        activeDownloadsByID[id] != nil
    }

    func hasPendingOrActiveAttempt(id: UUID) -> Bool {
        pendingResumes[id] != nil
            || activeDownloadsByID[id] != nil
            || completionPublications[id] != nil
            || activeSession?.downloadID == id
    }

    func hasResumableWebView(id: UUID) -> Bool {
        resumableWebViews[id] != nil
    }

#if DEBUG
    var isQuiescingForShutdownForTesting: Bool {
        isQuiescingForShutdown
    }

    func installPendingNavigationConversionForTesting(
        session: BrowserDownloadSession
    ) {
        guard activeSession?.id == session.id else {
            return
        }
        pendingNavigationConversions[session.downloadID] = session
    }

    func installCompletionPublicationFailureForTesting(
        downloadID: UUID,
        attemptIdentifier: UUID,
        message: String
    ) {
        completionPublicationFailures[downloadID] = (attemptIdentifier, message)
    }

    func installCompletionPublicationForTesting(
        downloadID: UUID,
        attemptIdentifier: UUID,
        operation: @escaping @MainActor @Sendable () async -> BrowserDownloadEvent
    ) {
        completionPublications[downloadID] = CompletionPublication(
            attemptIdentifier: attemptIdentifier,
            task: Task { @MainActor in
                await operation()
            }
        )
    }

    func simulatePendingResumeCallbackWithStalledCancellationForTesting(
        downloadID: UUID
    ) -> Bool {
        simulatePendingResumeCallbackForTesting(
            downloadID: downloadID,
            cancel: { _ in }
        )
    }

    func simulatePendingResumeCallbackForTesting(
        downloadID: UUID,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let pending = pendingResumes[downloadID] else {
            return false
        }
        return beginCancellingPendingResume(
            downloadID: downloadID,
            attemptIdentifier: pending.session.attemptIdentifier,
            session: pending.session,
            webView: pending.session.webView,
            cancel: cancel
        )
    }

    func installActiveDownloadForTesting(
        session: BrowserDownloadSession,
        cancel: @escaping (@escaping @Sendable (Data?) -> Void) -> Void
    ) {
        guard activeSession?.id == session.id else {
            return
        }
        let owner = NSObject()
        let key = ObjectIdentifier(owner)
        session.hasStartedDownload = true
        downloadContexts[key] = DownloadContext(
            downloadID: session.downloadID,
            attemptIdentifier: session.attemptIdentifier,
            sourceURL: session.sourceURL,
            webView: session.webView,
            isResumeAttempt: false,
            originalResumeData: nil,
            suggestedFilename: nil,
            responseMimeType: nil,
            statusCode: nil,
            httpResponse: nil,
            expectedBytes: 0,
            temporaryURL: nil,
            terminationReason: nil,
            rejectionError: nil
        )
        activeDownloadsByID[session.downloadID] = ActiveDownloadHandle(
            owner: owner,
            identity: key,
            cancel: cancel
        )
    }

    func simulatePendingNavigationCallbackForTesting(
        downloadID: UUID,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let stop = pendingNavigationStops[downloadID] else {
            return false
        }
        return beginCancellingPendingNavigation(
            downloadID: downloadID,
            session: stop.session,
            webView: stop.session.webView,
            cancel: cancel
        )
    }
#endif

    func quiesceDownload(id: UUID, cancelling: Bool = false) async -> BrowserDownloadQuiescence? {
        if let completed = completedActiveStopResults[id] {
            if let currentAttemptIdentifier = currentAttemptIdentifier(for: id),
               currentAttemptIdentifier != completed.0 {
                completedActiveStopResults.removeValue(forKey: id)
            } else {
                completedActiveStopResults.removeValue(forKey: id)
                return BrowserDownloadQuiescence(
                    attemptIdentifier: completed.0,
                    resumeData: completed.1.resumeData,
                    writerQuiescenceUnavailableMessage: completed.1.writerQuiescenceUnavailableMessage
                )
            }
        }
        if let failure = completionPublicationFailures[id] {
            return BrowserDownloadQuiescence(
                attemptIdentifier: failure.0,
                resumeData: nil,
                completionUnavailableMessage: takeCompletionPublicationFailure(
                    id: id,
                    attemptIdentifier: failure.0
                )
            )
        }

        if let publication = completionPublications[id] {
            _ = await deliverCompletionPublication(
                id: id,
                attemptIdentifier: publication.attemptIdentifier
            )
            return BrowserDownloadQuiescence(
                attemptIdentifier: publication.attemptIdentifier,
                resumeData: nil,
                completionUnavailableMessage: takeCompletionPublicationFailure(
                    id: id,
                    attemptIdentifier: publication.attemptIdentifier
                )
            )
        }

        if let pending = pendingResumes[id] {
            let resumeData: Data? = await withCheckedContinuation { continuation in
                _ = requestPendingResumeStop(
                    id: id,
                    reason: cancelling ? .cancel : .pause,
                    completion: { continuation.resume(returning: $0) }
                )
            }
            return BrowserDownloadQuiescence(
                attemptIdentifier: pending.session.attemptIdentifier,
                resumeData: resumeData
            )
        }


        if let pending = pendingNavigationConversions[id] {
            let resumeData: Data? = await withCheckedContinuation { continuation in
                _ = requestPendingNavigationStop(
                    id: id,
                    reason: cancelling ? .cancel : .pause,
                    completion: { continuation.resume(returning: $0) }
                )
            }
            return BrowserDownloadQuiescence(
                attemptIdentifier: pending.attemptIdentifier,
                resumeData: resumeData
            )
        }

        if let session = activeSession, session.downloadID == id,
           activeDownloadsByID[id] == nil {
            session.webView.stopLoading()
            activeSession = nil
            return BrowserDownloadQuiescence(
                attemptIdentifier: session.attemptIdentifier,
                resumeData: nil
            )
        }

        guard let download = activeDownloadsByID[id],
              let context = downloadContexts[download.identity] else {
            if let failure = completionPublicationFailures[id] {
                return BrowserDownloadQuiescence(
                    attemptIdentifier: failure.0,
                    resumeData: nil,
                    completionUnavailableMessage: takeCompletionPublicationFailure(
                        id: id,
                        attemptIdentifier: failure.0
                    )
                )
            }
            return nil
        }
        let stopResult: ActiveDownloadStopResult = await withCheckedContinuation { continuation in
            _ = requestStop(
                id: id,
                reason: cancelling ? .cancel : .pause,
                completion: { continuation.resume(returning: $0) }
            )
        }
        if let publication = completionPublications[id] {
            _ = await deliverCompletionPublication(
                id: id,
                attemptIdentifier: publication.attemptIdentifier
            )
        }
        return BrowserDownloadQuiescence(
            attemptIdentifier: context.attemptIdentifier,
            resumeData: stopResult.resumeData,
            completionUnavailableMessage: takeCompletionPublicationFailure(
                id: id,
                attemptIdentifier: context.attemptIdentifier
            ),
            writerQuiescenceUnavailableMessage: stopResult.writerQuiescenceUnavailableMessage
        )
    }

    func quiesceForShutdown() async -> [UUID: BrowserDownloadQuiescence] {
        acceptsResumeCallbacks = false
        isQuiescingForShutdown = true
        defer { isQuiescingForShutdown = false }
        var results: [UUID: BrowserDownloadQuiescence] = [:]
        var blockedWriterIDs: Set<UUID> = []
        while true {
            let resolvedWriterIDs = blockedWriterIDs.filter {
                activeDownloadsByID[$0] == nil
            }
            for id in resolvedWriterIDs {
                blockedWriterIDs.remove(id)
                results.removeValue(forKey: id)
            }
            var pendingIDs = Set(pendingResumes.keys)
            pendingIDs.formUnion(pendingNavigationConversions.keys)
            pendingIDs.formUnion(pendingNavigationStops.keys)
            pendingIDs.formUnion(activeDownloadsByID.keys)
            pendingIDs.formUnion(completionPublications.keys)
            pendingIDs.formUnion(completionPublicationFailures.keys)
            pendingIDs.formUnion(completedActiveStopResults.keys)
            if let activeSession {
                pendingIDs.insert(activeSession.downloadID)
            }
            pendingIDs.subtract(blockedWriterIDs)

            guard pendingIDs.isEmpty == false else {
                return results
            }

            for id in pendingIDs {
                if let result = await quiesceDownload(id: id) {
                    results[id] = result
                    if result.writerQuiescenceUnavailableMessage != nil {
                        blockedWriterIDs.insert(id)
                    }
                }
            }
        }
    }

    func resumeAfterFailedShutdown() {
        acceptsResumeCallbacks = true
    }

    func discardRecoveryData(id: UUID) {
        try? discardRecoveryDataOrThrow(id: id)
    }

    func discardRecoveryDataOrThrow(id: UUID) throws {
        pendingResumes.removeValue(forKey: id)
        pendingResumeTerminationReasons.removeValue(forKey: id)
        pendingResumeStopWaiters.removeValue(forKey: id)
        pendingNavigationConversions.removeValue(forKey: id)
        pendingNavigationStops.removeValue(forKey: id)
        resumableWebViews.removeValue(forKey: id)
        completedActiveStopResults.removeValue(forKey: id)
        completionPublicationFailures.removeValue(forKey: id)
        try discardPartialFilesThrowing(downloadID: id)
        try completedHandoffStore.discardThrowing(downloadID: id)
    }

    func recoverCompletedTemporaryFiles(
        downloadID: UUID? = nil
    ) async throws -> [UUID: String] {
        let fileManager = fileManager
        let temporaryDirectory = temporaryDirectory
        let completedHandoffStore = completedHandoffStore
        let failures = try await Task.detached(priority: .utility) {
            try Self.recoverCompletedTemporaryFilesOffMainActor(
                downloadID: downloadID,
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory,
                completedHandoffStore: completedHandoffStore
            )
        }.value
        if let downloadID {
            if failures[downloadID] == nil {
                completionPublicationFailures.removeValue(forKey: downloadID)
            }
        } else {
            for id in Array(completionPublicationFailures.keys)
            where failures[id] == nil {
                completionPublicationFailures.removeValue(forKey: id)
            }
        }
        return failures
    }

    func discardPartialRecoveryData(id: UUID) {
        pendingResumes.removeValue(forKey: id)
        pendingResumeTerminationReasons.removeValue(forKey: id)
        pendingResumeStopWaiters.removeValue(forKey: id)
        pendingNavigationConversions.removeValue(forKey: id)
        pendingNavigationStops.removeValue(forKey: id)
        resumableWebViews.removeValue(forKey: id)
        completedActiveStopResults.removeValue(forKey: id)
        discardPartialFiles(downloadID: id)
    }

    func discardOrphanedTemporaryFiles(retaining retainedIDs: Set<UUID>) {
        completedHandoffStore.discardLegacyUnvalidatedFiles(
            in: temporaryDirectory
        )
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.pathExtension == "part"
            || url.pathExtension == Self.completedTemporaryManifestExtension {
            guard let identifiers = Self.temporaryIdentifiers(from: url),
                  retainedIDs.contains(identifiers.downloadID) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            if url.pathExtension == "part" {
                let manifestURL = Self.completedTemporaryManifestURL(
                    temporaryDirectory: temporaryDirectory,
                    downloadID: identifiers.downloadID,
                    attemptIdentifier: identifiers.attemptIdentifier
                )
                let manifestExists: Bool
                do {
                    manifestExists = try Self.itemExists(at: manifestURL)
                } catch {
                    // An operational lookup failure is not proof that the
                    // completion marker is absent. Preserve the only payload
                    // until a later scan can make that distinction safely.
                    continue
                }
                if manifestExists == false {
                    // A WebKit destination without a completed marker is an
                    // interrupted transfer, not a publishable file.
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private func track(
        download: WKDownload,
        for session: BrowserDownloadSession,
        isResumeAttempt: Bool = false,
        originalResumeData: Data? = nil
    ) {
        guard activeSession?.id == session.id,
              activeDownloadsByID[session.downloadID] == nil
        else {
            cancelUnownedDownload(download)
            return
        }

        session.hasStartedDownload = true
        session.statusMessage = "Starting secure browser-backed download…"

        downloadContexts[ObjectIdentifier(download)] = DownloadContext(
            downloadID: session.downloadID,
            attemptIdentifier: session.attemptIdentifier,
            sourceURL: session.sourceURL,
            webView: session.webView,
            isResumeAttempt: isResumeAttempt,
            originalResumeData: originalResumeData,
            suggestedFilename: nil,
            responseMimeType: nil,
            statusCode: nil,
            httpResponse: nil,
            expectedBytes: 0,
            temporaryURL: nil,
            terminationReason: nil,
            rejectionError: nil
        )

        activeDownloadsByID[session.downloadID] = ActiveDownloadHandle(
            owner: download,
            identity: ObjectIdentifier(download),
            cancel: { completion in download.cancel(completion) }
        )
        download.delegate = self
    }

    private func requestPendingResumeStop(
        id: UUID,
        reason: TerminationReason,
        completion: @escaping (Data?) -> Void
    ) -> Bool {
        guard let pending = pendingResumes[id] else {
            return false
        }

        if reason == .cancel || pendingResumeTerminationReasons[id] == nil {
            pendingResumeTerminationReasons[id] = reason
        }
        pendingResumeStopWaiters[id, default: []].append(completion)
        if activeSession?.id == pending.session.id {
            pending.session.webView.stopLoading()
            activeSession = nil
        }
        // WebKit does not guarantee that resumeDownload's completion handler
        // fires after its hosting view is stopped or closed. Bound quiescence;
        // a late callback is rejected by the pending-token ownership check.
        let sessionIdentifier = pending.session.id
        let webViewIdentifier = ObjectIdentifier(pending.session.webView)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else {
                return
            }
            self.finishPendingResumeStop(
                id: id,
                sessionIdentifier: sessionIdentifier,
                webViewIdentifier: webViewIdentifier,
                cancellationWasConfirmed: false
            )
        }
        return true
    }

    private func finishPendingResumeStop(
        id: UUID,
        sessionIdentifier: UUID,
        webViewIdentifier: ObjectIdentifier,
        resumeData deliveredResumeData: Data? = nil,
        cancellationWasConfirmed: Bool
    ) {
        guard let pending = pendingResumes[id],
              pending.session.id == sessionIdentifier,
              ObjectIdentifier(pending.session.webView) == webViewIdentifier,
              let reason = pendingResumeTerminationReasons[id] else {
            return
        }
        pendingResumes.removeValue(forKey: id)
        pendingResumeTerminationReasons.removeValue(forKey: id)
        if activeSession?.id == sessionIdentifier {
            activeSession = nil
        }
        let resumeData = reason == .pause
            ? (deliveredResumeData ?? pending.resumeData)
            : nil
        if resumeData != nil, cancellationWasConfirmed {
            resumableWebViews[id] = pending.session.webView
        } else {
            // A timeout proves only that Harbor stopped waiting; it does not
            // prove that WebKit released this view's old resume operation.
            // Quarantine it so a retry cannot attach a second WKDownload to
            // the same view while the retained callback is still pending.
            resumableWebViews.removeValue(forKey: id)
        }
        let waiters = pendingResumeStopWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0(resumeData) }
    }

    private func abandonPendingResume(
        downloadID: UUID,
        pending: PendingResume
    ) {
        pendingResumes.removeValue(forKey: downloadID)
        let reason = pendingResumeTerminationReasons.removeValue(forKey: downloadID)
        let resumeData = reason == .pause ? pending.resumeData : nil
        let waiters = pendingResumeStopWaiters.removeValue(forKey: downloadID) ?? []
        waiters.forEach { $0(resumeData) }
        if activeSession?.id == pending.session.id {
            pending.session.webView.stopLoading()
            activeSession = nil
        }
        resumableWebViews.removeValue(forKey: downloadID)
    }

    private func requestPendingNavigationStop(
        id: UUID,
        reason: TerminationReason,
        completion: @escaping (Data?) -> Void
    ) -> Bool {
        guard let session = pendingNavigationConversions[id] else {
            return false
        }
        if var stop = pendingNavigationStops[id] {
            stop.waiters.append(completion)
            pendingNavigationStops[id] = stop
        } else {
            pendingNavigationStops[id] = PendingNavigationStop(
                session: session,
                reason: reason,
                waiters: [completion]
            )
        }
        session.webView.stopLoading()
        if activeSession?.id == session.id {
            activeSession = nil
        }
        // WebKit normally follows a policy conversion with didBecome, but a
        // stopped navigation is allowed to end before producing a WKDownload.
        // At that point there is no destination and therefore no writer to
        // quiesce. Bound the wait and reject any late download callback as
        // unowned instead of hanging Pause, Cancel, or app termination.
        let sessionIdentifier = session.id
        let webViewIdentifier = ObjectIdentifier(session.webView)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else {
                return
            }
            self.finishPendingNavigationStop(
                id: id,
                sessionIdentifier: sessionIdentifier,
                webViewIdentifier: webViewIdentifier,
                resumeData: nil
            )
        }
        return true
    }

    private func finishPendingNavigationStop(
        id: UUID,
        sessionIdentifier: UUID,
        webViewIdentifier: ObjectIdentifier,
        resumeData: Data?
    ) {
        guard let stop = pendingNavigationStops[id],
              stop.session.id == sessionIdentifier,
              ObjectIdentifier(stop.session.webView) == webViewIdentifier else {
            return
        }
        pendingNavigationConversions.removeValue(forKey: id)
        pendingNavigationStops.removeValue(forKey: id)
        if activeSession?.id == sessionIdentifier {
            activeSession = nil
        }
        if stop.reason == .pause, resumeData != nil {
            resumableWebViews[id] = stop.session.webView
        } else {
            resumableWebViews.removeValue(forKey: id)
        }
        stop.waiters.forEach { $0(resumeData) }
    }

    private func cancelPendingNavigationDownloadIfNeeded(
        _ download: WKDownload,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        beginCancellingPendingNavigation(
            downloadID: session.downloadID,
            session: session,
            webView: webView,
            cancel: { completion in download.cancel(completion) }
        )
    }

    private func beginCancellingPendingNavigation(
        downloadID: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let stop = pendingNavigationStops[downloadID],
              stop.session.id == session.id,
              stop.session.webView === webView else {
            return false
        }
        let sessionIdentifier = stop.session.id
        let webViewIdentifier = ObjectIdentifier(webView)
        cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finishPendingNavigationStop(
                    id: downloadID,
                    sessionIdentifier: sessionIdentifier,
                    webViewIdentifier: webViewIdentifier,
                    resumeData: resumeData
                )
            }
        }
        return true
    }

    private func cancelPendingResumeDownloadIfNeeded(
        _ download: WKDownload,
        downloadID: UUID,
        attemptIdentifier: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        beginCancellingPendingResume(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            session: session,
            webView: webView,
            cancel: { completion in download.cancel(completion) }
        )
    }

    private func beginCancellingPendingResume(
        downloadID: UUID,
        attemptIdentifier: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let pending = pendingResumes[downloadID],
              pending.session.id == session.id,
              pending.session.attemptIdentifier == attemptIdentifier,
              pending.session.webView === webView,
              pendingResumeTerminationReasons[downloadID] != nil else {
            return false
        }

        let sessionIdentifier = session.id
        let webViewIdentifier = ObjectIdentifier(webView)
        cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finishPendingResumeStop(
                    id: downloadID,
                    sessionIdentifier: sessionIdentifier,
                    webViewIdentifier: webViewIdentifier,
                    resumeData: resumeData,
                    cancellationWasConfirmed: true
                )
            }
        }
        return true
    }

    private func clearActiveSession(matching context: DownloadContext) {
        guard activeSession?.downloadID == context.downloadID,
              activeSession?.attemptIdentifier == context.attemptIdentifier,
              activeSession?.webView === context.webView else {
            return
        }

        activeSession = nil
    }

    private func deliverCompletionPublication(
        id: UUID,
        attemptIdentifier: UUID
    ) async -> BrowserDownloadEvent? {
        guard let publication = completionPublications[id],
              publication.attemptIdentifier == attemptIdentifier else {
            return nil
        }
        let event = await publication.task.value
        guard completionPublications[id]?.attemptIdentifier == attemptIdentifier else {
            return nil
        }
        completionPublications.removeValue(forKey: id)
        if case let .failed(_, _, failure) = event {
            completionPublicationFailures[id] = (
                attemptIdentifier,
                failure.message
            )
        }
        onEvent(event)
        return event
    }

    private func takeCompletionPublicationFailure(
        id: UUID,
        attemptIdentifier: UUID
    ) -> String? {
        guard let failure = completionPublicationFailures[id],
              failure.0 == attemptIdentifier else {
            return nil
        }
        completionPublicationFailures.removeValue(forKey: id)
        return failure.1
    }

    @discardableResult
    private func requestStop(
        id: UUID,
        reason: TerminationReason,
        completion: @escaping (ActiveDownloadStopResult) -> Void
    ) -> Bool {
        guard let download = activeDownloadsByID[id] else {
            return false
        }

        let key = download.identity
        guard var context = downloadContexts[key] else {
            return false
        }

        if context.terminationReason != nil {
            if case .cancel = reason {
                context.terminationReason = .cancel
                downloadContexts[key] = context
            }
            if let failure = activeDownloadStopFailures[id],
               failure.attemptIdentifier == context.attemptIdentifier {
                completion(
                    ActiveDownloadStopResult(
                        resumeData: nil,
                        writerQuiescenceUnavailableMessage: failure.message
                    )
                )
                return true
            }
            stopWaiters[id, default: []].append(completion)
            return true
        }

        context.terminationReason = reason
        downloadContexts[key] = context
        stopWaiters[id, default: []].append(completion)
        let attemptIdentifier = context.attemptIdentifier
        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finishActiveDownloadStop(
                    id: id,
                    key: key,
                    resumeData: resumeData
                )
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.failActiveDownloadStopIfStillPending(
                id: id,
                key: key,
                attemptIdentifier: attemptIdentifier
            )
        }
        return true
    }

    private func failActiveDownloadStopIfStillPending(
        id: UUID,
        key: ObjectIdentifier,
        attemptIdentifier: UUID
    ) {
        guard let download = activeDownloadsByID[id],
              download.identity == key,
              let context = downloadContexts[key],
              context.attemptIdentifier == attemptIdentifier,
              context.terminationReason != nil else {
            return
        }
        let message = String(
            localized: "download.browser.writerQuiescenceUnavailable",
            defaultValue: "WebKit did not confirm that the active browser download stopped. Harbor left its temporary file and recovery state untouched.",
            comment: "Failure shown when WebKit does not acknowledge cancellation of an active browser download."
        )
        activeDownloadStopFailures[id] = ActiveDownloadStopFailure(
            attemptIdentifier: attemptIdentifier,
            message: message
        )
        let result = ActiveDownloadStopResult(
            resumeData: nil,
            writerQuiescenceUnavailableMessage: message
        )
        let waiters = stopWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0(result) }
    }

    private func finishActiveDownloadStop(
        id: UUID,
        key: ObjectIdentifier,
        resumeData: Data?
    ) {
        guard activeDownloadsByID[id]?.identity == key,
              let stoppedContext = downloadContexts.removeValue(forKey: key),
              let reason = stoppedContext.terminationReason else {
            return
        }
        activeDownloadsByID.removeValue(forKey: id)
        let hadTimedOut = activeDownloadStopFailures.removeValue(forKey: id) != nil

        if let publication = completionPublications[id],
           publication.attemptIdentifier == stoppedContext.attemptIdentifier {
            // downloadDidFinish won the stop race and transferred payload
            // ownership to an asynchronous integrity publication. Do not
            // delete its source path, and do not release quiescence until the
            // resulting completion/failure event is delivered.
            let waiters = stopWaiters.removeValue(forKey: id) ?? []
            Task { @MainActor [weak self] in
                _ = await self?.deliverCompletionPublication(
                    id: id,
                    attemptIdentifier: publication.attemptIdentifier
                )
                let result = ActiveDownloadStopResult(
                    resumeData: nil,
                    writerQuiescenceUnavailableMessage: nil
                )
                waiters.forEach { $0(result) }
            }
            return
        }

        switch reason {
        case .pause:
            if let temporaryURL = stoppedContext.temporaryURL {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if resumeData != nil {
                resumableWebViews[id] = stoppedContext.webView
            } else {
                resumableWebViews.removeValue(forKey: id)
            }
        case .cancel:
            resumableWebViews.removeValue(forKey: id)
            if let temporaryURL = stoppedContext.temporaryURL {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let result = ActiveDownloadStopResult(
            resumeData: reason == .pause ? resumeData : nil,
            writerQuiescenceUnavailableMessage: nil
        )
        let waiters = stopWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0(result) }
        if hadTimedOut {
            if isQuiescingForShutdown {
                completedActiveStopResults[id] = (
                    stoppedContext.attemptIdentifier,
                    result
                )
            }
            onEvent(
                .quiescedAfterTimeout(
                    id: id,
                    attemptIdentifier: stoppedContext.attemptIdentifier,
                    resumeData: reason == .pause ? resumeData : nil,
                    wasCancelling: reason == .cancel
                )
            )
        }
    }

    private func currentAttemptIdentifier(for id: UUID) -> UUID? {
        if let download = activeDownloadsByID[id],
           let context = downloadContexts[download.identity] {
            return context.attemptIdentifier
        }
        if let pending = pendingResumes[id] {
            return pending.session.attemptIdentifier
        }
        if let pending = pendingNavigationConversions[id] {
            return pending.attemptIdentifier
        }
        if let pending = pendingNavigationStops[id] {
            return pending.session.attemptIdentifier
        }
        if let activeSession, activeSession.downloadID == id {
            return activeSession.attemptIdentifier
        }
        return nil
    }

    private func shouldDownloadInBrowser(response: URLResponse, isForMainFrame: Bool) -> Bool {
        guard isForMainFrame else {
            return false
        }

        let normalizedMimeType = response.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return isHTMLMimeType(normalizedMimeType) == false
    }

    private func isHTMLMimeType(_ mimeType: String?) -> Bool {
        mimeType == "text/html" || mimeType == "application/xhtml+xml"
    }

    private func shouldIgnoreNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let frameLoadInterruptedByPolicyChange = 102

        if nsError.domain == WKErrorDomain,
           nsError.code == frameLoadInterruptedByPolicyChange {
            return true
        }

        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return true
        }

        return false
    }

    private func temporaryDownloadURL(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) throws -> URL {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        return recoveryFileURL(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier
        )
    }

    private func recoveryFileURL(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
            )
            .appendingPathExtension("part")
    }

    private func persistCompletedTemporaryManifest(
        _ manifest: CompletedDownloadHandoffManifest,
        payloadURL: URL
    ) throws -> URL {
        // The payload must reach stable storage before the ownership marker.
        // A crash after the marker is committed can then safely finish hashing
        // and publication from this deterministic Application Support path.
        try DurableFileSystem.synchronizeFile(at: payloadURL)
        try DurableFileSystem.synchronizeParentDirectory(of: payloadURL)
        let url = Self.completedTemporaryManifestURL(
            temporaryDirectory: temporaryDirectory,
            downloadID: manifest.downloadID,
            attemptIdentifier: manifest.attemptIdentifier
        )
        try JSONEncoder().encode(
            BrowserCompletedTemporaryManifest(handoff: manifest)
        ).write(to: url, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: url)
        try DurableFileSystem.synchronizeParentDirectory(of: url)
        return url
    }

    private nonisolated static func finalizedCompletedTemporaryManifest(
        _ claimingManifest: CompletedDownloadHandoffManifest,
        payloadURL: URL,
        metadataURL: URL
    ) throws -> CompletedDownloadHandoffManifest {
        let payloadSHA256 = try sha256(at: payloadURL)
        if claimingManifest.payloadSHA256.isEmpty == false,
           claimingManifest.payloadSHA256 != payloadSHA256 {
            throw CompletedDownloadHandoffError.invalidPayload
        }
        let readyManifest = CompletedDownloadHandoffManifest(
            downloadID: claimingManifest.downloadID,
            attemptIdentifier: claimingManifest.attemptIdentifier,
            owner: claimingManifest.owner,
            sourceURL: claimingManifest.sourceURL,
            statusCode: claimingManifest.statusCode,
            mimeType: claimingManifest.mimeType,
            suggestedFilename: claimingManifest.suggestedFilename,
            actualBytes: claimingManifest.actualBytes,
            expectedBytes: claimingManifest.expectedBytes,
            payloadSHA256: payloadSHA256,
            createdAt: claimingManifest.createdAt
        )
        try JSONEncoder().encode(
            BrowserCompletedTemporaryManifest(handoff: readyManifest)
        ).write(to: metadataURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: metadataURL)
        try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        return readyManifest
    }

    private nonisolated static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), data.isEmpty == false {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func validatedBrowserCompletedByteCount(
        response: HTTPURLResponse,
        actualBytes: Int64,
        isResumeAttempt: Bool
    ) throws -> Int64 {
        if response.statusCode == 206 {
            let range = try DownloadCoordinator.validatedPartialContentRange(response)
            guard isResumeAttempt,
                  let total = range.total,
                  range.start > 0,
                  range.end == total - 1,
                  total == actualBytes else {
                throw DirectDownloadIncompleteResponseError(
                    actualBytes: actualBytes,
                    expectedBytes: range.total
                )
            }
            return total
        }
        return try DownloadCoordinator.validatedCompletedByteCount(
            response: response,
            actualBytes: actualBytes,
            startedFromResumeData: false,
            resumeOffset: nil
        )
    }

    private nonisolated static func completedTemporaryManifestURL(
        temporaryDirectory: URL,
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
            )
            .appendingPathExtension(completedTemporaryManifestExtension)
    }

    private nonisolated static func temporaryPartURL(
        temporaryDirectory: URL,
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)"
            )
            .appendingPathExtension("part")
    }

    private nonisolated static func temporaryIdentifiers(
        from url: URL
    ) -> (downloadID: UUID, attemptIdentifier: UUID)? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 73,
              name[name.index(name.startIndex, offsetBy: 36)] == "-" else {
            return nil
        }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard let downloadID = UUID(uuidString: String(name[..<separator])),
              let attemptIdentifier = UUID(
                  uuidString: String(name[name.index(after: separator)...])
              ) else {
            return nil
        }
        return (downloadID, attemptIdentifier)
    }

    private nonisolated static func recoverCompletedTemporaryFilesOffMainActor(
        downloadID requestedDownloadID: UUID?,
        fileManager: FileManager,
        temporaryDirectory: URL,
        completedHandoffStore: CompletedDownloadHandoffStore
    ) throws -> [UUID: String] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch let error as POSIXError where error.code == .ENOENT {
            return [:]
        } catch {
            throw error
        }

        var failures: [UUID: String] = [:]
        for metadataURL in contents
        where metadataURL.pathExtension == completedTemporaryManifestExtension {
            guard let identifiers = temporaryIdentifiers(from: metadataURL),
                  requestedDownloadID == nil
                    || identifiers.downloadID == requestedDownloadID else {
                continue
            }
            let payloadURL = temporaryPartURL(
                temporaryDirectory: temporaryDirectory,
                downloadID: identifiers.downloadID,
                attemptIdentifier: identifiers.attemptIdentifier
            )
            let payloadExists: Bool
            do {
                payloadExists = try itemExists(at: payloadURL)
            } catch {
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }
            guard payloadExists else {
                removeCompletedTemporaryFiles(
                    payloadURL: nil,
                    metadataURL: metadataURL,
                    fileManager: fileManager
                )
                continue
            }

            let marker: BrowserCompletedTemporaryManifest
            do {
                let markerData = try Data(contentsOf: metadataURL)
                do {
                    marker = try JSONDecoder().decode(
                        BrowserCompletedTemporaryManifest.self,
                        from: markerData
                    )
                } catch {
                    removeCompletedTemporaryFiles(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL,
                        fileManager: fileManager
                    )
                    continue
                }
            } catch {
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }

            var handoff = marker.handoff
            do {
                let values = try payloadURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard marker.version == BrowserCompletedTemporaryManifest.currentVersion,
                      handoff.version == CompletedDownloadHandoffManifest.currentVersion,
                      handoff.downloadID == identifiers.downloadID,
                      handoff.attemptIdentifier == identifiers.attemptIdentifier,
                      handoff.owner == .browser,
                      handoff.phase == .claiming || handoff.phase == .ready,
                      handoff.destinationPath == nil,
                      handoff.placementStagingPath == nil,
                      handoff.actualBytes >= 0,
                      handoff.expectedBytes == handoff.actualBytes,
                      (handoff.phase == .claiming && handoff.payloadSHA256.isEmpty)
                        || (handoff.phase == .ready
                            && handoff.payloadSHA256.count == SHA256.byteCount * 2),
                      handoff.statusCode.map({ (200 ... 299).contains($0) }) != false,
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      values.fileSize.map(Int64.init) == handoff.actualBytes else {
                    removeCompletedTemporaryFiles(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL,
                        fileManager: fileManager
                    )
                    continue
                }

                if handoff.phase == .claiming {
                    handoff = try finalizedCompletedTemporaryManifest(
                        handoff,
                        payloadURL: payloadURL,
                        metadataURL: metadataURL
                    )
                } else if try sha256(at: payloadURL) != handoff.payloadSHA256 {
                    removeCompletedTemporaryFiles(
                        payloadURL: payloadURL,
                        metadataURL: metadataURL,
                        fileManager: fileManager
                    )
                    continue
                }
            } catch {
                // Failure to read file attributes is operational. The marker
                // and payload remain the only ownership journal, so retain
                // both and block a destructive retry.
                failures[identifiers.downloadID] = error.localizedDescription
                continue
            }

            do {
                _ = try completedHandoffStore.publish(
                    payloadAt: payloadURL,
                    manifest: handoff
                )
                removeCompletedTemporaryFiles(
                    payloadURL: nil,
                    metadataURL: metadataURL,
                    fileManager: fileManager
                )
            } catch {
                // The marker and payload have already passed their own
                // integrity checks. A publish failure therefore describes the
                // destination store, not corrupt completed bytes.
                failures[identifiers.downloadID] = error.localizedDescription
            }
        }
        return failures
    }

    private nonisolated static func itemExists(at url: URL) throws -> Bool {
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

    private nonisolated static func removeCompletedTemporaryFiles(
        payloadURL: URL?,
        metadataURL: URL,
        fileManager: FileManager
    ) {
        if let payloadURL {
            try? fileManager.removeItem(at: payloadURL)
        }
        do {
            try fileManager.removeItem(at: metadataURL)
            try DurableFileSystem.synchronizeParentDirectory(of: metadataURL)
        } catch {
            // Best-effort cleanup. A malformed marker left behind cannot be
            // published because every scan repeats the integrity validation.
        }
    }

    private func discardPartialFiles(downloadID: UUID) {
        try? discardPartialFilesThrowing(downloadID: downloadID)
    }

    private func discardPartialFilesThrowing(downloadID: UUID) throws {
        let legacyURL = temporaryDirectory
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")
        var removedEntry = false
        if try Self.itemExists(at: legacyURL) {
            try fileManager.removeItem(at: legacyURL)
            removedEntry = true
        }

        guard try Self.itemExists(at: temporaryDirectory) else {
            return
        }
        let contents = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents where (url.pathExtension == "part"
            || url.pathExtension == Self.completedTemporaryManifestExtension)
            && Self.temporaryIdentifiers(from: url)?.downloadID == downloadID {
            try fileManager.removeItem(at: url)
            removedEntry = true
        }
        if removedEntry {
            try DurableFileSystem.synchronizeDirectory(at: temporaryDirectory)
        }
    }

    private func session(for webView: WKWebView) -> BrowserDownloadSession? {
        guard let activeSession, activeSession.webView === webView else {
            return nil
        }

        return activeSession
    }

    private func refreshSessionURL(from webView: WKWebView) {
        guard let session = session(for: webView), let url = webView.url else {
            return
        }

        session.currentURL = url
    }

    private func completeNavigationFailure(_ error: Error, from webView: WKWebView) {
        if let pendingStop = pendingNavigationStops.first(where: {
            $0.value.session.webView === webView
        }) {
            finishPendingNavigationStop(
                id: pendingStop.key,
                sessionIdentifier: pendingStop.value.session.id,
                webViewIdentifier: ObjectIdentifier(pendingStop.value.session.webView),
                resumeData: nil
            )
            return
        }

        guard let activeSession = session(for: webView) else {
            return
        }

        if shouldIgnoreNavigationError(error) || activeSession.hasStartedDownload {
            return
        }

        let downloadID = activeSession.downloadID
        let attemptIdentifier = activeSession.attemptIdentifier
        self.activeSession = nil
        pendingNavigationConversions.removeValue(forKey: downloadID)
        pendingNavigationStops.removeValue(forKey: downloadID)
        onEvent(
            .failed(
                id: downloadID,
                attemptIdentifier: attemptIdentifier,
                failure: DirectDownloadFailure(error: error, resumeData: nil)
            )
        )
    }
}

extension BrowserDownloadCoordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload,
           let session = session(for: webView) {
            pendingNavigationConversions[session.downloadID] = session
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let activeSession = session(for: webView) else {
            decisionHandler(.cancel)
            return
        }

        activeSession.currentURL = navigationResponse.response.url ?? activeSession.currentURL

        if shouldDownloadInBrowser(
            response: navigationResponse.response,
            isForMainFrame: navigationResponse.isForMainFrame
        ) {
            pendingNavigationConversions[activeSession.downloadID] = activeSession
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let activeSession = session(for: webView) else {
            return
        }

        activeSession.isLoading = true
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let activeSession = session(for: webView) else {
            return
        }

        activeSession.isLoading = false
        activeSession.pageTitle = webView.title
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeNavigationFailure(error, from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeNavigationFailure(error, from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let session = pendingNavigationConversions.values.first(where: {
            $0.webView === webView
        }) ?? activeSession,
              session.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        if cancelPendingNavigationDownloadIfNeeded(
            download,
            session: session,
            webView: webView
        ) {
            return
        }
        pendingNavigationConversions.removeValue(forKey: session.downloadID)
        track(download: download, for: session)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let session = pendingNavigationConversions.values.first(where: {
            $0.webView === webView
        }) ?? activeSession,
              session.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        if cancelPendingNavigationDownloadIfNeeded(
            download,
            session: session,
            webView: webView
        ) {
            return
        }
        pendingNavigationConversions.removeValue(forKey: session.downloadID)
        track(download: download, for: session)
    }
}

extension BrowserDownloadCoordinator: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)

        guard var context = downloadContexts[key] else {
            completionHandler(nil)
            return
        }

        do {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DirectDownloadInvalidRangeResponseError()
            }
            context.statusCode = httpResponse.statusCode
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw DirectDownloadHTTPStatusError(statusCode: httpResponse.statusCode)
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                throw URLError(.badServerResponse)
            }

            let temporaryURL = try temporaryDownloadURL(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier
            )

            // WebKit requires every proposed destination, including a resumed one,
            // to be absent when the delegate supplies it.
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }

            context.suggestedFilename = suggestedFilename
            context.responseMimeType = response.mimeType
            context.statusCode = httpResponse.statusCode
            context.httpResponse = httpResponse
            if httpResponse.statusCode == 206 {
                let range = try DownloadCoordinator.validatedPartialContentRange(httpResponse)
                guard context.isResumeAttempt, range.start > 0,
                      let total = range.total else {
                    throw DirectDownloadInvalidRangeResponseError()
                }
                context.expectedBytes = total
            } else {
                guard httpResponse.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw DirectDownloadInvalidRangeResponseError()
                }
                if DownloadCoordinator.responseUsesIdentityEncoding(httpResponse) {
                    context.expectedBytes = try DownloadCoordinator.declaredContentLength(httpResponse)
                        ?? max(response.expectedContentLength, 0)
                } else {
                    context.expectedBytes = 0
                }
            }
            context.temporaryURL = temporaryURL
            downloadContexts[key] = context

            completionHandler(temporaryURL)

            clearActiveSession(matching: context)
            onEvent(
                .started(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    suggestedFilename: suggestedFilename,
                    expectedBytes: context.expectedBytes,
                    responseMimeType: context.responseMimeType,
                    statusCode: context.statusCode,
                    isResumed: context.isResumeAttempt
                )
            )
        } catch {
            context.rejectionError = error
            downloadContexts[key] = context
            completionHandler(nil)
            clearActiveSession(matching: context)
            // Supplying no destination asks WebKit to cancel. Keep ownership
            // until didFailWithError returns its replacement resume blob;
            // falling back to the original opaque blob preserves a safe retry.
        }
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)

        guard let context = downloadContexts.removeValue(forKey: key),
              let temporaryURL = context.temporaryURL
        else {
            return
        }

        if activeDownloadsByID[context.downloadID]?.identity == key {
            activeDownloadsByID.removeValue(forKey: context.downloadID)
        }
        activeDownloadStopFailures.removeValue(forKey: context.downloadID)
        let pendingStopWaiters = context.terminationReason == nil
            ? []
            : (stopWaiters.removeValue(forKey: context.downloadID) ?? [])
        resumableWebViews.removeValue(forKey: context.downloadID)

        var hasDurableCompletionMarker = false
        do {
            let values = try temporaryURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let actualBytes = Int64(fileSize)
            guard let httpResponse = context.httpResponse else {
                throw URLError(.badServerResponse)
            }
            let expectedBytes: Int64
            if DownloadCoordinator.responseUsesIdentityEncoding(httpResponse) {
                expectedBytes = try Self.validatedBrowserCompletedByteCount(
                    response: httpResponse,
                    actualBytes: actualBytes,
                    isResumeAttempt: context.isResumeAttempt
                )
            } else {
                guard httpResponse.statusCode == 200,
                      httpResponse.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw URLError(.cannotDecodeContentData)
                }
                expectedBytes = actualBytes
            }
            let claimingManifest = CompletedDownloadHandoffManifest(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                owner: .browser,
                sourceURL: context.sourceURL,
                statusCode: context.statusCode,
                mimeType: context.responseMimeType,
                suggestedFilename: context.suggestedFilename,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes,
                phase: .claiming
            )
            let completedTemporaryManifestURL = try persistCompletedTemporaryManifest(
                claimingManifest,
                payloadURL: temporaryURL
            )
            hasDurableCompletionMarker = true
            let completedHandoffStore = completedHandoffStore
            let fileManager = fileManager
            let wasResuming = context.isResumeAttempt
            let statusCode = context.statusCode
            let publicationTask = Task.detached(priority: .utility) {
                () -> BrowserDownloadEvent in
                do {
                    let manifest = CompletedDownloadHandoffManifest(
                        downloadID: claimingManifest.downloadID,
                        attemptIdentifier: claimingManifest.attemptIdentifier,
                        owner: claimingManifest.owner,
                        sourceURL: claimingManifest.sourceURL,
                        statusCode: claimingManifest.statusCode,
                        mimeType: claimingManifest.mimeType,
                        suggestedFilename: claimingManifest.suggestedFilename,
                        actualBytes: claimingManifest.actualBytes,
                        expectedBytes: claimingManifest.expectedBytes,
                        createdAt: claimingManifest.createdAt
                    )
                    let claim = try completedHandoffStore.claim(
                        payloadAt: temporaryURL,
                        manifest: manifest
                    )
                    let handoff = try completedHandoffStore.finalize(claim)
                    let event = BrowserDownloadEvent.finished(
                        id: manifest.downloadID,
                        attemptIdentifier: manifest.attemptIdentifier,
                        handoff: handoff
                    )
                    do {
                        try fileManager.removeItem(
                            at: completedTemporaryManifestURL
                        )
                        try DurableFileSystem.synchronizeParentDirectory(
                            of: completedTemporaryManifestURL
                        )
                    } catch {
                        // The handoff is already authoritative; a stale marker
                        // is safely pruned by recovery once its payload is gone.
                    }
                    return event
                } catch {
                    return .failed(
                        id: claimingManifest.downloadID,
                        attemptIdentifier: claimingManifest.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: wasResuming,
                            httpStatusCode: statusCode
                        )
                    )
                }
            }
            completionPublications[context.downloadID] = CompletionPublication(
                attemptIdentifier: context.attemptIdentifier,
                task: publicationTask
            )
            Task { @MainActor [weak self] in
                _ = await self?.deliverCompletionPublication(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                )
                let result = ActiveDownloadStopResult(
                    resumeData: nil,
                    writerQuiescenceUnavailableMessage: nil
                )
                pendingStopWaiters.forEach { $0(result) }
            }
        } catch {
            if hasDurableCompletionMarker == false {
                // Validation proved the payload unusable, or its ownership
                // marker could not be committed. It is not recoverable state.
                try? fileManager.removeItem(at: temporaryURL)
                try? DurableFileSystem.synchronizeParentDirectory(of: temporaryURL)
            }
            onEvent(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: context.isResumeAttempt,
                        httpStatusCode: context.statusCode
                    )
                )
            )
            let result = ActiveDownloadStopResult(
                resumeData: nil,
                writerQuiescenceUnavailableMessage: nil
            )
            pendingStopWaiters.forEach { $0(result) }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let context = downloadContexts[key] else {
            return
        }

        if context.terminationReason != nil {
            // A delegate failure is also authoritative proof that WebKit's
            // writer stopped. Complete a pending pause/cancel even if the
            // separate cancel completion handler is delayed or never called.
            finishActiveDownloadStop(
                id: context.downloadID,
                key: key,
                resumeData: resumeData
            )
            return
        }

        downloadContexts.removeValue(forKey: key)
        if activeDownloadsByID[context.downloadID]?.identity == key {
            activeDownloadsByID.removeValue(forKey: context.downloadID)
        }

        if let temporaryURL = context.temporaryURL {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let reportedError = context.rejectionError ?? error
        let shouldRetireResumeData = context.isResumeAttempt
            && Self.shouldRetireResumeData(
                after: reportedError,
                statusCode: context.statusCode
            )
        let preservedResumeData = shouldRetireResumeData
            ? nil
            : (resumeData ?? context.originalResumeData)
        if preservedResumeData != nil {
            resumableWebViews[context.downloadID] = context.webView
        } else {
            resumableWebViews.removeValue(forKey: context.downloadID)
        }

        clearActiveSession(matching: context)

        onEvent(
            .failed(
                id: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                failure: DirectDownloadFailure(
                    error: reportedError,
                    resumeData: preservedResumeData,
                    wasResuming: context.isResumeAttempt,
                    httpStatusCode: context.statusCode
                )
            )
        )
    }

    nonisolated static func shouldRetireResumeData(
        after error: Error,
        statusCode: Int?
    ) -> Bool {
        if error is DirectDownloadInvalidRangeResponseError {
            return true
        }
        if let statusCode,
           (200 ... 299).contains(statusCode) == false,
           DirectDownloadRetryPolicy.isRetryableHTTPStatus(statusCode) == false {
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

extension BrowserDownloadCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }

        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let session = session(for: webView) else {
            return
        }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return
            }
            let result = await self.quiesceDownload(id: session.downloadID)
            if let message = result?.writerQuiescenceUnavailableMessage,
               result?.attemptIdentifier == session.attemptIdentifier {
                self.onEvent(
                    .quiescenceFailed(
                        id: session.downloadID,
                        attemptIdentifier: session.attemptIdentifier,
                        message: message
                    )
                )
                return
            }
            if let message = result?.completionUnavailableMessage,
               result?.attemptIdentifier == session.attemptIdentifier {
                self.onEvent(
                    .completionUnavailable(
                        id: session.downloadID,
                        attemptIdentifier: session.attemptIdentifier,
                        message: message
                    )
                )
                return
            }
            self.onEvent(
                .dismissed(
                    id: session.downloadID,
                    attemptIdentifier: session.attemptIdentifier,
                    resumeData: result?.attemptIdentifier == session.attemptIdentifier
                        ? result?.resumeData
                        : nil
                )
            )
        }
    }
}
