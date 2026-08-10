import Foundation
import Observation
import WebKit

enum BrowserDownloadEvent {
    case started(
        id: UUID,
        suggestedFilename: String?,
        expectedBytes: Int64,
        responseMimeType: String?,
        statusCode: Int?,
        isResumed: Bool
    )
    case finished(
        id: UUID,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?,
        expectedBytes: Int64
    )
    case failed(id: UUID, failure: DirectDownloadFailure)
}

@MainActor
@Observable
final class BrowserDownloadSession: Identifiable {
    let id = UUID()
    let downloadID: UUID
    let sourceURL: URL
    let displayName: String

    @ObservationIgnored let webView: WKWebView

    var currentURL: URL?
    var pageTitle: String?
    var statusMessage = "Complete any required sign-in or verification. Harbor will capture the file automatically."
    var isLoading = true

    fileprivate var hasStartedDownload = false

    init(downloadID: UUID, sourceURL: URL, displayName: String, webView: WKWebView) {
        self.downloadID = downloadID
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
        let sourceURL: URL
        let webView: WKWebView
        let isResumeAttempt: Bool
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var expectedBytes: Int64
        var temporaryURL: URL?
        var terminationReason: TerminationReason?
    }

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let onEvent: @MainActor (BrowserDownloadEvent) -> Void
    private let resumeDownload: ResumeDownload
    private let cancelUnownedDownload: CancelUnownedDownload

    private var activeSession: BrowserDownloadSession?
    private var pendingResumeSessions: [UUID: BrowserDownloadSession] = [:]
    private var downloadContexts: [ObjectIdentifier: DownloadContext] = [:]
    private var activeDownloadsByID: [UUID: WKDownload] = [:]
    private var resumableWebViews: [UUID: WKWebView] = [:]

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
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
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("HarborBrowserDownloads", isDirectory: true)
        self.resumeDownload = resumeDownload
        self.cancelUnownedDownload = cancelUnownedDownload
        self.onEvent = onEvent

        super.init()

        try? fileManager.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    func startSession(
        downloadID: UUID,
        sourceURL: URL,
        displayName: String,
        resumeData: Data? = nil
    ) -> BrowserDownloadSession {
        if let activeSession, activeSession.downloadID == downloadID {
            return activeSession
        }

        if let pendingSession = pendingResumeSessions[downloadID] {
            cancelSession()
            activeSession = pendingSession
            return pendingSession
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
            sourceURL: sourceURL,
            displayName: displayName,
            webView: webView
        )

        activeSession = session

        if let resumeData {
            resumableWebViews[downloadID] = webView
            session.statusMessage = "Resuming secure browser-backed download…"
            session.isLoading = false
            pendingResumeSessions[downloadID] = session
            resumeDownload(webView, resumeData) { [weak self, weak session] download in
                guard let self, let session else {
                    download.cancel { _ in }
                    return
                }

                guard self.claimPendingResume(
                    downloadID: downloadID,
                    session: session,
                    webView: webView
                ) else {
                    self.cancelUnownedDownload(download)
                    return
                }

                self.track(download: download, for: session, isResumeAttempt: true)
            }
        } else {
            webView.load(URLRequest(url: sourceURL))
        }
        return session
    }

    func claimPendingResume(
        downloadID: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        guard pendingResumeSessions[downloadID]?.id == session.id else {
            return false
        }

        pendingResumeSessions.removeValue(forKey: downloadID)
        return activeSession?.id == session.id
            && activeSession?.webView === webView
            && session.webView === webView
    }

    func cancelSession() {
        activeSession?.webView.stopLoading()
        activeSession = nil
    }

    func hasActiveDownload(id: UUID) -> Bool {
        activeDownloadsByID[id] != nil
    }

    func hasResumableWebView(id: UUID) -> Bool {
        resumableWebViews[id] != nil
    }

    func pauseDownloadAndWait(id: UUID) async -> Data? {
        await withCheckedContinuation { continuation in
            guard stopDownload(
                id: id,
                reason: .pause,
                continuation: continuation
            ) else {
                continuation.resume(returning: nil)
                return
            }
        }
    }

    func cancelDownloadAndWait(id: UUID) async {
        _ = await withCheckedContinuation { continuation in
            guard stopDownload(
                id: id,
                reason: .cancel,
                continuation: continuation
            ) else {
                continuation.resume(returning: nil)
                return
            }
        }
    }

    func discardRecoveryData(id: UUID) {
        pendingResumeSessions.removeValue(forKey: id)
        resumableWebViews.removeValue(forKey: id)
        try? fileManager.removeItem(at: recoveryFileURL(downloadID: id))
    }

    func discardOrphanedTemporaryFiles() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
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

    private func track(
        download: WKDownload,
        for session: BrowserDownloadSession,
        isResumeAttempt: Bool = false
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
            sourceURL: session.sourceURL,
            webView: session.webView,
            isResumeAttempt: isResumeAttempt,
            suggestedFilename: nil,
            responseMimeType: nil,
            statusCode: nil,
            expectedBytes: 0,
            temporaryURL: nil,
            terminationReason: nil
        )

