import Foundation

/// A single interpretation of the settings used by the UI, queue and export engine.
struct ExportPlan: Sendable {
    let mode: ExportMode
    let pixelFormat: PixelFormat
    let blockers: [String]

    init(configuration: ExportConfiguration, editing: EditSettings, sourceVideo: MediaStream? = nil, primarySourceURL: URL? = nil, sourceDuration: Double? = nil) {
        mode = configuration.mode
        let tracks = configuration.trackSettings.filter(\.isIncluded)
        let video = tracks.first(where: { $0.kind == .video })?.sourceStream ?? sourceVideo
        let audioTracks = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        let color = configuration.color
        let settings = configuration.video
        pixelFormat = Self.resolvedPixelFormat(settings: settings, sourceVideo: video)
        var reasons: [String] = []
        reasons += editing.validationIssues
        if editing.requiresRenderedPreview, configuration.audio.codec == .copy {
            reasons.append("多素材或特效合成需要音频重新编码；请选择 AAC、Opus 等，或移除音频")
        }
        if editing.requiresRenderedPreview {
            for stream in editing.clips.compactMap({ $0.media?.video }) + editing.overlayClips.compactMap({ $0.media.video }) {
                reasons += ColorConversionPlan(settings: color, source: stream).blockers
            }
            if color.outputColorSpace == .source && color.activeLUTFile == nil, let primary = VideoColorSpec(stream: video) {
                let sources = editing.clips.compactMap { $0.media?.video } + editing.overlayClips.compactMap { $0.media.video }
                if sources.contains(where: { VideoColorSpec(stream: $0).map { $0 != primary } ?? false }) {
                    reasons.append("素材色彩空间或范围不同；请明确选择统一输出色彩空间，不能混合后沿用主素材标签")
                }
            }
        }

        if !configuration.trackSettings.isEmpty, !tracks.contains(where: { $0.kind == .video }) {
            reasons.append("成片导出至少需要启用一条视频轨道")
        }
        if !configuration.advanced.additionalArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("附加参数可能覆盖已校验设置；请清空附加 FFmpeg 参数后导出")
        }

