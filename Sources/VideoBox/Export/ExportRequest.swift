import Foundation

struct ExportRequest: Codable, Equatable, Sendable {
    var sourceURL: URL
    var destinationURL: URL
    var sourceDuration: TimeInterval?
    var configuration: ExportConfiguration
    var editing: EditSettings
    var operation: ExportOperation

    init(
        sourceURL: URL,
        destinationURL: URL,
        sourceDuration: TimeInterval? = nil,
        configuration: ExportConfiguration,
        editing: EditSettings,
        operation: ExportOperation = .media
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceDuration = sourceDuration
        self.configuration = configuration
        self.editing = editing
        self.operation = operation
    }
}

enum ExportOperation: Codable, Equatable, Sendable {
    case media
    case trackExtraction(TrackExportSettings)
}

struct ExportConfiguration: Codable, Equatable, Sendable {
    var mode: ExportMode = .streamCopy
    var container: MediaContainer = .mp4
    var streamSelection: StreamSelection = .all
    var includeAttachments = true
    var includeDataStreams = false
    var trackSettings: [TrackExportSettings] = []
    var metadataEntries: [MetadataExportEntry] = []
    var video = VideoExportSettings()
    var audio = AudioExportSettings()
    var subtitles = SubtitleExportSettings()
    var containerOptions = ContainerExportSettings()
    var advanced = AdvancedExportSettings()
}

struct TrackExportSettings: Codable, Equatable, Identifiable, Sendable {
    var sourceURL: URL?
    var streamIndex: Int
    var kind: MediaStreamKind
    var isIncluded: Bool
    var title: String
    var language: String
    var isDefault: Bool
    var codecName: String?
    var width: Int?
    var height: Int?
    var sampleRate: Int?
    var channels: Int?
    var sourceDuration: TimeInterval?

    var id: String {
        let sourceIdentity = sourceURL?.standardizedFileURL.path ?? "__primary__"
        return "\(sourceIdentity)::\(kind.rawValue)::\(streamIndex)"
    }

    init(
        sourceURL: URL? = nil,
        streamIndex: Int,
        kind: MediaStreamKind,
        isIncluded: Bool = true,
        title: String = "",
        language: String = "",
        isDefault: Bool = false,
        codecName: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        sourceDuration: TimeInterval? = nil
    ) {
        self.sourceURL = sourceURL
        self.streamIndex = streamIndex
        self.kind = kind
        self.isIncluded = isIncluded
        self.title = title
        self.language = language
        self.isDefault = isDefault
        self.codecName = codecName
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channels = channels
        self.sourceDuration = sourceDuration
    }

    init(sourceURL: URL, stream: MediaStream, sourceDuration: TimeInterval?) {
        self.init(
            sourceURL: sourceURL,
            streamIndex: stream.index,
            kind: stream.kind,
            title: stream.title ?? "",
            language: stream.language ?? "",
            isDefault: stream.isDefault,
            codecName: stream.codecName,
            width: stream.width,
            height: stream.height,
            sampleRate: stream.sampleRate,
            channels: stream.channels,
            sourceDuration: sourceDuration
        )
    }

    func resolvedSourceURL(primarySourceURL: URL) -> URL {
        sourceURL ?? primarySourceURL
    }

    func isImported(relativeTo primarySourceURL: URL) -> Bool {
        resolvedSourceURL(primarySourceURL: primarySourceURL).standardizedFileURL
            != primarySourceURL.standardizedFileURL
    }

    var suggestedExtractionExtension: String {
        let codec = codecName?.lowercased() ?? ""
        switch kind {
        case .video:
            return ["h264", "hevc", "h265", "mpeg4", "prores"].contains(codec) ? "mov" : "mkv"
        case .audio:
            switch codec {
            case "aac", "alac": return "m4a"
            case "mp3": return "mp3"
            case "flac": return "flac"
            case "opus": return "opus"
            case "vorbis": return "ogg"
            case let value where value.hasPrefix("pcm_"): return "wav"
            default: return "mka"
            }
        case .subtitle:
            switch codec {
            case "ass", "ssa": return "ass"
            case "webvtt": return "vtt"
            case "hdmv_pgs_subtitle": return "sup"
            case "dvd_subtitle", "dvb_subtitle", "dvb_teletext", "xsub", "arib_caption":
                return "mkv"
            default: return "srt"
            }
        default:
            return "mkv"
        }
    }
}