        activeDownloadsByID[session.downloadID] = download
        download.delegate = self
    }

    private func clearActiveSession(matching context: DownloadContext) {
        guard activeSession?.downloadID == context.downloadID,
              activeSession?.webView === context.webView else {
            return
        }

        activeSession = nil
    }

    @discardableResult
    private func stopDownload(
        id: UUID,
        reason: TerminationReason,
        continuation: CheckedContinuation<Data?, Never>?
    ) -> Bool {
        guard let download = activeDownloadsByID[id] else {
            return false
        }

        let key = ObjectIdentifier(download)
        guard var context = downloadContexts[key] else {
            return false
        }

        context.terminationReason = reason
        downloadContexts[key] = context
        download.cancel { [weak self] resumeData in
            guard let self else {
                continuation?.resume(returning: resumeData)
                return
            }

            self.activeDownloadsByID.removeValue(forKey: id)
            let stoppedContext = self.downloadContexts.removeValue(forKey: key) ?? context

            switch reason {
            case .pause:
                if let temporaryURL = stoppedContext.temporaryURL {
                    try? self.fileManager.removeItem(at: temporaryURL)
                }
                if resumeData != nil {
                    self.resumableWebViews[id] = stoppedContext.webView
                } else {
                    self.resumableWebViews.removeValue(forKey: id)
                }
            case .cancel:
                self.resumableWebViews.removeValue(forKey: id)
                if let temporaryURL = stoppedContext.temporaryURL {
                    try? self.fileManager.removeItem(at: temporaryURL)
                }
            }

            continuation?.resume(returning: resumeData)
        }
        return true
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

    private func temporaryDownloadURL(downloadID: UUID) throws -> URL {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        return recoveryFileURL(downloadID: downloadID)
    }

    private func recoveryFileURL(downloadID: UUID) -> URL {
        temporaryDirectory
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")
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
        guard let activeSession = session(for: webView) else {
            return
        }

        if shouldIgnoreNavigationError(error) || activeSession.hasStartedDownload {
            return
        }

        let downloadID = activeSession.downloadID
        self.activeSession = nil
        onEvent(
            .failed(
                id: downloadID,
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
        guard let activeSession, activeSession.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        track(download: download, for: activeSession)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let activeSession, activeSession.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        track(download: download, for: activeSession)
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
            let temporaryURL = try temporaryDownloadURL(downloadID: context.downloadID)

            // WebKit requires every proposed destination, including a resumed one,
            // to be absent when the delegate supplies it.
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }

            context.suggestedFilename = suggestedFilename
            context.responseMimeType = response.mimeType
            context.statusCode = (response as? HTTPURLResponse)?.statusCode
            context.expectedBytes = max(response.expectedContentLength, 0)
            context.temporaryURL = temporaryURL
            downloadContexts[key] = context

            completionHandler(temporaryURL)

            clearActiveSession(matching: context)
            onEvent(
                .started(
                    id: context.downloadID,
                    suggestedFilename: suggestedFilename,
                    expectedBytes: context.expectedBytes,
                    responseMimeType: context.responseMimeType,
                    statusCode: context.statusCode,
                    isResumed: context.isResumeAttempt
                )
            )
        } catch {
            completionHandler(nil)
            clearActiveSession(matching: context)
            downloadContexts.removeValue(forKey: key)
            activeDownloadsByID.removeValue(forKey: context.downloadID)
            resumableWebViews.removeValue(forKey: context.downloadID)
            onEvent(
                .failed(
                    id: context.downloadID,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: context.isResumeAttempt
                    )
                )
            )
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

        activeDownloadsByID.removeValue(forKey: context.downloadID)
        resumableWebViews.removeValue(forKey: context.downloadID)

        onEvent(
            .finished(
                id: context.downloadID,
                temporaryURL: temporaryURL,
                suggestedFilename: context.suggestedFilename,
                responseMimeType: context.responseMimeType,
                statusCode: context.statusCode,
                expectedBytes: context.expectedBytes
            )
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let context = downloadContexts[key] else {
            return
        }

        if context.terminationReason != nil {
            return
        }

        downloadContexts.removeValue(forKey: key)
        activeDownloadsByID.removeValue(forKey: context.downloadID)

        if let temporaryURL = context.temporaryURL {
            try? fileManager.removeItem(at: temporaryURL)
        }

        if resumeData != nil {
            resumableWebViews[context.downloadID] = context.webView
        } else {
            resumableWebViews.removeValue(forKey: context.downloadID)
        }

        onEvent(
            .failed(
                id: context.downloadID,
                failure: DirectDownloadFailure(
                    error: error,
                    resumeData: resumeData,
                    wasResuming: context.isResumeAttempt
                )
            )
        )
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
        guard session(for: webView) != nil else {
            return
        }

        cancelSession()
    }
}
