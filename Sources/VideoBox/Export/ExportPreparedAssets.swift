import Foundation

struct ExportPreparedAssets: Sendable {
    var lutFilters: [String]?
    var subtitleURLs: [URL]?
    var burnSubtitleURL: URL?
    var chapterURL: URL?

    static func make(request: ExportRequest, directory: URL, ffmpeg: URL, runner: any CLIProcessRunning) async throws -> ExportPreparedAssets {
        guard case .media = request.operation else { return ExportPreparedAssets() }
        var assets = ExportPreparedAssets()
        if let lut = request.configuration.color.activeLUTFile {
            assets.lutFilters = try CubeLUT.load(from: lut.url).prepareFilters(in: directory)
        }
        let subtitleSettings = request.configuration.subtitles
        let needsSubtitles = subtitleSettings.mode == .burn
            || (subtitleSettings.mode != .remove && request.editing.changesSourceTimingForExport)
        var tracks = request.configuration.trackSettings
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let needsChapters = request.configuration.containerOptions.preserveChapters && request.editing.changesSourceTimingForExport
        var probe: MediaProbe?
        if needsChapters || (needsSubtitles && tracks.isEmpty) {
            probe = try await FFprobeEngine(executableURL: ffprobe, runner: runner).probe(request.sourceURL)
            if tracks.isEmpty, let probe {
                tracks = probe.streams.map { TrackExportSettings(sourceURL: request.sourceURL, stream: $0, sourceDuration: probe.duration) }
            }
        }
        if needsChapters {
            let url = directory.appendingPathComponent("chapters.ffmetadata")
            try TimedMetadataRemapper.ffmetadata(TimedMetadataRemapper.chapters(probe?.chapters ?? [], editing: request.editing, primarySourceURL: request.sourceURL))
                .write(to: url, atomically: true, encoding: .utf8)
            assets.chapterURL = url
        }
        if needsSubtitles {
            let allSubtitles = tracks.filter { $0.kind == .subtitle }
            let selected: [TrackExportSettings]
            if subtitleSettings.mode == .burn {
                guard allSubtitles.indices.contains(subtitleSettings.burnStreamIndex), allSubtitles[subtitleSettings.burnStreamIndex].isIncluded else {
                    throw ExportValidationError(blockers: ["所选字幕轨道不存在或未启用"])
                }
                selected = [allSubtitles[subtitleSettings.burnStreamIndex]]
            } else { selected = allSubtitles.filter(\.isIncluded) }
            var urls: [URL] = []
            for (index, track) in selected.enumerated() {
                try Task.checkCancellation()
                let raw = directory.appendingPathComponent("subtitle-\(index)-source.ass")
                let url = directory.appendingPathComponent("subtitle-\(index)-edited.ass")
                let result = try await runner.run(CLICommand(executableURL: ffmpeg, arguments: [
                    "-v", "error", "-nostdin", "-n", "-i", track.resolvedSourceURL(primarySourceURL: request.sourceURL).path,
                    "-map", "0:\(track.streamIndex)", "-c:s", "ass", raw.path
                ]))
                guard result.succeeded else { throw ExportValidationError(blockers: ["字幕读取失败（位图字幕需先 OCR）：\(result.standardError)"]) }
                let text = try String(contentsOf: raw, encoding: .utf8)
                try TimedMetadataRemapper.ass(text, editing: request.editing, offset: subtitleSettings.timeOffsetSeconds, primarySourceURL: request.sourceURL)
                    .write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
            if subtitleSettings.mode == .burn { assets.burnSubtitleURL = urls.first }
            else { assets.subtitleURLs = urls }
        }
        return assets
    }
}
