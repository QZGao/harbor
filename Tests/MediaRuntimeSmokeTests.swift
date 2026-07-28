import Darwin
import Foundation

@main
struct MediaRuntimeSmokeTests {
    static func main() async throws {
        try testMetadataParserBuildsFormatOptions()
        try testMetadataParserKeepsMeaningfulVariants()
        try testMetadataParserCombinedMP4Video()
        try testMetadataParserVideoWithoutAudio()
        try testMetadataParserRejectsExtensionOnlyFile()
        try testMetadataParserExposesAudioWithoutUnverifiedVideo()
        try testMetadataParserCollection()
        try testFormatPreferenceCoding()
        try testLegacyMetadataDecoding()
        try testProgressAndFinalPathParsers()
        try testManagedChildProcessTerminatesProcessGroup()
        print("Media runtime smoke tests passed")
    }

    private static func testMetadataParserBuildsFormatOptions() throws {
        let json = """
        {
          "id": "abc123",
          "title": "Sample Short",
          "extractor_key": "Youtube",
          "thumbnail": "https://img.example.test/thumb.jpg",
          "webpage_url": "https://www.youtube.com/shorts/abc123",
          "formats": [
            {
              "format_id": "137",
              "ext": "mp4",
              "vcodec": "avc1.640028",
              "acodec": "none",
              "has_drm": false,
              "width": 1920,
              "height": 1080,
              "fps": 30,
              "vbr": 4500,
              "filesize": 4000000
            },
            {
              "format_id": "140",
              "ext": "m4a",
              "vcodec": "none",
              "acodec": "mp4a.40.2",
              "has_drm": false,
              "abr": 128,
              "filesize": 100000
            },
            {
              "format_id": "248",
              "ext": "webm",
              "vcodec": "vp9",
              "acodec": "none",
              "has_drm": false,
              "width": 1920,
              "height": 1080,
              "fps": 30,
              "vbr": 3200,
              "filesize": 3000000
            },
            {
              "format_id": "251",
              "ext": "webm",
              "vcodec": "none",
              "acodec": "opus",
              "has_drm": false,
              "abr": 160,
              "filesize": 120000
            },
            {
              "format_id": "18",
              "ext": "mp4",
              "vcodec": "avc1.42001E",
              "acodec": "mp4a.40.2",
              "has_drm": false,
              "width": 640,
              "height": 360,
              "fps": 30,
              "tbr": 600,
              "filesize_approx": 600000
            }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://www.youtube.com/shorts/abc123")!
        )

        try assert(metadata.title == "Sample Short", "Video title should parse")
        try assert(metadata.platform == "Youtube", "Extractor key should become platform")
        try assert(metadata.mediaType == .video, "Checked video formats should classify the source as video")
        try assert(metadata.capabilities.supportsMediaFormatSelection, "Checked media formats should enable the format picker")
        try assert(metadata.supportsMediaDownload, "Checked video formats should enable yt-dlp")
        try assert(metadata.capabilities.formatOptions.count == 5, "Each meaningful checked media output should be listed")
        try assert(metadata.defaultFormatPreference == .original, "Original should be the default format")

        let mp4Pair = metadata.capabilities.formatOptions.first { $0.id == "137+140" }
        try assert(mp4Pair?.container == "mp4", "MP4 video and M4A audio should produce MP4")
        try assert(mp4Pair?.mergeOutputFormat == "mp4", "Paired MP4 streams should request an MP4 merge")
        try assert(mp4Pair?.estimatedBytes == 4_100_000, "Paired stream sizes should be combined")

        let webMPair = metadata.capabilities.formatOptions.first { $0.id == "248+251" }
        try assert(webMPair?.container == "webm", "WebM video and audio should produce WebM")
        try assert(webMPair?.mergeOutputFormat == "webm", "Paired WebM streams should request a WebM merge")

        let combined = metadata.capabilities.formatOptions.first { $0.id == "18" }
        try assert(combined?.audioFormatID == nil, "A combined format should use one exact format ID")
        try assert(combined?.mergeOutputFormat == nil, "A combined format should not request a merge")

        let audioSelectors = Set(
            metadata.capabilities.formatOptions
                .filter { $0.videoCodec == nil }
                .map(\.selector)
        )
        try assert(audioSelectors == ["140", "251"], "Checked audio-only formats should be selectable")

        let roundTrip = try JSONDecoder().decode(
            MediaDownloadMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        try assert(roundTrip == metadata, "Media format options should persist with metadata")
    }

    private static func testMetadataParserKeepsMeaningfulVariants() throws {
        let json = """
        {
          "id": "variants",
          "title": "Meaningful Variants",
          "extractor_key": "Example",
          "formats": [
            {
              "format_id": "133",
              "ext": "mp4",
              "vcodec": "avc1.4d400c",
              "acodec": "none",
              "has_drm": false,
              "width": 320,
              "height": 240,
              "fps": 15,
              "vbr": 300,
              "filesize": 430000
            },
            {
              "format_id": "134",
              "ext": "mp4",
              "vcodec": "avc1.4d400c",
              "acodec": "none",
              "has_drm": false,
              "width": 320,
              "height": 240,
              "fps": 15,
              "vbr": 200,
              "filesize": 320000
            },
            {
              "format_id": "140",
              "ext": "m4a",
              "vcodec": "none",
              "acodec": "mp4a.40.2",
              "has_drm": false,
              "abr": 128,
              "filesize": 100000
            }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://video.example.test/variants")!
        )

        let selectors = Set(
            metadata.capabilities.formatOptions
                .filter { $0.videoCodec != nil }
                .map(\.selector)
        )
        try assert(
            selectors == ["133+140", "134+140"],
            "Formats with meaningfully different bitrates and sizes should both remain available"
        )
    }

    private static func testMetadataParserCombinedMP4Video() throws {
        let json = """
        {
          "id": "combined",
          "title": "Combined MP4",
          "extractor_key": "Example",
          "format_id": "18",
          "ext": "mp4",
          "vcodec": "h264",
          "acodec": "aac",
          "has_drm": false
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://video.example.test/combined")!
        )

        try assert(metadata.capabilities.supportsMediaFormatSelection, "Combined MP4 should enable the format picker")
        try assert(metadata.capabilities.formatOptions.map(\.selector) == ["18"], "Combined MP4 should be selectable directly")
    }

    private static func testMetadataParserVideoWithoutAudio() throws {
        let json = """
        {
          "id": "silent",
          "title": "Silent Video",
          "extractor_key": "Example",
          "formats": [
            {
              "format_id": "silent-video",
              "ext": "mp4",
              "vcodec": "h264",
              "acodec": "none",
              "has_drm": false,
              "width": 1280,
              "height": 720
            }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://video.example.test/silent")!
        )

        let option = metadata.capabilities.formatOptions.first
        try assert(option?.selector == "silent-video", "A checked silent video should remain selectable")
        try assert(option?.audioCodec == nil, "A silent video option should not invent an audio stream")
        try assert(option?.mergeOutputFormat == nil, "A silent video should not request a merge")
    }

    private static func testMetadataParserRejectsExtensionOnlyFile() throws {
        let json = """
        {
          "id": "book",
          "title": "Book",
          "extractor_key": "Generic",
          "ext": "mobi"
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://files.example.test/book.mobi")!
        )

        try assert(metadata.mediaType == .unknown, "An extension alone must not classify a file as video")
        try assert(
            metadata.capabilities == .unavailable,
            "An extension-only result must remain a direct download"
        )
        try assert(metadata.supportsMediaDownload == false, "A Generic MOBI file must remain a direct download")

        let imageMetadata = try MediaDownloadMetadataParser.metadata(
            from: Data(#"{"id":"image","extractor_key":"Generic","ext":"jpg"}"#.utf8),
            sourceURL: URL(string: "https://files.example.test/image.jpg")!
        )
        try assert(imageMetadata.mediaType == .image, "A recognized image should remain media")
        try assert(imageMetadata.supportsMediaDownload, "Image media should remain on the automatic yt-dlp path")
    }

    private static func testMetadataParserExposesAudioWithoutUnverifiedVideo() throws {
        let json = """
        {
          "id": "unverified",
          "title": "Unverified Video",
          "extractor_key": "Example",
          "formats": [
            {
              "format_id": "unknown",
              "ext": "mp4",
              "vcodec": "unknown",
              "acodec": "aac",
              "has_drm": false
            },
            {
              "format_id": "drm",
              "ext": "mp4",
              "vcodec": "h264",
              "acodec": "none",
              "has_drm": "maybe"
            },
            {
              "format_id": "audio-only",
              "ext": "m4a",
              "vcodec": "none",
              "acodec": "aac",
              "has_drm": false
            }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://video.example.test/unverified")!
        )

        try assert(
            metadata.capabilities.formatOptions.map(\.selector) == ["audio-only"],
            "The checked audio format should remain while unverified video formats are excluded"
        )
        try assert(metadata.capabilities.supportsMediaFormatSelection, "Checked audio should enable the media format picker")
        try assert(
            metadata.supportsMediaDownload,
            "A successful non-Generic extractor should remain on the automatic yt-dlp path"
        )
    }

    private static func testMetadataParserCollection() throws {
        let json = """
        {
          "title": "Carousel",
          "extractor": "Instagram",
          "entries": [
            { "id": "one", "title": "One", "filesize": 1000 },
            { "id": "two", "title": "Two", "filesize_approx": 2000 }
          ]
        }
        """.data(using: .utf8)!

        let metadata = try MediaDownloadMetadataParser.metadata(
            from: json,
            sourceURL: URL(string: "https://www.instagram.com/p/example/")!
        )

        try assert(metadata.isCollection, "Multiple entries should be collection")
        try assert(metadata.entryCount == 2, "Entry count should parse")
        try assert(metadata.expectedBytes == 2000, "Collection expected bytes should use largest known entry")
        try assert(
            metadata.capabilities == .unavailable,
            "Flat collection metadata should not invent video format options"
        )
        try assert(metadata.supportsMediaDownload, "Collections should remain on the automatic yt-dlp path")
        try assert(metadata.defaultFormatPreference == .original, "Collection default format should preserve originals")
    }

    private static func testFormatPreferenceCoding() throws {
        let preference = MediaDownloadFormatPreference.specific("137+140")
        let decoded = try JSONDecoder().decode(
            MediaDownloadFormatPreference.self,
            from: JSONEncoder().encode(preference)
        )
        try assert(decoded == preference, "An exact format selection should survive persistence")

        let legacyPreference = try JSONDecoder().decode(
            MediaDownloadFormatPreference.self,
            from: Data(#""bestMP4""#.utf8)
        )
        try assert(
            legacyPreference == .original,
            "The removed Best MP4 preference should migrate to Original"
        )
    }

    private static func testLegacyMetadataDecoding() throws {
        let json = """
        {
          "title": "Legacy Video",
          "platform": "Youtube",
          "extractorKey": "Youtube",
          "thumbnailURL": null,
          "webpageURL": "https://www.youtube.com/watch?v=legacy",
          "expectedBytes": 4096,
          "mediaType": "video",
          "entryCount": 1
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(MediaDownloadMetadata.self, from: json)
        try assert(
            metadata.capabilities == .unavailable,
            "Missing legacy capabilities should decode as unavailable"
        )
    }

    private static func testProgressAndFinalPathParsers() throws {
        let progress = MediaDownloadProgressParser.progress(
            from: "harbor-progress:1024\t4096\t512.5"
        )

        try assert(progress?.bytesWritten == 1024, "Progress bytes should parse")
        try assert(progress?.expectedBytes == 4096, "Progress total should parse")
        try assert(progress?.speedBytesPerSecond == 512.5, "Progress speed should parse")

        let encodedPath = String(
            data: try JSONEncoder().encode("/tmp/Harbor Test.mp4"),
            encoding: .utf8
        )!
        let finalURL = MediaDownloadFinalPathParser.fileURL(from: "harbor-file:\(encodedPath)")
        try assert(finalURL?.path == "/tmp/Harbor Test.mp4", "JSON final file path should parse")
    }

    private static func testManagedChildProcessTerminatesProcessGroup() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("harbor-process-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let childPIDURL = temporaryDirectory.appendingPathComponent("child.pid")
        let command = "sleep 30 & echo $! > '\(childPIDURL.path)'; wait"
        let semaphore = DispatchSemaphore(value: 0)
        let terminationBox = LockedBox<ManagedChildProcessTermination?>(nil)

        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { _ in },
            onStderr: { _ in },
            onTermination: { finishedTermination in
                terminationBox.value = finishedTermination
                semaphore.signal()
            }
        )

        let childPID = try waitForChildPID(at: childPIDURL)
        process.terminate(grace: 0.2)

        let result = semaphore.wait(timeout: .now() + 4)
        try assert(result == .success, "Managed process should terminate promptly")
        try assert(terminationBox.value != nil, "Termination should be reported")

        Thread.sleep(forTimeInterval: 0.4)
        let childStillExists = kill(childPID, 0) == 0
        if childStillExists {
            _ = kill(childPID, SIGKILL)
        }
        try assert(childStillExists == false, "Child process should not survive process-group termination")
    }

    private static func waitForChildPID(at url: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        throw TestFailure("Timed out waiting for child process pid")
    }

    private static func assert(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
