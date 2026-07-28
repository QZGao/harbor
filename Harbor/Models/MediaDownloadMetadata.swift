import Foundation

enum MediaDownloadType: String, Codable, Sendable {
    case video
    case image
    case collection
    case unknown
}

enum MediaDownloadFormatPreference: Codable, Equatable, Hashable, Sendable {
    case original
    case specific(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case optionID
    }

    private enum Kind: String, Codable {
        case original
        case specific
    }

    nonisolated init(from decoder: Decoder) throws {
        if let legacyValue = try? decoder.singleValueContainer().decode(String.self) {
            switch legacyValue {
            case "original", "bestMP4":
                self = .original
                return
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown media format preference: \(legacyValue)"
                    )
                )
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .original:
            self = .original
        case .specific:
            self = .specific(try container.decode(String.self, forKey: .optionID))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        switch self {
        case .original:
            var container = encoder.singleValueContainer()
            try container.encode("original")
        case let .specific(optionID):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.specific, forKey: .kind)
            try container.encode(optionID, forKey: .optionID)
        }
    }
}

struct MediaDownloadFormatOption: Codable, Equatable, Identifiable, Sendable {
    let formatID: String
    let audioFormatID: String? // merge with video if formatID is video-only
    let container: String
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let dynamicRange: String?
    let bitrateKbps: Double?
    let estimatedBytes: Int64
    let mergeOutputFormat: String?

    // Keep the existing coding keys because format options are persisted.
    private enum CodingKeys: String, CodingKey {
        case formatID = "videoFormatID"
        case audioFormatID
        case container
        case videoCodec
        case audioCodec
        case width
        case height
        case framesPerSecond
        case dynamicRange
        case bitrateKbps
        case estimatedBytes
        case mergeOutputFormat
    }

    nonisolated var id: String {
        selector
    }

    nonisolated var selector: String {
        guard let audioFormatID else {
            return formatID
        }

        return "\(formatID)+\(audioFormatID)"
    }
}

struct MediaDownloadCapabilities: Codable, Equatable, Sendable {
    let formatOptions: [MediaDownloadFormatOption]

    nonisolated static let unavailable = MediaDownloadCapabilities(
        formatOptions: []
    )

    private enum CodingKeys: String, CodingKey {
        case formatOptions
    }

    nonisolated init(formatOptions: [MediaDownloadFormatOption]) {
        self.formatOptions = formatOptions
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatOptions = try container.decodeIfPresent(
            [MediaDownloadFormatOption].self,
            forKey: .formatOptions
        ) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatOptions, forKey: .formatOptions)
    }

    nonisolated var supportsMediaFormatSelection: Bool {
        formatOptions.isEmpty == false
    }
}

struct MediaDownloadMetadata: Codable, Equatable, Sendable {
    let title: String
    let platform: String
    let extractorKey: String?
    let thumbnailURL: URL?
    let webpageURL: URL?
    let expectedBytes: Int64
    let mediaType: MediaDownloadType
    let entryCount: Int
    let capabilities: MediaDownloadCapabilities

    private enum CodingKeys: String, CodingKey {
        case title
        case platform
        case extractorKey
        case thumbnailURL
        case webpageURL
        case expectedBytes
        case mediaType
        case entryCount
        case capabilities
    }

    nonisolated init(
        title: String,
        platform: String,
        extractorKey: String?,
        thumbnailURL: URL?,
        webpageURL: URL?,
        expectedBytes: Int64,
        mediaType: MediaDownloadType,
        entryCount: Int,
        capabilities: MediaDownloadCapabilities
    ) {
        self.title = title
        self.platform = platform
        self.extractorKey = extractorKey
        self.thumbnailURL = thumbnailURL
        self.webpageURL = webpageURL
        self.expectedBytes = expectedBytes
        self.mediaType = mediaType
        self.entryCount = entryCount
        self.capabilities = capabilities
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        platform = try container.decode(String.self, forKey: .platform)
        extractorKey = try container.decodeIfPresent(String.self, forKey: .extractorKey)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        webpageURL = try container.decodeIfPresent(URL.self, forKey: .webpageURL)
        expectedBytes = try container.decode(Int64.self, forKey: .expectedBytes)
        mediaType = try container.decode(MediaDownloadType.self, forKey: .mediaType)
        entryCount = try container.decode(Int.self, forKey: .entryCount)
        capabilities = try container.decodeIfPresent(
            MediaDownloadCapabilities.self,
            forKey: .capabilities
        ) ?? .unavailable
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(platform, forKey: .platform)
        try container.encode(extractorKey, forKey: .extractorKey)
        try container.encode(thumbnailURL, forKey: .thumbnailURL)
        try container.encode(webpageURL, forKey: .webpageURL)
        try container.encode(expectedBytes, forKey: .expectedBytes)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(entryCount, forKey: .entryCount)
        try container.encode(capabilities, forKey: .capabilities)
    }

