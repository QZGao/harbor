import Darwin
import Foundation

struct DownloadDestinationResolver: @unchecked Sendable {
    nonisolated(unsafe) private let fileManager: FileManager

    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated func resolvedFilename(
        custom: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL
    ) -> String {
        let trimmedCustom = custom?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let trimmedSuggested = responseSuggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var candidate = trimmedCustom
            ?? trimmedSuggested
            ?? sourceURL.lastPathComponent.nilIfEmpty
            ?? sourceURL.host
            ?? "Download"

        if let trimmedCustom,
           URL(fileURLWithPath: trimmedCustom).pathExtension.isEmpty {
            let extensionSource = URL(fileURLWithPath: trimmedSuggested ?? "").pathExtension.nilIfEmpty
                ?? sourceURL.pathExtension.nilIfEmpty

            if let extensionSource {
                candidate += ".\(extensionSource)"
            }
        }

        return sanitize(candidate)
    }

    nonisolated func uniqueDestinationURL(for filename: String, in directory: URL) throws -> URL {
        let cleanName = sanitize(filename)
        let baseURL = directory.appendingPathComponent(cleanName)

        guard try pathEntryExists(at: baseURL) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? cleanName
            : String(cleanName.dropLast(fileExtension.count + 1))

        var attempt = 2
        while true {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName) \(attempt)"
            } else {
                candidateName = "\(baseName) \(attempt).\(fileExtension)"
            }

            let candidateURL = directory.appendingPathComponent(candidateName)
            if try pathEntryExists(at: candidateURL) == false {
                return candidateURL
            }

            attempt += 1
        }
    }

    nonisolated func moveDownloadedFile(
        from temporaryURL: URL,
        customFilename: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL,
        into directory: URL
    ) throws -> URL {
        try createDirectoryIfNeeded(directory)

        let targetName = resolvedFilename(
            custom: customFilename,
            responseSuggestedFilename: responseSuggestedFilename,
            sourceURL: sourceURL
        )
        while true {
            let destinationURL = try uniqueDestinationURL(for: targetName, in: directory)
            do {
                try moveDownloadedFile(from: temporaryURL, to: destinationURL)
                return destinationURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Another writer won the name after it was selected. Resolve a
                // new name; never remove a file Harbor does not own.
                continue
            }
        }
    }

    nonisolated func destinationURL(
        customFilename: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL,
        in directory: URL
    ) throws -> URL {
        try createDirectoryIfNeeded(directory)
        let targetName = resolvedFilename(
            custom: customFilename,
            responseSuggestedFilename: responseSuggestedFilename,
            sourceURL: sourceURL
        )
        return try uniqueDestinationURL(for: targetName, in: directory)
    }

    nonisolated func moveDownloadedFile(from sourceURL: URL, to destinationURL: URL) throws {
        try createDirectoryIfNeeded(destinationURL.deletingLastPathComponent())
        guard try pathEntryExists(at: destinationURL) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
    }

    nonisolated func synchronizePlacedFile(at destinationURL: URL) throws {
        guard try pathEntryExists(at: destinationURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try DurableFileSystem.synchronizeFile(at: destinationURL)
        try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
    }

    nonisolated func copyDownloadedFile(from sourceURL: URL, to stagingURL: URL) throws {
        try createDirectoryIfNeeded(stagingURL.deletingLastPathComponent())
        guard try pathEntryExists(at: stagingURL) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        try DurableFileSystem.synchronizeFile(at: stagingURL)
        try DurableFileSystem.synchronizeParentDirectory(of: stagingURL)
    }

    private nonisolated func createDirectoryIfNeeded(_ directoryURL: URL) throws {
        let alreadyExists = try pathEntryExists(at: directoryURL)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if alreadyExists == false {
            try DurableFileSystem.synchronizeParentDirectory(of: directoryURL)
        }
    }

    private nonisolated func pathEntryExists(at url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &info)
        }
        if result == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private nonisolated func sanitize(_ filename: String) -> String {
        let replaced = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return replaced.isEmpty ? "Download" : replaced
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
