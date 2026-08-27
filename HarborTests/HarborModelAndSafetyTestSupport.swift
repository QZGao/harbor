import Foundation
import XCTest
@testable import Harbor

nonisolated struct MediaFormatTestFixture {
    let sourceURL: URL
    let videoFormat: MediaDownloadFormatOption
    let audioFormat: MediaDownloadFormatOption
    let metadata: MediaDownloadMetadata
    let selection: MediaDownloadFormatSelection
}

nonisolated func makeMediaFormatTestFixture() -> MediaFormatTestFixture {
    let sourceURL = URL(string: "https://example.com/video")!
    let videoFormat = MediaDownloadFormatOption(
        formatID: "137",
        container: "mp4",
        videoCodec: "avc1.640028",
        audioCodec: nil,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        dynamicRange: "SDR",
        bitrateKbps: 4_500,
        estimatedBytes: 9_000_000
    )
    let audioFormat = MediaDownloadFormatOption(
        formatID: "140",
        container: "m4a",
        videoCodec: nil,
        audioCodec: "mp4a.40.2",
        width: nil,
        height: nil,
        framesPerSecond: nil,
        dynamicRange: nil,
        bitrateKbps: 128,
        estimatedBytes: 1_000_000,
        language: "en",
        formatNote: "English (Original)",
        audioChannels: 2,
        languagePreference: 10
    )
    let metadata = MediaDownloadMetadata(
        title: "Video",
        platform: "Test",
        extractorKey: "Test",
        thumbnailURL: nil,
        webpageURL: sourceURL,
        expectedBytes: 10_000_000,
        mediaType: .video,
        entryCount: 1,
        capabilities: MediaDownloadCapabilities(formatOptions: [videoFormat, audioFormat])
    )
    return MediaFormatTestFixture(
        sourceURL: sourceURL,
        videoFormat: videoFormat,
        audioFormat: audioFormat,
        metadata: metadata,
        selection: MediaDownloadFormatSelection(format: videoFormat, audioFormat: audioFormat)
    )
}

final class ConcurrentMoveResults: @unchecked Sendable {
    struct Snapshot {
        let successfulIndices: [Int]
        let cocoaErrorCodes: [CocoaError.Code]
        let unexpectedErrors: [String]
    }

    private let lock = NSLock()
    private var successfulIndices: [Int] = []
    private var cocoaErrorCodes: [CocoaError.Code] = []
    private var unexpectedErrors: [String] = []

    func recordSuccess(_ index: Int) {
        lock.lock()
        successfulIndices.append(index)
        lock.unlock()
    }

    func recordCocoaError(_ code: CocoaError.Code) {
        lock.lock()
        cocoaErrorCodes.append(code)
        lock.unlock()
    }

    func recordUnexpectedError(_ error: Error) {
        lock.lock()
        unexpectedErrors.append(error.localizedDescription)
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            successfulIndices: successfulIndices,
            cocoaErrorCodes: cocoaErrorCodes,
            unexpectedErrors: unexpectedErrors
        )
    }
}
actor AsyncTestGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isReleased == false else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}
actor AsyncTestCounter {
    private var value = 0

    func incrementAndGet() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int {
        value
    }
}
nonisolated final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }
}

nonisolated final class ManagedProcessTestState: @unchecked Sendable {
    struct Snapshot {
        let stdout: String
        let stderr: String
        let stdoutAtTermination: String
        let stderrAtTermination: String
        let termination: ManagedChildProcessTermination?
    }

    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""
    private var stdoutAtTermination = ""
    private var stderrAtTermination = ""
    private var termination: ManagedChildProcessTermination?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            stdout: stdout,
            stderr: stderr,
            stdoutAtTermination: stdoutAtTermination,
            stderrAtTermination: stderrAtTermination,
            termination: termination
        )
    }

    func appendStdout(_ output: String) {
        lock.lock()
        stdout += output
        lock.unlock()
    }

    func appendStderr(_ output: String) {
        lock.lock()
        stderr += output
        lock.unlock()
    }

    func recordTermination(_ value: ManagedChildProcessTermination) {
        lock.lock()
        stdoutAtTermination = stdout
        stderrAtTermination = stderr
        termination = value
        lock.unlock()
    }
}

nonisolated final class DirectDownloadTestEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailures: [DirectDownloadFailure] = []
    private var storedProgress: [(bytesWritten: Int64, expectedBytes: Int64)] = []
    private var storedCompletedURL: URL?
    private var storedCompletedSuggestedFilename: String?
    private var storedCompletedResponseMimeType: String?
    private var storedCompletedStatusCode: Int?

    var firstFailure: DirectDownloadFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures.first
    }

    var failures: [DirectDownloadFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }

    var progressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedProgress.count
    }

    var completedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedURL
    }

    var completedSuggestedFilename: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedSuggestedFilename
    }

    var completedResponseMimeType: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedResponseMimeType
    }

    var completedStatusCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedCompletedStatusCode
    }

    func recordFailure(_ failure: DirectDownloadFailure) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedFailures.append(failure)
        return storedFailures.count
    }

    func recordProgress(bytesWritten: Int64, expectedBytes: Int64) {
        lock.lock()
        storedProgress.append((bytesWritten, expectedBytes))
        lock.unlock()
    }


    func recordCompletion(_ handoff: CompletedDownloadHandoff) {
        lock.lock()
        storedCompletedURL = handoff.availablePayloadURL
        storedCompletedSuggestedFilename = handoff.manifest.suggestedFilename
        storedCompletedResponseMimeType = handoff.manifest.mimeType
        storedCompletedStatusCode = handoff.manifest.statusCode
        lock.unlock()
    }


}

