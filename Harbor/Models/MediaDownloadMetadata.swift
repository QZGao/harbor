import Foundation

enum MediaDownloadType: String, Codable, Sendable {
    case video
    case image
    case collection
    case unknown
}

enum MediaDownloadFormatPreference: Codable, Equatable, Hashable, Sendable {
    case bestAvailable
    case specific(MediaDownloadFormatSelection)

    private enum CodingKeys: String, CodingKey {
        case kind
        case optionID
        case selection
    }

    private enum Kind: String, Codable {
        case bestAvailable
        case original
        case specific
    }

    nonisolated init(from decoder: Decoder) throws {
        if let legacyValue = try? decoder.singleValueContainer().decode(String.self) {
            switch legacyValue {
            case "bestAvailable", "original", "bestMP4":
                self = .bestAvailable
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
        case .bestAvailable, .original:
            self = .bestAvailable
        case .specific:
            if let selection = try container.decodeIfPresent(
                MediaDownloadFormatSelection.self,
                forKey: .selection
            ) {
                self = .specific(selection)
            } else {
                self = .specific(
                    MediaDownloadFormatSelection(
                        legacySelector: try container.decode(String.self, forKey: .optionID)
                    )
                )
            }
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        switch self {
        case .bestAvailable:
            var container = encoder.singleValueContainer()
            try container.encode("bestAvailable")
        case let .specific(selection):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.specific, forKey: .kind)
            try container.encode(selection, forKey: .selection)
        }
    }

    nonisolated func initialExpectedBytes(metadataEstimate: Int64) -> Int64 {
        switch self {
        case .bestAvailable:
            metadataEstimate
        case let .specific(selection):
            selection.estimatedBytes
        }
    }

    nonisolated var selection: MediaDownloadFormatSelection? {
        guard case let .specific(selection) = self else {
            return nil
        }
        return selection
    }
}

struct MediaDownloadFormatOption: Codable, Equatable, Identifiable, Sendable {
    let formatID: String
    let container: String
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let dynamicRange: String?
    let bitrateKbps: Double?
    let estimatedBytes: Int64
    let language: String?
    let formatNote: String?
    let audioChannels: Int?
    let languagePreference: Int?
    let selectionPreference: Double?

    // Retain the existing keys so records written before catalogs became transient still decode.
    private enum CodingKeys: String, CodingKey {
        case formatID = "videoFormatID"
        case container
        case videoCodec
        case audioCodec
        case width
        case height
        case framesPerSecond
        case dynamicRange
        case bitrateKbps
        case estimatedBytes
        case language
        case formatNote
        case audioChannels
        case languagePreference
        case selectionPreference
    }

    nonisolated init(
        formatID: String,
        container: String,
        videoCodec: String?,
        audioCodec: String?,
        width: Int?,
        height: Int?,
        framesPerSecond: Double?,
        dynamicRange: String?,
        bitrateKbps: Double?,
        estimatedBytes: Int64,
        language: String? = nil,
        formatNote: String? = nil,
        audioChannels: Int? = nil,
        languagePreference: Int? = nil,
        selectionPreference: Double? = nil
    ) {
        self.formatID = formatID
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.dynamicRange = dynamicRange
        self.bitrateKbps = bitrateKbps
        self.estimatedBytes = estimatedBytes
        self.language = language
        self.formatNote = formatNote
        self.audioChannels = audioChannels
        self.languagePreference = languagePreference
        self.selectionPreference = selectionPreference
    }

    nonisolated var id: String {
        formatID
    }

    nonisolated var hasVideo: Bool {
        videoCodec != nil
    }

    nonisolated var hasAudio: Bool {
        audioCodec != nil
    }

    nonisolated var isVideoOnly: Bool {
        hasVideo && hasAudio == false
    }

    nonisolated var isAudioOnly: Bool {
        hasVideo == false && hasAudio
    }

    var formatTitle: String {
        "\(mediaKindTitle) \(container.uppercased())"
    }