    nonisolated var isCollection: Bool {
        entryCount > 1 || mediaType == .collection
    }

    /// Whether the source should stay on Harbor's yt-dlp download path.
    nonisolated var supportsMediaDownload: Bool {
        if capabilities.supportsMediaFormatSelection || mediaType != .unknown {
            return true
        }

        guard let extractorKey = extractorKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            extractorKey.isEmpty == false else {
            return false
        } // Normalize.

        return extractorKey.caseInsensitiveCompare("generic") != .orderedSame // "generic" denotes extractorKey not recognized by yt-dlp
    }

    nonisolated var defaultFormatPreference: MediaDownloadFormatPreference {
        .original
    }
}

enum MediaDownloadMetadataParser {
    nonisolated static func metadata(from data: Data, sourceURL: URL) throws -> MediaDownloadMetadata {
        let payload = try JSONDecoder().decode(YTDLPInfoPayload.self, from: data)
        return metadata(from: payload, sourceURL: sourceURL)
    }

    private nonisolated static func metadata(
        from payload: YTDLPInfoPayload,
        sourceURL: URL
    ) -> MediaDownloadMetadata {
        let entries = payload.entries ?? []
        let entryCount = max(entries.count, 1)
        let capabilities = capabilities(for: payload)
        let mediaType = mediaType(
            for: payload,
            entryCount: entryCount,
            capabilities: capabilities
        )
        let expectedBytes = max(payload.expectedBytes, entries.map(\.expectedBytes).max() ?? 0)
        let title = payload.bestTitle ?? sourceURL.host ?? "Media Download"

        return MediaDownloadMetadata(
            title: title,
            platform: payload.platform ?? sourceURL.host ?? "Media",
            extractorKey: payload.extractorKey,
            thumbnailURL: payload.thumbnailURL,
            webpageURL: payload.webpageURL ?? sourceURL,
            expectedBytes: expectedBytes,
            mediaType: mediaType,
            entryCount: entryCount,
            capabilities: capabilities
        )
    }

    private nonisolated static func mediaType(
        for payload: YTDLPInfoPayload,
        entryCount: Int,
        capabilities: MediaDownloadCapabilities
    ) -> MediaDownloadType {
        if entryCount > 1 {
            return .collection
        }

        if capabilities.formatOptions.contains(where: { $0.videoCodec != nil }) {
            return .video
        }

        if let ext = payload.ext?.lowercased(),
           imageExtensions.contains(ext) {
            return .image
        }

        return .unknown
    }

    private nonisolated static func capabilities(
        for payload: YTDLPInfoPayload
    ) -> MediaDownloadCapabilities {
        return MediaDownloadCapabilities(
            formatOptions: formatOptions(for: payload)
        )
    }

