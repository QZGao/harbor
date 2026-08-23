import CryptoKit
import Foundation

struct ManagedTorrentSource: Equatable, Sendable {
    let fingerprint: String
    let sourceFingerprint: String
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
        if let infoDictionaryRange = TorrentMetainfoParser.infoDictionaryRange(in: data) {
            return Insecure.SHA1.hash(data: data[infoDictionaryRange])
                .map { String(format: "%02x", $0) }
                .joined()
        }

        // Keep deterministic handling for malformed legacy inputs so callers can surface the
        // parser error through aria2 without losing managed-source deduplication.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sourceFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func normalizedInfoHash(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            value.isEmpty == false else {
            return nil
        }

        if value.count == 40, value.allSatisfy(\.isHexDigit) {
            return value
        }

        guard value.count == 32,
              let decoded = decodeBase32(value),
              decoded.count == 20 else {
            return nil
        }

        return decoded.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func decodeBase32(_ value: String) -> [UInt8]? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
        var accumulator: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []

        for character in value {
            guard let decoded = lookup[character] else {
                return nil
            }

            accumulator = (accumulator << 5) | UInt64(decoded)
            bitCount += 5

            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((accumulator >> UInt64(bitCount)) & 0xff))
                accumulator &= bitCount == 0 ? 0 : (1 << UInt64(bitCount)) - 1
            }
        }

        return bitCount == 0 ? bytes : nil
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
            sourceFingerprint: Self.sourceFingerprint(for: data),
            managedURL: managedURL,
            originalURL: originalURL
        )
    }

    nonisolated private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        HarborApplicationSupport.directoryURL(fileManager: fileManager)
            .appendingPathComponent("TorrentSources", isDirectory: true)
    }
}

nonisolated private struct TorrentMetainfoParser {
    private let data: Data
    private var index = 0
    private static let maximumDepth = 128

    private init(data: Data) {
        self.data = data
    }

    static func infoDictionaryRange(in data: Data) -> Range<Data.Index>? {
        var parser = TorrentMetainfoParser(data: data)
        return parser.parseTopLevelInfoDictionary()
    }

    private mutating func parseTopLevelInfoDictionary() -> Range<Data.Index>? {
        guard consume(UInt8(ascii: "d")) else {
            return nil
        }

        var infoRange: Range<Data.Index>?
        var previousKey: Data?

        while currentByte != UInt8(ascii: "e") {
            guard let keyRange = parseByteString(),
                  validateDictionaryKey(data[keyRange], after: &previousKey) else {
                return nil
            }

            let valueStart = index
            guard skipValue(depth: 1) else {
                return nil
            }

            if data[keyRange].elementsEqual("info".utf8) {
                guard infoRange == nil,
                      data[valueStart] == UInt8(ascii: "d") else {
                    return nil
                }
                infoRange = valueStart ..< index
            }
        }

        guard consume(UInt8(ascii: "e")),
              index == data.endIndex else {
            return nil
        }

        return infoRange
    }

    private mutating func skipValue(depth: Int) -> Bool {
        guard depth <= Self.maximumDepth,
              let byte = currentByte else {
            return false
        }

        switch byte {
        case UInt8(ascii: "i"):
            return skipInteger()
        case UInt8(ascii: "l"):
            return skipList(depth: depth)
        case UInt8(ascii: "d"):
            return skipDictionary(depth: depth)
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return parseByteString() != nil
        default:
            return false
        }
    }

    private mutating func skipInteger() -> Bool {
        guard consume(UInt8(ascii: "i")) else {
            return false
        }

        let isNegative = consume(UInt8(ascii: "-"))
        let digitsStart = index

        while let byte = currentByte, byte.isASCIIDigit {
            index += 1
        }

        guard index > digitsStart,
              currentByte == UInt8(ascii: "e") else {
            return false
        }

        let digits = data[digitsStart ..< index]
        guard (digits.count == 1 || digits.first != UInt8(ascii: "0")),
              (isNegative == false || digits.first != UInt8(ascii: "0")) else {
            return false
        }

        index += 1
        return true
    }

    private mutating func skipList(depth: Int) -> Bool {
        guard consume(UInt8(ascii: "l")) else {
            return false
        }

        while currentByte != UInt8(ascii: "e") {
            guard skipValue(depth: depth + 1) else {
                return false
            }
        }

        return consume(UInt8(ascii: "e"))
    }

    private mutating func skipDictionary(depth: Int) -> Bool {
        guard consume(UInt8(ascii: "d")) else {
            return false
        }

        var previousKey: Data?
        while currentByte != UInt8(ascii: "e") {
            guard let keyRange = parseByteString(),
                  validateDictionaryKey(data[keyRange], after: &previousKey),
                  skipValue(depth: depth + 1) else {
                return false
            }
        }

        return consume(UInt8(ascii: "e"))
    }

    private mutating func parseByteString() -> Range<Data.Index>? {
        let lengthStart = index
        while let byte = currentByte, byte.isASCIIDigit {
            index += 1
        }

        guard index > lengthStart,
              currentByte == UInt8(ascii: ":") else {
            return nil
        }

        let digits = data[lengthStart ..< index]
        guard digits.count == 1 || digits.first != UInt8(ascii: "0") else {
            return nil
        }

        var length = 0
        for digit in digits {
            let value = Int(digit - UInt8(ascii: "0"))
            guard length <= (Int.max - value) / 10 else {
                return nil
            }
            length = length * 10 + value
        }

        index += 1
        guard length <= data.endIndex - index else {
            return nil
        }

        let range = index ..< index + length
        index += length
        return range
    }

    private mutating func validateDictionaryKey(
        _ key: Data.SubSequence,
        after previousKey: inout Data?
    ) -> Bool {
        let keyData = Data(key)
        if let previousKey,
           keyData.lexicographicallyPrecedes(previousKey) || keyData == previousKey {
            return false
        }
        previousKey = keyData
        return true
    }

    private var currentByte: UInt8? {
        index < data.endIndex ? data[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else {
            return false
        }
        index += 1
        return true
    }
}

nonisolated private extension UInt8 {
    var isASCIIDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }
}