    var formatDetails: String {
        var details: [String] = []

        if hasAudio, let language = language?.nilIfBlank {
            details.append(language.uppercased())
        }
        if hasAudio, let formatNote = formatNote?.nilIfBlank {
            details.append(formatNote)
        }
        if let videoCodec {
            details.append(Self.codecTitle(videoCodec))
        }
        if let audioCodec {
            details.append(Self.codecTitle(audioCodec))
        } else if videoCodec != nil {
            details.append(
                String(
                    localized: "media.format.separateAudio",
                    defaultValue: "Separate audio",
                    comment: "Media format detail shown when a video stream requires a separate audio selection."
                )
            )
        }
        if let channelTitle {
            details.append(channelTitle)
        }
        if let framesPerSecond, framesPerSecond > 0 {
            details.append(
                "\(framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))) fps"
            )
        }
        if let dynamicRange,
           dynamicRange.caseInsensitiveCompare("SDR") != .orderedSame {
            details.append(dynamicRange)
        }
        if let formattedBitrate {
            details.append(formattedBitrate)
        }
        if estimatedBytes > 0 {
            details.append(DownloadFormatting.byteString(estimatedBytes))
        }
        return details.joined(separator: " • ")
    }

    var compactFormatTitle: String {
        [selectionSummary, formattedBitrate]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var audioFormatTitle: String {
        var components = [String]()
        if let language = language?.nilIfBlank {
            components.append(language.uppercased())
        }
        if let formatNote = formatNote?.nilIfBlank {
            components.append(formatNote)
        }
        components.append(container.uppercased())
        if let audioCodec {
            components.append(Self.codecTitle(audioCodec))
        }
        if let formattedBitrate {
            components.append(formattedBitrate)
        }
        if let channelTitle {
            components.append(channelTitle)
        }
        return components.joined(separator: " • ")
    }

    fileprivate nonisolated var selectionSummary: String {
        var components: [String] = []
        if let height {
            components.append("\(height)p")
        } else if let width {
            components.append("\(width) px")
        } else if videoCodec != nil {
            components.append("Video")
        } else if audioCodec != nil {
            components.append("Audio")
        } else {
            components.append("Media")
        }
        components.append(container.uppercased())
        if hasAudio, let language = language?.nilIfBlank {
            components.append(language.uppercased())
        }
        if hasAudio, let formatNote = formatNote?.nilIfBlank {
            components.append(formatNote)
        }
        if let codec = videoCodec ?? audioCodec,
           let codecFamily = codec.split(separator: ".").first {
            components.append(codecFamily.uppercased())
        }
        return components.joined(separator: " • ")
    }

    fileprivate nonisolated var audioSelectionSummary: String {
        formatNote?.nilIfBlank
            ?? language?.nilIfBlank?.uppercased()
            ?? audioCodec?.split(separator: ".").first.map { String($0).uppercased() }
            ?? container.uppercased()
    }

    private var mediaKindTitle: String {
        if let height {
            return "\(height)p"
        }
        if let width {
            return "\(width) px"
        }
        if videoCodec != nil {
            return String(
                localized: "media.format.video",
                defaultValue: "Video",
                comment: "Fallback label for a video format whose dimensions are unknown."
            )
        }
        if audioCodec != nil {
            return String(
                localized: "media.format.audio",
                defaultValue: "Audio",
                comment: "Label for an audio-only media format."
            )
        }
        return String(
            localized: "media.format.media",
            defaultValue: "Media",
            comment: "Fallback label for a media format whose type is unknown."
        )
    }

    private var formattedBitrate: String? {
        guard let bitrateKbps, bitrateKbps.isFinite, bitrateKbps > 0 else {
            return nil
        }
        return "\(bitrateKbps.formatted(.number.precision(.fractionLength(0)))) kbps"
    }

    private var channelTitle: String? {
        guard let audioChannels, audioChannels > 0 else {
            return nil
        }
        switch audioChannels {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        default:
            return "\(audioChannels) channels"
        }
    }

    private nonisolated static func codecTitle(_ codec: String) -> String {
        let normalizedCodec = codec.lowercased()
        let families: [(prefixes: [String], title: String)] = [
            (["avc1", "h264"], "H.264"),
            (["hev1", "hvc1", "hevc"], "HEVC"),
            (["av01", "av1"], "AV1"),
            (["vp9"], "VP9"),
            (["vp8"], "VP8"),
            (["mp4a", "aac"], "AAC"),
            (["opus"], "Opus"),
            (["vorbis"], "Vorbis")
        ]
        return families.first { family in
            family.prefixes.contains { normalizedCodec.hasPrefix($0) }
        }?.title ?? codec.uppercased()
    }
}

struct MediaDownloadFormatSelection: Codable, Equatable, Hashable, Sendable {
    let selector: String
    let formatID: String?
    let audioFormatID: String?
    let mergeOutputFormat: String?
    let displaySummary: String?
    let estimatedBytes: Int64

