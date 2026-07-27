import CryptoKit
import Foundation

struct ManagedTorrentSource: Equatable, Sendable {
    let fingerprint: String
    let managedURL: URL
    let originalURL: URL
}

enum ManagedTorrentSourceStoreError: LocalizedError {
    case emptyTorrent
    case invalidServerResponse
    case unsuccessfulStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTorrent:
            String(
                localized: "torrent.import.empty",
                defaultValue: "The torrent file is empty.",
                comment: "Error shown when a selected torrent file has no data."
            )
        case .invalidServerResponse:
            String(
                localized: "torrent.import.invalidResponse",
                defaultValue: "The torrent server returned an invalid response.",
                comment: "Error shown when a remote torrent URL does not return an HTTP response."
            )
        case let .unsuccessfulStatusCode(statusCode):
            String(
                format: String(
                    localized: "torrent.import.httpStatus",
                    defaultValue: "The torrent server returned HTTP status %lld.",
                    comment: "Error shown when a remote torrent URL returns a failing HTTP status."
                ),
                Int64(statusCode)
            )
        }
    }
}

actor ManagedTorrentSourceStore {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
    }

    func prepareLocalTorrent(
        at sourceURL: URL,
        originalURL: URL? = nil
    ) throws -> ManagedTorrentSource {
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return try persist(data: data, originalURL: originalURL ?? sourceURL)
    }

    func fetchRemoteTorrent(
        from remoteURL: URL,
        using session: URLSession = .shared
    ) async throws -> ManagedTorrentSource {
        let (data, response) = try await session.data(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagedTorrentSourceStoreError.invalidServerResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw ManagedTorrentSourceStoreError.unsuccessfulStatusCode(httpResponse.statusCode)
        }

        return try persist(data: data, originalURL: remoteURL)
    }

    func fetchRemoteTorrent(
        from remoteURL: URL,
        requestHeaders: [RequestHeader]
    ) async throws -> ManagedTorrentSource {
        let data = try await TorrentSourceLoader.load(
            from: remoteURL,
            requestHeaders: requestHeaders
        )
        return try persist(data: data, originalURL: remoteURL)
    }

    func fingerprint(forTorrentAt sourceURL: URL) throws -> String {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.isEmpty == false else {
            throw ManagedTorrentSourceStoreError.emptyTorrent
        }
        return Self.fingerprint(for: data)
    }

    func torrent(at sourceURL: URL, matches fingerprint: String) -> Bool {
        guard let currentFingerprint = try? self.fingerprint(forTorrentAt: sourceURL) else {
            return false
        }

        return currentFingerprint == fingerprint
    }

    nonisolated static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persist(data: Data, originalURL: URL) throws -> ManagedTorrentSource {
        guard data.isEmpty == false else {
            throw ManagedTorrentSourceStoreError.emptyTorrent
        }

        let fingerprint = Self.fingerprint(for: data)
        let managedURL = directoryURL.appendingPathComponent("\(fingerprint).torrent", isDirectory: false)
        if fileManager.fileExists(atPath: managedURL.path) == false {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: managedURL, options: .atomic)
        }

        return ManagedTorrentSource(
            fingerprint: fingerprint,
            managedURL: managedURL,
            originalURL: originalURL
        )
    }

    nonisolated private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        HarborApplicationSupport.directoryURL(fileManager: fileManager)
            .appendingPathComponent("TorrentSources", isDirectory: true)
    }
}
