import XCTest
@testable import Harbor

final class MediaRuntimeTests: XCTestCase {
    func testMetadataParserBuildsSelectableFormatCatalog() throws {
        let metadata = try parseMetadata(
            #"""
            {
              "id": "abc123", "title": "Sample Short", "extractor_key": "Youtube",
              "formats": [
                {"format_id":"137","ext":"mp4","vcodec":"avc1.640028","acodec":"none","has_drm":false,"width":1920,"height":1080,"fps":30,"vbr":4500,"filesize":4000000},
                {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","has_drm":false,"abr":128,"filesize":100000,"language":"en","format_note":"English (Original)","audio_channels":2,"language_preference":10},
                {"format_id":"140-fr","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","has_drm":false,"abr":192,"filesize":150000,"language":"fr","format_note":"French Dub","audio_channels":2,"language_preference":0},
                {"format_id":"248","ext":"webm","vcodec":"vp9","acodec":"none","has_drm":false,"width":1920,"height":1080,"fps":30,"vbr":3200,"filesize":3000000},
                {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","has_drm":false,"abr":160,"filesize":120000,"language":"en","format_note":"English (Original)","audio_channels":2,"language_preference":20},
                {"format_id":"18","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2","has_drm":false,"width":640,"height":360,"fps":30,"tbr":600,"filesize_approx":600000}
              ]
            }
            """#
        )

        XCTAssertEqual(metadata.title, "Sample Short")
        XCTAssertEqual(metadata.platform, "Youtube")
        XCTAssertEqual(metadata.mediaType, .video)
        XCTAssertTrue(metadata.capabilities.supportsMediaFormatSelection)
        XCTAssertTrue(metadata.supportsMediaDownload)
        XCTAssertEqual(metadata.capabilities.formatOptions.count, 6)
        XCTAssertEqual(metadata.defaultFormatPreference, .bestAvailable)

        let mp4Video = try XCTUnwrap(metadata.capabilities.formatOption(id: "137"))
        let webMVideo = try XCTUnwrap(metadata.capabilities.formatOption(id: "248"))
        let defaultMP4Selection = metadata.capabilities.defaultSelection(for: mp4Video)
        XCTAssertEqual(defaultMP4Selection.selector, "137+251")
        XCTAssertEqual(defaultMP4Selection.mergeOutputFormat, "mkv")
        XCTAssertEqual(defaultMP4Selection.estimatedBytes, 4_120_000)

        let frenchSelection = metadata.capabilities.selection(
            for: mp4Video,
            audioFormatID: "140-fr"
        )
        XCTAssertEqual(frenchSelection?.selector, "137+140-fr")
        XCTAssertEqual(frenchSelection?.mergeOutputFormat, "mp4")
        XCTAssertEqual(
            metadata.capabilities.selection(for: mp4Video, audioFormatID: nil)?.selector,
            "137"
        )

        let webMSelection = metadata.capabilities.defaultSelection(for: webMVideo)
        XCTAssertEqual(webMSelection.selector, "248+251")
        XCTAssertEqual(webMSelection.mergeOutputFormat, "webm")

        let combined = try XCTUnwrap(metadata.capabilities.formatOption(id: "18"))
        let combinedSelection = MediaDownloadFormatSelection(format: combined)
        XCTAssertNil(combinedSelection.audioFormatID)
        XCTAssertNil(combinedSelection.mergeOutputFormat)
        XCTAssertEqual(
            Set(metadata.capabilities.audioFormatOptions.map(\.formatID)),
            Set(["140", "140-fr", "251"])
        )

        let roundTrip = try JSONDecoder().decode(
            MediaDownloadMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        XCTAssertEqual(roundTrip, metadata)
    }

    func testMetadataParserKeepsMeaningfulVariants() throws {
        let metadata = try parseMetadata(
            #"""
            {
              "id":"variants","title":"Meaningful Variants","extractor_key":"Example",
              "formats":[
                {"format_id":"133","ext":"mp4","vcodec":"avc1.4d400c","acodec":"none","has_drm":false,"width":320,"height":240,"fps":15,"vbr":300,"filesize":430000},
                {"format_id":"134","ext":"mp4","vcodec":"avc1.4d400c","acodec":"none","has_drm":false,"width":320,"height":240,"fps":15,"vbr":200,"filesize":320000},
                {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","has_drm":false,"abr":128,"filesize":100000}
              ]
            }
            """#
        )

        XCTAssertEqual(
            Set(metadata.capabilities.formatOptions.filter { $0.hasVideo }.map(\.formatID)),
            Set(["133", "134"])
        )
        let firstVideo = try XCTUnwrap(metadata.capabilities.formatOption(id: "133"))
        XCTAssertEqual(
            metadata.capabilities.defaultSelection(for: firstVideo).selector,
            "133+140"
        )
    }

    func testMetadataParserClassifiesEdgeCases() throws {
        let combined = try parseMetadata(
            #"{"id":"combined","title":"Combined MP4","extractor_key":"Example","format_id":"18","ext":"mp4","vcodec":"h264","acodec":"aac","has_drm":false}"#
        )
        XCTAssertTrue(combined.capabilities.supportsMediaFormatSelection)
        XCTAssertEqual(combined.capabilities.formatOptions.map(\.formatID), ["18"])

        let silent = try parseMetadata(
            #"{"id":"silent","title":"Silent Video","extractor_key":"Example","formats":[{"format_id":"silent-video","ext":"mp4","vcodec":"h264","acodec":"none","has_drm":false,"width":1280,"height":720}]}"#
        )
        let silentOption = try XCTUnwrap(silent.capabilities.formatOptions.first)
        XCTAssertEqual(silentOption.formatID, "silent-video")
        XCTAssertNil(silentOption.audioCodec)
        XCTAssertNil(MediaDownloadFormatSelection(format: silentOption).mergeOutputFormat)

        let genericFile = try parseMetadata(
            #"{"id":"book","title":"Book","extractor_key":"Generic","ext":"mobi"}"#
        )
        XCTAssertEqual(genericFile.mediaType, .unknown)
        XCTAssertEqual(genericFile.capabilities, .unavailable)
        XCTAssertFalse(genericFile.supportsMediaDownload)

        let image = try parseMetadata(
            #"{"id":"image","extractor_key":"Generic","ext":"jpg"}"#
        )
        XCTAssertEqual(image.mediaType, .image)
        XCTAssertTrue(image.supportsMediaDownload)

        let checkedAudio = try parseMetadata(
            #"""
            {"id":"unverified","title":"Unverified Video","extractor_key":"Example","formats":[
              {"format_id":"unknown","ext":"mp4","vcodec":"unknown","acodec":"aac","has_drm":false},
              {"format_id":"drm","ext":"mp4","vcodec":"h264","acodec":"none","has_drm":"maybe"},
              {"format_id":"audio-only","ext":"m4a","vcodec":"none","acodec":"aac","has_drm":false}
            ]}
            """#
        )
        XCTAssertEqual(checkedAudio.capabilities.formatOptions.map(\.formatID), ["audio-only"])
        XCTAssertTrue(checkedAudio.capabilities.supportsMediaFormatSelection)
        XCTAssertTrue(checkedAudio.supportsMediaDownload)

        let collection = try parseMetadata(
            #"{"title":"Carousel","extractor":"Instagram","entries":[{"id":"one","title":"One","filesize":1000},{"id":"two","title":"Two","filesize_approx":2000}]}"#
        )
        XCTAssertTrue(collection.isCollection)
        XCTAssertEqual(collection.entryCount, 2)
        XCTAssertEqual(collection.expectedBytes, 2_000)
        XCTAssertEqual(collection.capabilities, .unavailable)
        XCTAssertTrue(collection.supportsMediaDownload)
        XCTAssertEqual(collection.defaultFormatPreference, .bestAvailable)
    }

    func testFormatPreferenceCodingAndLegacyMigration() throws {
        let fixture = makeMediaFormatTestFixture()
        let preference = MediaDownloadFormatPreference.specific(fixture.selection)
        let decoded = try JSONDecoder().decode(
            MediaDownloadFormatPreference.self,
            from: JSONEncoder().encode(preference)
        )
        XCTAssertEqual(decoded, preference)
        guard case let .specific(decodedSelection) = decoded else {
            return XCTFail("Expected a specific format selection")
        }
        XCTAssertEqual(decodedSelection.formatID, "137")
        XCTAssertEqual(decodedSelection.audioFormatID, "140")
        XCTAssertEqual(decodedSelection.selector, "137+140")
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(MediaDownloadFormatPreference.bestAvailable), as: UTF8.self),
            #""bestAvailable""#
        )

        for legacyValue in [#""original""#, #""bestMP4""#] {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    MediaDownloadFormatPreference.self,
                    from: Data(legacyValue.utf8)
                ),
                .bestAvailable
            )
        }

        let legacySpecific = try JSONDecoder().decode(
            MediaDownloadFormatPreference.self,
            from: Data(#"{"kind":"specific","optionID":"137+140"}"#.utf8)
        )
        guard case let .specific(legacySelection) = legacySpecific else {
            return XCTFail("Expected the legacy selector to remain specific")
        }
        XCTAssertEqual(legacySelection.selector, "137+140")
        XCTAssertTrue(legacySelection.requiresFormatProbe)

        let compactPreference = try JSONDecoder().decode(
            MediaDownloadFormatPreference.self,
            from: Data(
                #"{"kind":"specific","selection":{"selector":"137+140","mergeOutputFormat":"mp4","displaySummary":"1080p • MP4 • AVC1","estimatedBytes":10000000}}"#.utf8
            )
        )
        guard case let .specific(compactSelection) = compactPreference else {
            return XCTFail("Expected the compact selector to remain specific")
        }
        XCTAssertTrue(compactSelection.requiresFormatProbe)
        let upgraded = fixture.metadata.capabilities.resolvedSelection(matching: compactSelection)
        XCTAssertEqual(upgraded?.formatID, "137")
        XCTAssertEqual(upgraded?.audioFormatID, "140")

        let legacyMetadata = try JSONDecoder().decode(
            MediaDownloadMetadata.self,
            from: Data(
                #"{"title":"Legacy Video","platform":"Youtube","extractorKey":"Youtube","thumbnailURL":null,"webpageURL":"https://www.youtube.com/watch?v=legacy","expectedBytes":4096,"mediaType":"video","entryCount":1}"#.utf8
            )
        )
        XCTAssertEqual(legacyMetadata.capabilities, .unavailable)
    }

    func testProgressAndFinalPathParsers() throws {
        let progress = try XCTUnwrap(
            MediaDownloadProgressParser.progress(from: "harbor-progress:1024\t4096\t512.5")
        )
        XCTAssertEqual(progress.bytesWritten, 1_024)
        XCTAssertEqual(progress.expectedBytes, 4_096)
        XCTAssertEqual(progress.speedBytesPerSecond, 512.5)

        let encodedPath = try XCTUnwrap(
            String(data: JSONEncoder().encode("/tmp/Harbor Test.mp4"), encoding: .utf8)
        )
        XCTAssertEqual(
            MediaDownloadFinalPathParser.fileURL(from: "harbor-file:\(encodedPath)")?.path,
            "/tmp/Harbor Test.mp4"
        )
    }

    private func parseMetadata(
        _ json: String,
        sourceURL: URL = URL(string: "https://video.example.test/item")!
    ) throws -> MediaDownloadMetadata {
        try MediaDownloadMetadataParser.metadata(from: Data(json.utf8), sourceURL: sourceURL)
    }
}