    nonisolated init(
        format: MediaDownloadFormatOption,
        audioFormat: MediaDownloadFormatOption? = nil
    ) {
        let selectedAudioFormat = format.isVideoOnly && audioFormat?.isAudioOnly == true
            ? audioFormat
            : nil

        formatID = format.formatID
        audioFormatID = selectedAudioFormat?.formatID
        selector = selectedAudioFormat.map { "\(format.formatID)+\($0.formatID)" }
            ?? format.formatID
        mergeOutputFormat = selectedAudioFormat.map {
            Self.outputContainer(
                videoContainer: format.container,
                audioContainer: $0.container
            )
        }
        displaySummary = selectedAudioFormat.map {
            "\(format.selectionSummary) + \($0.audioSelectionSummary)"
        } ?? format.selectionSummary
        estimatedBytes = Self.combinedSize(
            format: format,
            audioFormat: selectedAudioFormat
        )
    }

    nonisolated init(legacySelector: String) {
        selector = legacySelector
        formatID = nil
        audioFormatID = nil
        mergeOutputFormat = nil
        displaySummary = nil
        estimatedBytes = 0
    }

    nonisolated var requiresFormatProbe: Bool {
        formatID == nil
    }

    nonisolated var primaryFormatID: String {
        formatID ?? selector
    }

    private nonisolated static func outputContainer(
        videoContainer: String,
        audioContainer: String
    ) -> String {
        if ["mp4", "m4v", "mov"].contains(videoContainer),
           ["m4a", "mp4"].contains(audioContainer) {
            return "mp4"
        }

        if videoContainer == "webm", audioContainer == "webm" {
            return "webm"
        }

        return "mkv"
    }