    private nonisolated static func formatOptions(
        for payload: YTDLPInfoPayload
    ) -> [MediaDownloadFormatOption] {
        let checkedFormats = payload.availableFormats.filter(\.isConfirmedDRMFree)
        let audioFormats = checkedFormats.filter { format in
            format.hasNoVideo && format.hasAudio && format.normalizedFormatID != nil
        }
        let options = checkedFormats.compactMap { format -> MediaDownloadFormatOption? in
            guard let formatID = format.normalizedFormatID,
                  let container = format.normalizedExtension else {
                return nil
            }

            if format.hasVideo {
                guard let videoCodec = format.normalizedVideoCodec else {
                    return nil
                }

                if format.hasAudio {
                    return MediaDownloadFormatOption(
                        formatID: formatID,
                        audioFormatID: nil,
                        container: container,
                        videoCodec: videoCodec,
                        audioCodec: format.normalizedAudioCodec,
                        width: format.width,
                        height: format.height,
                        framesPerSecond: format.framesPerSecond,
                        dynamicRange: format.normalizedDynamicRange,
                        bitrateKbps: format.totalBitrateKbps,
                        estimatedBytes: format.expectedBytes,
                        mergeOutputFormat: nil
                    )
                }

                guard format.hasNoAudio else {
                    return nil
                }

                let audioFormat = bestAudioFormat(
                    forVideoContainer: container,
                    from: audioFormats
                )
                let audioFormatID = audioFormat?.normalizedFormatID
                let outputContainer = outputContainer(
                    videoContainer: container,
                    audioContainer: audioFormat?.normalizedExtension
                )

                return MediaDownloadFormatOption(
                    formatID: formatID,
                    audioFormatID: audioFormatID,
                    container: outputContainer,
                    videoCodec: videoCodec,
                    audioCodec: audioFormat?.normalizedAudioCodec,
                    width: format.width,
                    height: format.height,
                    framesPerSecond: format.framesPerSecond,
                    dynamicRange: format.normalizedDynamicRange,
                    bitrateKbps: combinedBitrate(video: format, audio: audioFormat),
                    estimatedBytes: combinedSize(video: format, audio: audioFormat),
                    mergeOutputFormat: audioFormat == nil ? nil : outputContainer
                )
            }

            guard format.hasNoVideo,
                  format.hasAudio,
                  let audioCodec = format.normalizedAudioCodec else {
                return nil
            }

            return MediaDownloadFormatOption(
                formatID: formatID,
                audioFormatID: nil,
                container: container,
                videoCodec: nil,
                audioCodec: audioCodec,
                width: nil,
                height: nil,
                framesPerSecond: nil,
                dynamicRange: nil,
                bitrateKbps: format.totalBitrateKbps,
                estimatedBytes: format.expectedBytes,
                mergeOutputFormat: nil
            )
        }

        var uniqueOptions: [FormatOptionIdentity: MediaDownloadFormatOption] = [:]
        for option in options {
            uniqueOptions[FormatOptionIdentity(option)] = option
        }

        return uniqueOptions.values.sorted(by: formatOptionComesFirst)
    }

    private nonisolated static func bestAudioFormat(
        forVideoContainer videoContainer: String,
        from audioFormats: [YTDLPFormatPayload]
    ) -> YTDLPFormatPayload? {
        let preferredExtensions: Set<String>
        switch videoContainer {
        case "mp4", "m4v", "mov":
            preferredExtensions = ["m4a", "mp4"]
        case "webm":
            preferredExtensions = ["webm"]
        default:
            preferredExtensions = [videoContainer]
        }

        let compatibleFormats = audioFormats.filter { format in
            guard let audioContainer = format.normalizedExtension else {
                return false
            }

            return preferredExtensions.contains(audioContainer)
        }
        let candidates = compatibleFormats.isEmpty ? audioFormats : compatibleFormats

        return candidates.max { lhs, rhs in
            if lhs.audioQualityKbps != rhs.audioQualityKbps {
                return lhs.audioQualityKbps < rhs.audioQualityKbps
            }

            return lhs.expectedBytes < rhs.expectedBytes
        }
    }

    private nonisolated static func outputContainer(
        videoContainer: String,
        audioContainer: String?
    ) -> String {
        guard let audioContainer else {
            return videoContainer
        }

        if ["mp4", "m4v", "mov"].contains(videoContainer),
           ["m4a", "mp4"].contains(audioContainer) {
            return "mp4"
        }

        if videoContainer == "webm", audioContainer == "webm" {
            return "webm"
        }

        return "mkv"
    }

    private nonisolated static func combinedBitrate(
        video: YTDLPFormatPayload,
        audio: YTDLPFormatPayload?
    ) -> Double? {
        guard let audio else {
            return video.totalBitrateKbps
        }

        let videoBitrate = video.videoQualityKbps
        let audioBitrate = audio.audioQualityKbps
        guard videoBitrate > 0 || audioBitrate > 0 else {
            return nil
        }

        return videoBitrate + audioBitrate
    }