struct TrackPreviewSelection: Equatable, Sendable {
    var videoTrackID: String?
    var audioTrackID: String?
    var subtitleTrackID: String?

    mutating func select(_ track: TrackExportSettings) {
        switch track.kind {
        case .video: videoTrackID = track.id
        case .audio: audioTrackID = track.id
        case .subtitle: subtitleTrackID = track.id
        default: break
        }
    }

    mutating func normalize(using tracks: [TrackExportSettings]) {
        videoTrackID = normalizedID(videoTrackID, kind: .video, tracks: tracks)
        audioTrackID = normalizedID(audioTrackID, kind: .audio, tracks: tracks)

        let subtitles = tracks.filter { $0.kind == .subtitle }
        if let subtitleTrackID, !subtitles.contains(where: { $0.id == subtitleTrackID }) {
            self.subtitleTrackID = subtitles.first(where: { $0.isIncluded && $0.isDefault })?.id
        }
    }

    func selectedTracks(from tracks: [TrackExportSettings]) -> [TrackExportSettings] {
        var normalized = self
        normalized.normalize(using: tracks)
        return [
            normalized.videoTrackID.flatMap { id in tracks.first { $0.id == id } },
            normalized.audioTrackID.flatMap { id in tracks.first { $0.id == id } },
            normalized.subtitleTrackID.flatMap { id in tracks.first { $0.id == id } }
        ].compactMap { $0 }
    }

    private func normalizedID(
        _ requestedID: String?,
        kind: MediaStreamKind,
        tracks: [TrackExportSettings]
    ) -> String? {
        let matching = tracks.filter { $0.kind == kind }
        if let requestedID, matching.contains(where: { $0.id == requestedID }) {
            return requestedID
        }
        return matching.first(where: { $0.isIncluded && $0.isDefault })?.id
            ?? matching.first(where: \.isIncluded)?.id
            ?? matching.first?.id
    }
}

extension ExportConfiguration {
    mutating func moveTrack(id: String, to targetID: String) {
        guard id != targetID,
              let moving = trackSettings.first(where: { $0.id == id }),
              let target = trackSettings.first(where: { $0.id == targetID }),
              moving.kind == target.kind else { return }

        let positions = trackSettings.indices.filter { trackSettings[$0].kind == moving.kind }
        var orderedTracks = positions.map { trackSettings[$0] }
        guard let sourceIndex = orderedTracks.firstIndex(where: { $0.id == id }),
              let targetIndex = orderedTracks.firstIndex(where: { $0.id == targetID }) else { return }

        let item = orderedTracks.remove(at: sourceIndex)
        orderedTracks.insert(item, at: min(targetIndex, orderedTracks.count))
        for (position, track) in zip(positions, orderedTracks) {
            trackSettings[position] = track
        }
    }

    mutating func moveTrack(id: String, by offset: Int) {
        guard let moving = trackSettings.first(where: { $0.id == id }) else { return }
        let matching = trackSettings.filter { $0.kind == moving.kind }
        guard let index = matching.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), matching.count - 1)
        guard target != index else { return }
        moveTrack(id: id, to: matching[target].id)
    }
}

struct MetadataExportEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

enum ExportMode: String, Codable, CaseIterable, Hashable, Sendable {
    case streamCopy
    case transcode

    var displayName: String {
        switch self {
        case .streamCopy: "快速导出"
        case .transcode: "压缩导出"
        }
    }

    var detail: String {
        switch self {
        case .streamCopy: "复制原始码流，不损失画质"
        case .transcode: "重新编码，可调整画质与尺寸"
        }
    }
}

enum MediaContainer: String, Codable, CaseIterable, Hashable, Sendable {
    case mp4
    case mov
    case mkv
    case webm

    var displayName: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    var supportsFastStart: Bool {
        self == .mp4 || self == .mov
    }
}

enum StreamSelection: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case primary

    var displayName: String {
        switch self {
        case .all: "全部轨道"
        case .primary: "主视频与主音频"
        }
    }
}

struct VideoExportSettings: Codable, Equatable, Sendable {
    var codec: VideoCodec = .hevcVideoToolbox
    var rateControl: VideoRateControl = .averageBitrate
    var quality = 70
    var averageBitrateKbps = 8_000
    var maximumBitrateKbps = 12_000
    var bufferSizeKbps = 16_000
    var targetSizeMB = 1_024
    var preset: EncoderPreset = .medium
    var tune: EncoderTune = .none
    var profile: VideoProfile = .automatic
    var resolution: ResolutionPreset = .source
    var customWidth = 1_920
    var customHeight = 1_080
    var allowUpscaling = false
    var frameRate: FrameRatePreset = .source
    var customFrameRate = 30.0
    var pixelFormat: PixelFormat = .automatic
    var keyframeIntervalSeconds = 2.0
    var bFrames = 3
    var preserveHDRMetadata = true
}