    private nonisolated static func combinedSize(
        format: MediaDownloadFormatOption,
        audioFormat: MediaDownloadFormatOption?
    ) -> Int64 {
        guard let audioFormat else {
            return format.estimatedBytes
        }

        guard format.estimatedBytes > 0, audioFormat.estimatedBytes > 0 else {
            return 0
        }

        let (combinedBytes, overflowed) = format.estimatedBytes.addingReportingOverflow(
            audioFormat.estimatedBytes
        )
        return overflowed ? 0 : combinedBytes
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

    nonisolated var supportsMediaFormatSelection: Bool {
        formatOptions.isEmpty == false
    }

    nonisolated var audioFormatOptions: [MediaDownloadFormatOption] {
        formatOptions.filter(\.isAudioOnly)
    }

    nonisolated func formatOption(id: String) -> MediaDownloadFormatOption? {
        formatOptions.first { $0.id == id }
    }

    nonisolated func defaultSelection(
        for format: MediaDownloadFormatOption
    ) -> MediaDownloadFormatSelection {
        MediaDownloadFormatSelection(
            format: format,
            audioFormat: format.isVideoOnly ? preferredAudioFormat(for: format) : nil
        )
    }

    nonisolated func selection(
        for format: MediaDownloadFormatOption,
        audioFormatID: String?
    ) -> MediaDownloadFormatSelection? {
        guard formatOptions.contains(where: { $0.id == format.id }) else {
            return nil
        }

        guard format.isVideoOnly else {
            return MediaDownloadFormatSelection(format: format)
        }

        guard let audioFormatID else {
            return MediaDownloadFormatSelection(format: format)
        }

        guard let audioFormat = audioFormatOptions.first(where: {
            $0.id == audioFormatID
        }) else {
            return nil
        }

        return MediaDownloadFormatSelection(
            format: format,
            audioFormat: audioFormat
        )
    }

    nonisolated func resolvedSelection(
        matching selection: MediaDownloadFormatSelection
    ) -> MediaDownloadFormatSelection? {
        if let formatID = selection.formatID,
           let format = formatOption(id: formatID) {
            return self.selection(
                for: format,
                audioFormatID: selection.audioFormatID
            )
        }

        if let format = formatOption(id: selection.selector) {
            return MediaDownloadFormatSelection(format: format)
        }

        for videoFormat in formatOptions where videoFormat.isVideoOnly {
            for audioFormat in audioFormatOptions
            where "\(videoFormat.id)+\(audioFormat.id)" == selection.selector {
                return MediaDownloadFormatSelection(
                    format: videoFormat,
                    audioFormat: audioFormat
                )
            }
        }

        return nil
    }

    nonisolated func selectedFormat(
        in preference: MediaDownloadFormatPreference?
    ) -> MediaDownloadFormatOption? {
        guard let formatID = preference?.selection?.formatID else {
            return nil
        }
        return formatOption(id: formatID)
    }

    nonisolated func preference(
        selectingPrimaryFormatID formatID: String?
    ) -> MediaDownloadFormatPreference? {
        guard let formatID else {
            return .bestAvailable
        }
        guard let format = formatOption(id: formatID) else {
            return nil
        }
        return .specific(defaultSelection(for: format))
    }

    nonisolated func preference(
        _ preference: MediaDownloadFormatPreference?,
        selectingAudioFormatID audioFormatID: String?
    ) -> MediaDownloadFormatPreference? {
        guard let format = selectedFormat(in: preference),
              let selection = selection(
                  for: format,
                  audioFormatID: audioFormatID
              ) else {
            return nil
        }
        return .specific(selection)
    }

    nonisolated func isSelectionUnavailable(
        in preference: MediaDownloadFormatPreference?
    ) -> Bool {
        guard let selection = preference?.selection else {
            return false
        }
        switch resolvedSelection(matching: selection) {
        case .some:
            return false
        case .none:
            return true
        }
    }

    nonisolated func unavailablePrimaryFormatID(
        in preference: MediaDownloadFormatPreference?
    ) -> String? {
        guard let formatID = preference?.selection?.primaryFormatID,
              formatOptions.contains(where: { $0.id == formatID }) == false else {
            return nil
        }
        return formatID
    }

    nonisolated func unavailableAudioFormatID(
        in preference: MediaDownloadFormatPreference?
    ) -> String? {
        guard let audioFormatID = preference?.selection?.audioFormatID,
              audioFormatOptions.contains(where: { $0.id == audioFormatID }) == false else {
            return nil
        }
        return audioFormatID
    }

    private nonisolated func preferredAudioFormat(
        for videoFormat: MediaDownloadFormatOption
    ) -> MediaDownloadFormatOption? {
        let preferredExtensions: Set<String>
        switch videoFormat.container {
        case "mp4", "m4v", "mov":
            preferredExtensions = ["m4a", "mp4"]
        case "webm":
            preferredExtensions = ["webm"]
        default:
            preferredExtensions = [videoFormat.container]
        }

        return audioFormatOptions.max { lhs, rhs in
            let lhsLanguagePreference = lhs.languagePreference ?? Int.min
            let rhsLanguagePreference = rhs.languagePreference ?? Int.min
            if lhsLanguagePreference != rhsLanguagePreference {
                return lhsLanguagePreference < rhsLanguagePreference
            }

            let lhsSelectionPreference = lhs.selectionPreference ?? -Double.infinity
            let rhsSelectionPreference = rhs.selectionPreference ?? -Double.infinity
            if lhsSelectionPreference != rhsSelectionPreference {
                return lhsSelectionPreference < rhsSelectionPreference
            }

            let lhsIsContainerCompatible = preferredExtensions.contains(lhs.container)
            let rhsIsContainerCompatible = preferredExtensions.contains(rhs.container)
            if lhsIsContainerCompatible != rhsIsContainerCompatible {
                return lhsIsContainerCompatible == false
            }

            if lhs.audioChannels != rhs.audioChannels {
                return (lhs.audioChannels ?? 0) < (rhs.audioChannels ?? 0)
            }

            if lhs.bitrateKbps != rhs.bitrateKbps {
                return (lhs.bitrateKbps ?? 0) < (rhs.bitrateKbps ?? 0)
            }

            if lhs.estimatedBytes != rhs.estimatedBytes {
                return lhs.estimatedBytes < rhs.estimatedBytes
            }

            return lhs.id > rhs.id
        }
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
        if capabilities.supportsMediaFormatSelection {
            try container.encode(capabilities, forKey: .capabilities)
        }
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
        .bestAvailable
    }

    /// A compact copy suitable for durable download-record storage.
    nonisolated var persistenceSnapshot: MediaDownloadMetadata {
        guard capabilities.supportsMediaFormatSelection else {
            return self
        }

        return MediaDownloadMetadata(
            title: title,
            platform: platform,
            extractorKey: extractorKey,
            thumbnailURL: thumbnailURL,
            webpageURL: webpageURL,
            expectedBytes: expectedBytes,
            mediaType: mediaType,
            entryCount: entryCount,
            capabilities: .unavailable
        )
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
        let options = checkedFormats.compactMap { format -> MediaDownloadFormatOption? in
            guard let formatID = format.normalizedFormatID,
                  let container = format.normalizedExtension else {
                return nil
            }

            if format.hasVideo {
                guard let videoCodec = format.normalizedVideoCodec else {
                    return nil
                }

                guard format.hasAudio || format.hasNoAudio else {
                    return nil
                }

                return MediaDownloadFormatOption(
                    formatID: formatID,
                    container: container,
                    videoCodec: videoCodec,
                    audioCodec: format.normalizedAudioCodec,
                    width: format.width,
                    height: format.height,
                    framesPerSecond: format.framesPerSecond,
                    dynamicRange: format.normalizedDynamicRange,
                    bitrateKbps: format.totalBitrateKbps,
                    estimatedBytes: format.expectedBytes,
                    language: format.normalizedLanguage,
                    formatNote: format.normalizedFormatNote,
                    audioChannels: format.audioChannels,
                    languagePreference: format.languagePreference,
                    selectionPreference: format.preference
                )
            }

            guard format.hasNoVideo,
                  format.hasAudio,
                  let audioCodec = format.normalizedAudioCodec else {
                return nil
            }

            return MediaDownloadFormatOption(
                formatID: formatID,
                container: container,
                videoCodec: nil,
                audioCodec: audioCodec,
                width: nil,
                height: nil,
                framesPerSecond: nil,
                dynamicRange: nil,
                bitrateKbps: format.totalBitrateKbps,
                estimatedBytes: format.expectedBytes,
                language: format.normalizedLanguage,
                formatNote: format.normalizedFormatNote,
                audioChannels: format.audioChannels,
                languagePreference: format.languagePreference,
                selectionPreference: format.preference
            )
        }

        var uniqueOptions: [FormatOptionIdentity: MediaDownloadFormatOption] = [:]
        for option in options {
            uniqueOptions[FormatOptionIdentity(option)] = option
        }

        return uniqueOptions.values.sorted(by: formatOptionComesFirst)
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

        if lhs.isAudioOnly, rhs.isAudioOnly,
           lhs.languagePreference != rhs.languagePreference {
            return (lhs.languagePreference ?? Int.min) > (rhs.languagePreference ?? Int.min)
        }

        if lhs.container != rhs.container {
            return lhs.container < rhs.container
        }

        if lhs.bitrateKbps != rhs.bitrateKbps {
            return (lhs.bitrateKbps ?? -1) > (rhs.bitrateKbps ?? -1)
        }

        return lhs.formatID < rhs.formatID
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
        let language: String?
        let formatNote: String?
        let audioChannels: Int?
        let languagePreference: Int?
        let selectionPreferenceHundredths: Int?

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
            language = option.language?.lowercased()
            formatNote = option.formatNote?.lowercased()
            audioChannels = option.audioChannels
            languagePreference = option.languagePreference
            if let selectionPreference = option.selectionPreference,
               selectionPreference.isFinite,
               selectionPreference <= Double(Int.max) / 100,
               selectionPreference >= Double(Int.min) / 100 {
                selectionPreferenceHundredths = Int((selectionPreference * 100).rounded())
            } else {
                selectionPreferenceHundredths = nil
            }
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
                audioBitrate: nil,
                language: nil,
                formatNote: nil,
                audioChannels: nil,
                languagePreference: nil,
                preference: nil
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
    let language: String?
    let formatNote: String?
    let audioChannels: Int?
    let languagePreference: Int?
    let preference: Double?

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
        case language
        case formatNote = "format_note"
        case audioChannels = "audio_channels"
        case languagePreference = "language_preference"
        case preference
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

    nonisolated var normalizedLanguage: String? {
        language?.nilIfBlank
    }

    nonisolated var normalizedFormatNote: String? {
        formatNote?.nilIfBlank
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