    private nonisolated static func combinedSize(
        video: YTDLPFormatPayload,
        audio: YTDLPFormatPayload?
    ) -> Int64 {
        guard let audio else {
            return video.expectedBytes
        }

        guard video.expectedBytes > 0, audio.expectedBytes > 0 else {
            return 0
        }

        let (combinedBytes, overflowed) = video.expectedBytes.addingReportingOverflow(
            audio.expectedBytes
        )
        return overflowed ? 0 : combinedBytes
    }

    private nonisolated static func formatOptionComesFirst(
        _ lhs: MediaDownloadFormatOption,
        _ rhs: MediaDownloadFormatOption
    ) -> Bool {
        if lhs.height != rhs.height {
            return (lhs.height ?? -1) > (rhs.height ?? -1)
        }

        if lhs.width != rhs.width {
            return (lhs.width ?? -1) > (rhs.width ?? -1)
        }

        if lhs.framesPerSecond != rhs.framesPerSecond {
            return (lhs.framesPerSecond ?? -1) > (rhs.framesPerSecond ?? -1)
        }

        if lhs.container != rhs.container {
            return lhs.container < rhs.container
        }

        if lhs.bitrateKbps != rhs.bitrateKbps {
            return (lhs.bitrateKbps ?? -1) > (rhs.bitrateKbps ?? -1)
        }

        return lhs.selector < rhs.selector
    }

    private nonisolated struct FormatOptionIdentity: Hashable {
        let container: String
        let videoCodec: String?
        let audioCodec: String?
        let width: Int?
        let height: Int?
        let framesPerSecond: Double?
        let dynamicRange: String?
        let bitrateTenths: Int?
        let estimatedBytes: Int64

        nonisolated init(_ option: MediaDownloadFormatOption) {
            container = option.container
            videoCodec = option.videoCodec?.lowercased()
            audioCodec = option.audioCodec?.lowercased()
            width = option.width
            height = option.height
            framesPerSecond = option.framesPerSecond
            dynamicRange = option.dynamicRange?.lowercased()
            if let bitrateKbps = option.bitrateKbps,
               bitrateKbps.isFinite,
               bitrateKbps <= Double(Int.max) / 10 {
                bitrateTenths = Int((bitrateKbps * 10).rounded())
            } else {
                bitrateTenths = nil
            }
            estimatedBytes = option.estimatedBytes
        }
    }

    private nonisolated static let imageExtensions: Set<String> = [
        "avif",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "png",
        "webp"
    ]
}

private nonisolated struct YTDLPInfoPayload: Decodable {
    let id: String?
    let title: String?
    let fulltitle: String?
    let extractor: String?
    let extractorKey: String?
    let webpageURL: URL?
    let originalURL: URL?
    let thumbnailURL: URL?
    let formatID: String?
    let ext: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formats: [YTDLPFormatPayload]?
    let requestedFormats: [YTDLPFormatPayload]?
    let vcodec: String?
    let acodec: String?
    let hasDRM: YTDLPDRMStatus?
    let entries: [YTDLPInfoEntryPayload]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case fulltitle
        case extractor
        case extractorKey = "extractor_key"
        case webpageURL = "webpage_url"
        case originalURL = "original_url"
        case thumbnailURL = "thumbnail"
        case formatID = "format_id"
        case ext
        case filesize
        case filesizeApprox = "filesize_approx"
        case formats
        case requestedFormats = "requested_formats"
        case vcodec
        case acodec
        case hasDRM = "has_drm"
        case entries
    }

    nonisolated var bestTitle: String? {
        fulltitle?.nilIfBlank ?? title?.nilIfBlank ?? id?.nilIfBlank
    }

    nonisolated var platform: String? {
        extractorKey?.nilIfBlank ?? extractor?.nilIfBlank
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? formats?.compactMap(\.expectedBytes).max() ?? 0
    }

    nonisolated var selectedFormats: [YTDLPFormatPayload] {
        if let requestedFormats, requestedFormats.isEmpty == false {
            return requestedFormats
        }

        guard ext != nil || vcodec != nil || acodec != nil || hasDRM != nil else {
            return []
        }

        return [
            YTDLPFormatPayload(
                formatID: formatID,
                ext: ext,
                vcodec: vcodec,
                acodec: acodec,
                hasDRM: hasDRM,
                filesize: filesize,
                filesizeApprox: filesizeApprox,
                width: nil,
                height: nil,
                framesPerSecond: nil,
                dynamicRange: nil,
                totalBitrate: nil,
                videoBitrate: nil,
                audioBitrate: nil
            )
        ]
    }

    nonisolated var availableFormats: [YTDLPFormatPayload] {
        if let formats, formats.isEmpty == false {
            return formats
        }

        return selectedFormats
    }
}

