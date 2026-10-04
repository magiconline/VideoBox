import AVFoundation
import Foundation

final class PreviewVideoResource: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    init(url: URL) { self.url = url; asset = AVURLAsset(url: url) }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

enum CompositionPreviewRenderer {
    static func render(source: URL, editing: EditSettings, configuration: ExportConfiguration?) async throws -> PreviewTimeline {
        let tools = await ToolchainInspector().inspect()
        guard let ffmpeg = tools.executableURL(for: .ffmpeg), let ffprobe = tools.executableURL(for: .ffprobe) else {
            throw ProjectError.invalid("多素材与特效预览需要随包 FFmpeg")
        }
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        var config = configuration ?? ExportConfiguration()
        if config.trackSettings.isEmpty { config.trackSettings = probe.streams.filter { $0.kind == .video || $0.kind == .audio }.map { TrackExportSettings(sourceURL: source, stream: $0, sourceDuration: probe.duration) } }
        config.trackSettings = Array(config.trackSettings.filter { $0.isIncluded && $0.kind == .video }.prefix(1))
            + Array(config.trackSettings.filter { $0.isIncluded && $0.kind == .audio }.prefix(1))
        config.mode = .transcode; config.container = .mp4; config.includeAttachments = false; config.includeDataStreams = false
        config.metadataEntries = []; config.containerOptions = ContainerExportSettings(); config.containerOptions.preserveChapters = false
        config.subtitles.mode = .remove; config.advanced = AdvancedExportSettings()
        let outputHDR = ColorConversionPlan(settings: config.color, source: probe.primaryVideoStream).output?.isHDR == true
        config.video = VideoExportSettings(); config.video.codec = .h264; config.video.pixelFormat = .yuv420p; config.video.preset = .ultrafast
        if outputHDR { config.video.codec = .hevc; config.video.pixelFormat = .yuv420p10le }
        config.video.quality = 65; config.video.allowUpscaling = true
        config.video.frameRate = .custom; config.video.customFrameRate = editing.compositionFrameRate(configuration: configuration ?? config, source: probe.primaryVideoStream)
        config.audio.codec = .aac; config.audio.normalizeLoudness = false
        var previewEdit = editing
        let aspect = Double(editing.canvasWidth ?? 1920) / Double(editing.canvasHeight ?? 1080)
        let width = min(960, editing.canvasWidth ?? 960), height = max(2, Int(Double(width) / aspect) / 2 * 2)
        previewEdit.canvasWidth = width / 2 * 2; previewEdit.canvasHeight = height
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-TrackPreviews")
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resource = PreviewVideoResource(url: directory.appendingPathComponent("composition.mp4"))
        let request = ExportRequest(sourceURL: source, destinationURL: resource.url, sourceDuration: probe.duration,
            sourceVideo: probe.primaryVideoStream, configuration: config, editing: previewEdit)
        try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
        try Task.checkCancellation()
        return PreviewTimeline(asset: resource.asset, audioMix: nil, duration: editing.outputDuration, videoResource: resource)
    }
}