enum VideoCodec: String, Codable, CaseIterable, Hashable, Sendable {
    case h264VideoToolbox
    case hevcVideoToolbox
    case h264
    case hevc
    case av1
    case proRes

    var displayName: String {
        switch self {
        case .h264VideoToolbox: "H.264 · Apple 硬件"
        case .hevcVideoToolbox: "H.265/HEVC · Apple 硬件"
        case .h264: "H.264 · 软件"
        case .hevc: "H.265/HEVC · 软件"
        case .av1: "AV1 · 软件"
        case .proRes: "Apple ProRes"
        }
    }

    var ffmpegName: String {
        switch self {
        case .h264VideoToolbox: "h264_videotoolbox"
        case .hevcVideoToolbox: "hevc_videotoolbox"
        case .h264: "libx264"
        case .hevc: "libx265"
        case .av1: "libsvtav1"
        case .proRes: "prores_ks"
        }
    }

    var isHardwareAccelerated: Bool {
        self == .h264VideoToolbox || self == .hevcVideoToolbox
    }

    var supportsSoftwarePreset: Bool {
        self == .h264 || self == .hevc || self == .av1
    }

    var supportedProfiles: [VideoProfile] {
        switch self {
        case .h264VideoToolbox, .h264:
            [.automatic, .baseline, .main, .high]
        case .hevcVideoToolbox, .hevc:
            [.automatic, .main, .main10]
        case .av1:
            [.automatic, .main]
        case .proRes:
            [.automatic, .proxy, .lt, .standard, .hq, .fourFourFourFour]
        }
    }
}

enum VideoRateControl: String, Codable, CaseIterable, Hashable, Sendable {
    case constantQuality
    case averageBitrate
    case targetSize

    var displayName: String {
        switch self {
        case .constantQuality: "恒定质量"
        case .averageBitrate: "平均码率"
        case .targetSize: "目标文件大小"
        }
    }
}

enum EncoderPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case ultrafast
    case veryfast
    case fast
    case medium
    case slow
    case veryslow

    var displayName: String {
        switch self {
        case .ultrafast: "最快"
        case .veryfast: "很快"
        case .fast: "较快"
        case .medium: "平衡"
        case .slow: "较慢"
        case .veryslow: "最慢 / 更高压缩率"
        }
    }
}

enum EncoderTune: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case film
    case animation
    case grain
    case stillImage
    case fastDecode

    var displayName: String {
        switch self {
        case .none: "自动"
        case .film: "实拍"
        case .animation: "动画"
        case .grain: "保留颗粒"
        case .stillImage: "静态画面"
        case .fastDecode: "快速解码"
        }
    }

    var ffmpegValue: String? {
        switch self {
        case .none: nil
        case .film: "film"
        case .animation: "animation"
        case .grain: "grain"
        case .stillImage: "stillimage"
        case .fastDecode: "fastdecode"
        }
    }
}

enum VideoProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case baseline
    case main
    case high
    case main10
    case proxy
    case lt
    case standard
    case hq
    case fourFourFourFour

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .baseline: "Baseline"
        case .main: "Main"
        case .high: "High"
        case .main10: "Main 10"
        case .proxy: "Proxy"
        case .lt: "LT"
        case .standard: "Standard"
        case .hq: "HQ"
        case .fourFourFourFour: "4444"
        }
    }

    var ffmpegValue: String? {
        switch self {
        case .automatic: nil
        case .baseline: "baseline"
        case .main: "main"
        case .high: "high"
        case .main10: "main10"
        case .proxy: "0"
        case .lt: "1"
        case .standard: "2"
        case .hq: "3"
        case .fourFourFourFour: "4"
        }
    }
}