private nonisolated struct YTDLPInfoEntryPayload: Decodable {
    let id: String?
    let title: String?
    let filesize: Int64?
    let filesizeApprox: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case filesize
        case filesizeApprox = "filesize_approx"
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? 0
    }
}

private nonisolated struct YTDLPFormatPayload: Decodable {
    let formatID: String?
    let ext: String?
    let vcodec: String?
    let acodec: String?
    let hasDRM: YTDLPDRMStatus?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let dynamicRange: String?
    let totalBitrate: Double?
    let videoBitrate: Double?
    let audioBitrate: Double?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext
        case vcodec
        case acodec
        case hasDRM = "has_drm"
        case filesize
        case filesizeApprox = "filesize_approx"
        case width
        case height
        case framesPerSecond = "fps"
        case dynamicRange = "dynamic_range"
        case totalBitrate = "tbr"
        case videoBitrate = "vbr"
        case audioBitrate = "abr"
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? 0
    }

    nonisolated var normalizedExtension: String? {
        ext?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated var normalizedFormatID: String? {
        formatID?.nilIfBlank
    }

    nonisolated var normalizedVideoCodec: String? {
        hasVideo ? vcodec?.nilIfBlank : nil
    }

    nonisolated var normalizedAudioCodec: String? {
        hasAudio ? acodec?.nilIfBlank : nil
    }

    nonisolated var normalizedDynamicRange: String? {
        dynamicRange?.nilIfBlank
    }

    nonisolated var totalBitrateKbps: Double? {
        if let totalBitrate, totalBitrate > 0 {
            return totalBitrate
        }

        let componentTotal = videoQualityKbps + audioQualityKbps
        return componentTotal > 0 ? componentTotal : nil
    }

    nonisolated var videoQualityKbps: Double {
        if let videoBitrate, videoBitrate > 0 {
            return videoBitrate
        }

        return hasVideo ? max(totalBitrate ?? 0, 0) : 0
    }

    nonisolated var audioQualityKbps: Double {
        if let audioBitrate, audioBitrate > 0 {
            return audioBitrate
        }

        return hasAudio ? max(totalBitrate ?? 0, 0) : 0
    }

    nonisolated var hasVideo: Bool {
        vcodec.isKnownCodec
    }

    nonisolated var hasAudio: Bool {
        acodec.isKnownCodec
    }

    nonisolated var hasNoVideo: Bool {
        vcodec.isAbsentCodec
    }

    nonisolated var hasNoAudio: Bool {
        acodec.isAbsentCodec
    }

    nonisolated var isConfirmedDRMFree: Bool {
        hasDRM?.isConfirmedFalse ?? true
    }
}

private nonisolated struct YTDLPDRMStatus: Decodable {
    let isConfirmedFalse: Bool

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Bool.self) {
            isConfirmedFalse = value == false
            return
        }

        if let value = try? container.decode(String.self) {
            isConfirmedFalse = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("false") == .orderedSame
            return
        }

        isConfirmedFalse = false
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private extension Optional where Wrapped == String {
    nonisolated var isKnownCodec: Bool {
        guard let normalizedCodec = self?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            normalizedCodec.isEmpty == false else {
            return false
        }

        return normalizedCodec != "none" && normalizedCodec != "unknown"
    }

    nonisolated var isAbsentCodec: Bool {
        self?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("none") == .orderedSame
    }
}