nonisolated final class KnownZeroOverflowURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private static var ranges: [String?] = []

    static var capturedRanges: [String?] {
        stateLock.withLock { ranges }
    }

    static func reset() {
        stateLock.withLock {
            ranges = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "known-zero.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let range = request.value(forHTTPHeaderField: "Range")
        let requestNumber = Self.stateLock.withLock { () -> Int in
            Self.ranges.append(range)
            return Self.ranges.count
        }

        if requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "0",
                    "Content-Encoding": "identity",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"zero-v1\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcde".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if range == "bytes=5-" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "0",
                    "Content-Range": "bytes */5",
                    "Content-Encoding": "identity",
                    "ETag": "\"zero-v1\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "3",
                "Content-Encoding": "identity",
                "Content-Type": "application/octet-stream",
                "ETag": "\"fresh-v2\""
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("xyz".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated final class InterruptingRangeURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedHeaders: Sendable {
        let range: String?
        let ifRange: String?
    }

    private static let stateLock = NSLock()
    private static var headers: [CapturedHeaders] = []
    private static var shouldRejectFirstResume = false
    private static var shouldOverrunFirstResume = false
    private static var shouldOmitValidator = false
    private static var shouldChangeValidatorOnFirstResume = false
    private static var shouldFallbackToFullResponseOnFirstResume = false
    private static var shouldCompletePartialWithHTML416 = false
    private static var shouldCompletePartialWithoutValidator416 = false

    static var capturedHeaders: [CapturedHeaders] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return headers
    }

    static func reset(
        rejectFirstResume: Bool = false,
        overlongFirstResume: Bool = false,
        omitValidator: Bool = false,
        changeValidatorOnFirstResume: Bool = false,
        fallbackToFullResponseOnFirstResume: Bool = false,
        completePartialWithHTML416: Bool = false,
        completePartialWithoutValidator416: Bool = false
    ) {
        stateLock.lock()
        headers = []
        shouldRejectFirstResume = rejectFirstResume
        shouldOverrunFirstResume = overlongFirstResume
        shouldOmitValidator = omitValidator
        shouldChangeValidatorOnFirstResume = changeValidatorOnFirstResume
        shouldFallbackToFullResponseOnFirstResume = fallbackToFullResponseOnFirstResume
        shouldCompletePartialWithHTML416 = completePartialWithHTML416
        shouldCompletePartialWithoutValidator416 = completePartialWithoutValidator416
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "recovery.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        Self.stateLock.lock()
        Self.headers.append(CapturedHeaders(range: range, ifRange: ifRange))
        let requestNumber = Self.headers.count
        let rejectFirstResume = Self.shouldRejectFirstResume
        let overrunFirstResume = Self.shouldOverrunFirstResume
        let omitValidator = Self.shouldOmitValidator
        let changeValidatorOnFirstResume = Self.shouldChangeValidatorOnFirstResume
        let fallbackToFullResponseOnFirstResume = Self.shouldFallbackToFullResponseOnFirstResume
        let completePartialWithHTML416 = Self.shouldCompletePartialWithHTML416
        let completePartialWithoutValidator416 = Self.shouldCompletePartialWithoutValidator416
        Self.stateLock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if range == nil, requestNumber == 1 {
            var headerFields = [
                "Content-Length": "10",
                "Content-Type": fallbackToFullResponseOnFirstResume
                    ? "text/html"
                    : "application/octet-stream"
            ]
            if fallbackToFullResponseOnFirstResume {
                headerFields["Content-Disposition"] = "attachment; filename=old.html"
            }
            if omitValidator == false {
                headerFields["ETag"] = "\"test-etag\""
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcde".utf8))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else {
                    return
                }
                self.client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.networkConnectionLost)
                )
            }
            return
        }

        if omitValidator, range == nil, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "10",
                    "Content-Type": "application/octet-stream"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcdefghij".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if overrunFirstResume,
           range == nil,
           requestNumber == 3 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("abcdefghij".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeValidatorOnFirstResume, range == nil, requestNumber == 3 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("klmnopqrst".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }




        if overrunFirstResume,
           requestNumber == 3,
           range == "bytes=8-",
           ifRange == "\"test-etag\"" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 8-9/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ij".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard range == "bytes=5-", ifRange == "\"test-etag\"" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if completePartialWithHTML416, requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes */5",
                    "Content-Type": "text/html",
                    "Content-Disposition": "attachment; filename=error.html",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if completePartialWithoutValidator416, requestNumber == 1 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes */5",
                    "Content-Type": "application/octet-stream"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if changeValidatorOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Range": "bytes 5-9/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("pqrst".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }



        if fallbackToFullResponseOnFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "8",
                    "ETag": "\"replacement-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("uvwxyz12".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }


        if rejectFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "9",
                    "Content-Type": "text/plain"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else {
                    return
                }
                self.client?.urlProtocol(self, didLoad: Data("Forbidden".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }


        if overrunFirstResume, requestNumber == 2 {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "5",
                    "Content-Range": "bytes 5-7/10",
                    "Content-Type": "application/octet-stream",
                    "ETag": "\"test-etag\""
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fghXX".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }


        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "5",
                "Content-Range": "bytes 5-9/10",
                "Content-Type": "application/octet-stream",
                "ETag": "\"test-etag\""
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fghij".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