enum ResolutionPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case uhd2160
    case qhd1440
    case fullHD1080
    case hd720
    case sd480
    case custom

    var displayName: String {
        switch self {
        case .source: "保持原始"
        case .uhd2160: "4K · 3840 × 2160"
        case .qhd1440: "2K · 2560 × 1440"
        case .fullHD1080: "1080p · 1920 × 1080"
        case .hd720: "720p · 1280 × 720"
        case .sd480: "480p · 854 × 480"
        case .custom: "自定义"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .source: nil
        case .uhd2160: (3_840, 2_160)
        case .qhd1440: (2_560, 1_440)
        case .fullHD1080: (1_920, 1_080)
        case .hd720: (1_280, 720)
        case .sd480: (854, 480)
        case .custom: nil
        }
    }
}

enum FrameRatePreset: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case fps24
    case fps25
    case fps30
    case fps50
    case fps60
    case custom

    var displayName: String {
        switch self {
        case .source: "保持原始"
        case .fps24: "24 fps"
        case .fps25: "25 fps"
        case .fps30: "30 fps"
        case .fps50: "50 fps"
        case .fps60: "60 fps"
        case .custom: "自定义"
        }
    }

    var value: Double? {
        switch self {
        case .source, .custom: nil
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps50: 50
        case .fps60: 60
        }
    }
}

enum PixelFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case yuv420p
    case yuv420p10le
    case yuv422p10le
    case yuv444p10le

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .yuv420p: "8-bit 4:2:0"
        case .yuv420p10le: "10-bit 4:2:0"
        case .yuv422p10le: "10-bit 4:2:2"
        case .yuv444p10le: "10-bit 4:4:4"
        }
    }

    var ffmpegValue: String? {
        self == .automatic ? nil : rawValue
    }
}

struct AudioExportSettings: Codable, Equatable, Sendable {
    var codec: AudioCodec = .aac
    var bitrateKbps = 256
    var sampleRate: AudioSampleRate = .source
    var channels: AudioChannelLayout = .source
    var normalizeLoudness = false
    var targetLoudnessLUFS = -14.0
}

enum AudioCodec: String, Codable, CaseIterable, Hashable, Sendable {
    case copy
    case aac
    case opus
    case ac3
    case eac3
    case flac
    case pcm
    case none

    var displayName: String {
        switch self {
        case .copy: "复制原始音频"
        case .aac: "AAC"
        case .opus: "Opus"
        case .ac3: "AC-3"
        case .eac3: "E-AC-3"
        case .flac: "FLAC"
        case .pcm: "PCM 16-bit"
        case .none: "移除音频"
        }
    }

    var ffmpegName: String? {
        switch self {
        case .copy: "copy"
        case .aac: "aac"
        case .opus: "libopus"
        case .ac3: "ac3"
        case .eac3: "eac3"
        case .flac: "flac"
        case .pcm: "pcm_s16le"
        case .none: nil
        }
    }

    var usesBitrate: Bool {
        switch self {
        case .aac, .opus, .ac3, .eac3: true
        case .copy, .flac, .pcm, .none: false
        }
    }
}

enum AudioSampleRate: Int, Codable, CaseIterable, Hashable, Sendable {
    case source = 0
    case hz44100 = 44_100
    case hz48000 = 48_000
    case hz96000 = 96_000

    var displayName: String {
        self == .source ? "保持原始" : "\(rawValue / 1_000) kHz"
    }
}

enum AudioChannelLayout: Int, Codable, CaseIterable, Hashable, Sendable {
    case source = 0
    case mono = 1
    case stereo = 2
    case surround51 = 6
    case surround71 = 8

    var displayName: String {
        switch self {
        case .source: "保持原始"
        case .mono: "单声道"
        case .stereo: "立体声"
        case .surround51: "5.1 声道"
        case .surround71: "7.1 声道"
        }
    }
}

struct SubtitleExportSettings: Codable, Equatable, Sendable {
    var mode: SubtitleMode = .copy
    var burnStreamIndex = 0
    var timeOffsetSeconds = 0.0
}

enum SubtitleMode: String, Codable, CaseIterable, Hashable, Sendable {
    case copy
    case convert
    case burn
    case remove

    var displayName: String {
        switch self {
        case .copy: "复制字幕轨"
        case .convert: "转换为容器兼容格式"
        case .burn: "烧录到画面"
        case .remove: "移除字幕"
        }
    }
}

struct ContainerExportSettings: Codable, Equatable, Sendable {
    var preserveMetadata = true
    var preserveChapters = true
    var fastStart = true
    var normalizeTimestamps = true
    var preventNegativeTimestamps = true
}

struct AdvancedExportSettings: Codable, Equatable, Sendable {
    var hardwareDecoding = true
    var threadCount = 0
    var overwriteExisting = false
    var additionalArguments = ""
}
