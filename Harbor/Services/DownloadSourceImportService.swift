import AppKit
import Foundation
import UniformTypeIdentifiers

enum DownloadSourceImportService {
    struct TextEntry: Identifiable, Equatable {
        enum Status: Equatable {
            case ready
            case duplicate
            case unsupported
        }

        let id: Int
        let text: String
        let url: URL?
        let status: Status
    }

    static let supportedContentTypes: [UTType] = [
        .fileURL,
        .url,
        .plainText
    ]

    static func supportedURLs(from urls: [URL]) -> [URL] {
        deduplicatedSupportedURLs(urls)
    }

    /// Parses free-form text (for example a pasted list with one link per line)
    /// into the supported download URLs it contains, preserving order and
    /// removing duplicates.
    static func supportedURLs(fromText text: String) -> [URL] {
        urls(from: text)
    }

    static func textEntries(from text: String) -> [TextEntry] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }

        var seenKeys = Set<String>()
        return lines.enumerated().map { index, line in
            let lineURLs = urls(from: line)
            guard lineURLs.count == 1, let url = lineURLs.first else {
                return TextEntry(id: index, text: line, url: nil, status: .unsupported)
            }

            guard seenKeys.insert(deduplicationKey(for: url)).inserted else {
                return TextEntry(id: index, text: line, url: nil, status: .duplicate)
            }

            return TextEntry(id: index, text: line, url: url, status: .ready)
        }
    }

    @MainActor
    static func supportedURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        var collectedURLs: [URL] = []

        if let urlObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) {
            collectedURLs.append(contentsOf: urlObjects.compactMap { object in
                if let url = object as? URL {
                    return url
                }

                return (object as? NSURL).map { $0 as URL }
            })
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) {
            collectedURLs.append(contentsOf: strings.flatMap { object -> [URL] in
                guard let string = object as? NSString else {
                    return []
                }

                return Self.urls(from: string as String)
            })
        } else if let string = pasteboard.string(forType: .string) {
            collectedURLs.append(contentsOf: Self.urls(from: string))
        }

        return deduplicatedSupportedURLs(collectedURLs)
    }

    @discardableResult
    static func loadSupportedURLs(
        from itemProviders: [NSItemProvider],
        completion: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var loadedURLs: [URL] = []
        var didScheduleLoad = false

        func append(_ urls: [URL]) {
            guard urls.isEmpty == false else {
                return
            }

            lock.lock()
            loadedURLs.append(contentsOf: urls)
            lock.unlock()
        }

        for provider in itemProviders {
            if loadItem(
                from: provider,
                typeIdentifier: UTType.fileURL.identifier,
                group: group,
                append: append
            ) {
                didScheduleLoad = true
                continue
            }

            if loadItem(
                from: provider,
                typeIdentifier: UTType.url.identifier,
                group: group,
                append: append
            ) {
                didScheduleLoad = true
                continue
            }

            if loadItem(
                from: provider,
                typeIdentifier: UTType.plainText.identifier,
                group: group,
                append: append
            ) {
                didScheduleLoad = true
            }
        }

        guard didScheduleLoad else {
            return false
        }

        group.notify(queue: .main) {
            let urls = deduplicatedSupportedURLs(loadedURLs)
            Task { @MainActor in
                completion(urls)
            }
        }

        return true
    }

    private static func loadItem(
        from provider: NSItemProvider,
        typeIdentifier: String,
        group: DispatchGroup,
        append: @escaping ([URL]) -> Void
    ) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return false
        }

        group.enter()
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            append(urls(from: item, typeIdentifier: typeIdentifier))
            group.leave()
        }
        return true
    }

    private static func urls(from item: NSSecureCoding?, typeIdentifier: String) -> [URL] {
        switch item {
        case let url as URL:
            return [url]
        case let url as NSURL:
            return [url as URL]
        case let string as String:
            return urls(from: string)
        case let string as NSString:
            return urls(from: string as String)
        case let data as Data:
            if let url = URL(dataRepresentation: data, relativeTo: nil),
               DownloadSourceKind.detect(from: url) != nil {
                return [url]
            }

            guard let string = String(data: data, encoding: .utf8) else {
                return []
            }

            return urls(from: string)
        default:
            return []
        }
    }

    private static func urls(from string: String) -> [URL] {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedString.isEmpty == false else {
            return []
        }

        let containsWhitespace = trimmedString.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        if containsWhitespace == false, let url = supportedURL(from: trimmedString) {
            return [url]
        }

        // Keep text representations of local torrent files intact. Splitting a
        // path such as `/Downloads/My File.torrent` would otherwise resolve only
        // its final token against Harbor's working directory.
        if let fileURL = URL(string: trimmedString),
           fileURL.isFileURL,
           DownloadSourceKind.detect(from: fileURL) == .torrentFile {
            return [fileURL]
        }

        if let localTorrentURL = localTorrentURL(from: trimmedString) {
            return [localTorrentURL]
        }

        let tokenSeparators = CharacterSet.whitespacesAndNewlines
        let tokenURLs = trimmedString
            .components(separatedBy: tokenSeparators)
            .compactMap { supportedURL(from: $0) }
        return deduplicatedSupportedURLs(tokenURLs)
    }

    private static func supportedURL(from candidate: String) -> URL? {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCandidate.isEmpty == false else {
            return nil
        }

        if let url = URL(string: trimmedCandidate),
           DownloadSourceKind.detect(from: url) != nil {
            return url
        }

        return localTorrentURL(from: trimmedCandidate)
    }

    private static func localTorrentURL(from candidate: String) -> URL? {
        guard candidate.contains("://") == false,
              candidate.lowercased().hasPrefix("magnet:") == false else {
            return nil
        }

        let expandedPath: String
        if candidate.hasPrefix("~/") {
            expandedPath = NSString(string: candidate).expandingTildeInPath
        } else {
            expandedPath = candidate
        }

        let fileURL = URL(fileURLWithPath: expandedPath)
        guard DownloadSourceKind.detect(from: fileURL) == .torrentFile else {
            return nil
        }

        return fileURL
    }

    private static func deduplicatedSupportedURLs(_ urls: [URL]) -> [URL] {
        var seenKeys = Set<String>()
        var supportedURLs: [URL] = []

        for url in urls {
            guard DownloadSourceKind.detect(from: url) != nil else {
                continue
            }

            let key = deduplicationKey(for: url)
            guard seenKeys.insert(key).inserted else {
                continue
            }

            supportedURLs.append(url)
        }

        return supportedURLs
    }

    private static func deduplicationKey(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
}