        if mode == .streamCopy {
            if let range = editing.simpleTrimRange() {
                let selectedURL = primarySourceURL.map { primary in tracks.first(where: { $0.kind == .video })?.resolvedSourceURL(primarySourceURL: primary) ?? primary }
                if let index = configuration.copyTrimIndex,
                   selectedURL.map({ index.isCurrent(for: $0, streamIndex: video?.index ?? 0) }) ?? true {
                    if !index.isAligned(range) { reasons.append("裁切点未对齐关键帧；请对齐裁切点或使用压缩导出精确裁切") }
                } else { reasons.append("裁切前需要完成关键帧检查") }
            }
            if color.discardsDynamicHDR { reasons.append("移除动态 HDR 元数据需要压缩导出") }
            if video?.hasDynamicHDR == true && editing.changesSourceTimingForExport {
                reasons.append("动态 HDR 原样保留暂不允许改动时间线；请保持完整源片，或选择移除动态元数据后压缩导出")
            }
            if color.activeLUTFile != nil { reasons.append("已应用 LUT") }
            if !color.outputColorSpace.matches(video, declaredInput: color.inputProfile) {
                reasons.append("输出色彩空间与源视频不同")
            }
            if !color.outputRange.matches(video) { reasons.append("输出色彩范围与源视频不同") }
            if let depth = settings.pixelFormat.bitDepth, depth != video?.bitDepth {
                reasons.append("输出位深与源视频不同")
            }
            if let chroma = settings.pixelFormat.chromaSubsampling, chroma != video?.chromaSubsampling {
                reasons.append("色度采样与源视频不同")
            }
            if editing.requiresFilterComposition { reasons.append("剪辑或画面调整需要重新编码") }
            if settings.resolution != .source { reasons.append("已修改输出分辨率") }
            if settings.frameRate != .source { reasons.append("已修改输出帧率") }
            if configuration.subtitles.mode == .burn { reasons.append("已启用字幕烧录") }
            if configuration.audio.codec != .none {
                if configuration.audio.normalizeLoudness { reasons.append("已启用响度标准化") }
                if configuration.audio.sampleRate != .source {
                    reasons.append("已指定音频重采样")
                }
                if configuration.audio.channels != .source { reasons.append("已指定音频声道转换") }
                if configuration.audio.codec != .copy, let target = configuration.audio.codec.mediaCodecName,
                   audioTracks.contains(where: { $0.codecName?.lowercased() != target }) {
                    reasons.append("音频编码与源音轨不同；快速导出请选复制原始音频")
                }
            }
        } else {
            if !settings.codec.supportedPixelFormats.contains(pixelFormat) {
                reasons.append("\(settings.codec.displayName) 不支持 \(pixelFormat.displayName)，请选择兼容位深/采样或软件编码器")
            }
            if settings.pixelFormat == .automatic, let depth = video?.bitDepth, ![8, 10, 12].contains(depth) {
                reasons.append("源视频为 \(depth)-bit，当前不能自动保留；请明确选择输出位深")
            }
            if settings.rateControl == .targetSize {
                reasons += TargetSizeBudget(configuration: configuration, duration: editing.trimmedDuration ?? sourceDuration ?? editing.sourceDuration).blockers
            }
            if !settings.codec.supportedProfiles.contains(settings.profile) {
                reasons.append("当前编码器不支持所选编码档次")
            } else if !settings.profile.accepts(pixelFormat, codec: settings.codec) {
                reasons.append("编码档次 \(settings.profile.displayName) 与 \(pixelFormat.displayName) 不兼容，请选择自动或兼容档次")
            }
            if settings.profile == .baseline, settings.bFrames > 0 {
                reasons.append("Baseline 不支持 B 帧，请将 B 帧数量设为 0")
            }
            if configuration.audio.codec == .copy,
               configuration.audio.normalizeLoudness || configuration.audio.sampleRate != .source
                || configuration.audio.channels != .source || editing.requiresFilterComposition || editing.simpleTrimRange() != nil {
                if !audioTracks.isEmpty || configuration.trackSettings.isEmpty {
                    reasons.append("音频处理需要重新编码，请选择 AAC、Opus 等音频编码或移除音频")
                }
            }
            let colorPlan = ColorConversionPlan(settings: color, source: video)
            reasons += colorPlan.blockers
            if colorPlan.output?.isHDR == true && (pixelFormat.bitDepth ?? 8) < 10 {
                reasons.append("HDR 输出请选 10-bit 或更高位深")
            }
            if colorPlan.needsConversion && tracks.filter({ $0.kind == .video }).count > 1 {
                reasons.append("色彩转换时请只保留一条视频轨道")
            }
            if editing.requiresFilterComposition {
                if tracks.filter({ $0.kind == .video }).count > 1 {
                    reasons.append("片段剪切、重排或变速时只能保留一条视频轨道")
                }
            }
        }

        let outputVideoCodecs = mode == .transcode
            ? [settings.codec.mediaCodecName]
            : tracks.filter { $0.kind == .video }.compactMap { $0.codecName?.lowercased() }
                + (tracks.isEmpty ? [video?.codecName?.lowercased()].compactMap { $0 } : [])
        for codec in Set(outputVideoCodecs) where !configuration.container.acceptsVideo(codec) {
            reasons.append("\(configuration.container.displayName) 不支持视频编码 \(codec)，请更换容器或编码器")
        }
        if configuration.audio.codec != .none {
            let outputAudioCodecs = mode == .streamCopy || configuration.audio.codec == .copy
                ? audioTracks.compactMap { $0.codecName?.lowercased() }
                : (audioTracks.isEmpty && !tracks.isEmpty ? [] : [configuration.audio.codec.mediaCodecName].compactMap { $0 })
            for codec in Set(outputAudioCodecs) where !configuration.container.acceptsAudio(codec) {
                reasons.append("\(configuration.container.displayName) 不支持音频编码 \(codec)，请更换容器或音频编码")
            }
        }
        if configuration.subtitles.mode == .copy && !editing.changesSourceTimingForExport {
            let subtitleCodecs = subtitles.compactMap { $0.codecName?.lowercased() }
            if subtitleCodecs.contains(where: { !configuration.container.acceptsSubtitle($0) }) {
                reasons.append("字幕编码与 \(configuration.container.displayName) 不兼容，请转换或移除字幕")
            }
        }
        if configuration.subtitles.mode == .convert || configuration.subtitles.mode == .burn
            || (editing.changesSourceTimingForExport && configuration.subtitles.mode != .remove),
           subtitles.contains(where: { Self.bitmapSubtitles.contains($0.codecName ?? "") }) {
            reasons.append("位图字幕尚不支持重映射或烧录，请先 OCR 为文字字幕或移除字幕")
        }
        if configuration.subtitles.mode == .burn {
            let sourceSubtitles = configuration.trackSettings.filter { $0.kind == .subtitle }
            let index = configuration.subtitles.burnStreamIndex
            if !configuration.trackSettings.isEmpty,
               !sourceSubtitles.indices.contains(index) || !sourceSubtitles[index].isIncluded {
                reasons.append("所选源字幕不存在或未启用，请选择有效字幕轨道或移除字幕")
            }
        }
        if configuration.includeAttachments, configuration.container != .mkv,
           tracks.contains(where: { $0.kind == .attachment }) {
            reasons.append("字体等附件请使用 MKV 容器或关闭保留附件")
        }
        if configuration.includeDataStreams, [.mkv, .webm].contains(configuration.container),
           tracks.contains(where: { $0.kind == .data }) {
            reasons.append("所选容器不支持当前数据轨道，请关闭保留数据轨道")
        }
        blockers = reasons.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    init(request: ExportRequest) {
        self.init(configuration: request.configuration, editing: request.editing, sourceVideo: request.sourceVideo, primarySourceURL: request.sourceURL, sourceDuration: request.sourceDuration)
    }

    func validate() throws {
        if !blockers.isEmpty { throw ExportValidationError(blockers: blockers) }
    }

    static func fileBlockers(configuration: ExportConfiguration, primarySourceURL: URL) -> [String] {
        var urls = [primarySourceURL]
        urls += configuration.trackSettings.filter { track in
            guard track.isIncluded else { return false }
            if track.kind == .audio, configuration.audio.codec == .none { return false }
            if track.kind == .subtitle, configuration.subtitles.mode == .remove { return false }
            return true
        }.map { $0.resolvedSourceURL(primarySourceURL: primarySourceURL) }
        if let lut = configuration.color.activeLUTFile { urls.append(lut.url) }
        return Set(urls).filter { !FileManager.default.isReadableFile(atPath: $0.path) }
            .map { "源文件已不可用：\($0.lastPathComponent)" }.sorted()
    }

    static func destinationBlockers(request: ExportRequest) -> [String] {
        var inputs = [request.sourceURL]
        inputs += request.configuration.trackSettings.map { $0.resolvedSourceURL(primarySourceURL: request.sourceURL) }
        if case let .trackExtraction(track) = request.operation {
            inputs.append(track.resolvedSourceURL(primarySourceURL: request.sourceURL))
        }
        if let lut = request.configuration.color.lutFile { inputs.append(lut.url) }
        inputs += request.editing.referencedURLs
        guard inputs.contains(where: { refersToSameFile($0, request.destinationURL) }) else { return [] }
        return ["导出目标与输入文件相同，不能覆盖源视频、轨道或 LUT；请更换输出文件名或文件夹"]
    }

    static func refersToSameFile(_ first: URL, _ second: URL) -> Bool {
        let firstResolved = first.resolvingSymlinksInPath().standardizedFileURL
        let secondResolved = second.resolvingSymlinksInPath().standardizedFileURL
        if firstResolved == secondResolved { return true }
        guard let firstAttributes = try? FileManager.default.attributesOfItem(atPath: firstResolved.path),
              let secondAttributes = try? FileManager.default.attributesOfItem(atPath: secondResolved.path),
              let firstDevice = firstAttributes[.systemNumber] as? NSNumber,
              let secondDevice = secondAttributes[.systemNumber] as? NSNumber,
              let firstInode = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondInode = secondAttributes[.systemFileNumber] as? NSNumber else { return false }
        return firstDevice == secondDevice && firstInode == secondInode
    }

    static func resolvedPixelFormat(settings: VideoExportSettings, sourceVideo: MediaStream?) -> PixelFormat {
        guard settings.pixelFormat == .automatic else { return settings.pixelFormat }
        return .make(
            bitDepth: OutputBitDepth(rawValue: sourceVideo?.bitDepth ?? 8) ?? .twelve,
            chroma: sourceVideo?.chromaSubsampling ?? .fourTwoZero
        )
    }

    private static let bitmapSubtitles: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub", "arib_caption"]
}

extension EditSettings {
    var changesSourceTimingForExport: Bool {
        if clips.contains(where: { $0.sourceURL != nil || ($0.transition?.duration ?? 0) > 0 }) { return true }
        guard !clips.isEmpty else { return false }
        var sourceCursor = 0.0
        for clip in clips {
            if abs(clip.playbackRate - 1) > 0.000_1 || abs(clip.sourceRange.start - sourceCursor) > 0.000_1 {
                return true
            }
            sourceCursor = clip.sourceRange.end
        }
        return abs(sourceCursor - sourceDuration) > 0.000_1
    }
}

struct ExportValidationError: LocalizedError {
    let blockers: [String]
    var errorDescription: String? { blockers.joined(separator: "；") }
}

extension VideoCodec {
    var supportedPixelFormats: [PixelFormat] {
        switch self {
        case .h264VideoToolbox: [.yuv420p]
        case .hevcVideoToolbox, .av1: [.yuv420p, .yuv420p10le]
        case .h264: PixelFormat.allCases.filter { $0 != .automatic && ($0.bitDepth ?? 0) <= 10 }
        case .hevc: PixelFormat.allCases.filter { $0 != .automatic }
        case .proRes: [.yuv422p10le, .yuv444p10le]
        }
    }

    var mediaCodecName: String {
        switch self {
        case .h264VideoToolbox, .h264: "h264"
        case .hevcVideoToolbox, .hevc: "hevc"
        case .av1: "av1"
        case .proRes: "prores"
        }
    }
}

extension AudioCodec {
    var mediaCodecName: String? {
        switch self {
        case .copy, .none: nil
        case .aac: "aac"
        case .opus: "opus"
        case .ac3: "ac3"
        case .eac3: "eac3"
        case .flac: "flac"
        case .pcm: "pcm_s16le"
        }
    }
}

private extension VideoProfile {
    func accepts(_ format: PixelFormat, codec: VideoCodec) -> Bool {
        if self == .automatic { return true }
        switch codec {
        case .h264VideoToolbox, .h264:
            return format == .yuv420p
        case .hevcVideoToolbox, .hevc:
            return format.chromaSubsampling == .fourTwoZero && (self == .main10 || format.bitDepth == 8)
        case .av1:
            return format.chromaSubsampling == .fourTwoZero
        case .proRes:
            return self == .fourFourFourFour ? format == .yuv444p10le : format == .yuv422p10le
        }
    }
}

private extension MediaContainer {
    func acceptsVideo(_ codec: String) -> Bool {
        switch self {
        case .webm: ["vp8", "vp9", "av1"].contains(codec)
        case .mp4: ["h264", "hevc", "h265", "av1", "vp9", "mpeg4", "mpeg2video", "mjpeg"].contains(codec)
        case .mov: ["h264", "hevc", "h265", "av1", "mpeg4", "mpeg2video", "prores", "mjpeg", "qtrle", "rawvideo", "png", "dnxhd"].contains(codec)
        case .mkv: true
        }
    }

    func acceptsAudio(_ codec: String) -> Bool {
        switch self {
        case .webm: ["opus", "vorbis"].contains(codec)
        case .mp4: ["aac", "alac", "mp3", "ac3", "eac3", "opus", "flac"].contains(codec)
        case .mov: codec.hasPrefix("pcm_") || ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec)
        case .mkv: true
        }
    }

    func acceptsSubtitle(_ codec: String) -> Bool {
        switch self {
        case .mp4, .mov: codec == "mov_text"
        case .webm: codec == "webvtt"
        case .mkv: codec != "mov_text"
        }
    }
}
