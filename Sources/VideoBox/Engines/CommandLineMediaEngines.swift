import Foundation

actor FFprobeEngine: MediaProbing {
    private let executableURL: URL
    private let runner: any CLIProcessRunning

    init(executableURL: URL, runner: any CLIProcessRunning = ProcessRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    func probe(_ sourceURL: URL) async throws -> MediaProbe {
        let result = try await runner.run(
            CLICommand(
                executableURL: executableURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    "-show_chapters",
                    "-show_frames", "-read_intervals", "%+#32",
                    "-show_entries", "frame=stream_index:frame_side_data",
                    sourceURL.path
                ]
            )
        )

        guard result.succeeded else {
            throw MediaEngineError.commandFailed(
                tool: "ffprobe",
                status: result.terminationStatus,
                message: result.standardError
            )
        }

        do {
            let payload = try JSONDecoder().decode(FFprobePayload.self, from: Data(result.standardOutput.utf8))
            var probe = payload.mediaProbe(sourceURL: sourceURL)
            probe.rawReport = result.standardOutput
            return probe
        } catch {
            throw MediaEngineError.invalidProbeOutput(error)
        }
    }
}

actor FFmpegExportEngine: MediaExporting {
    private let executableURL: URL
    private let runner: any CLIProcessRunning
    private let commandBuilder: FFmpegCommandBuilder

    init(
        executableURL: URL,
        runner: any CLIProcessRunning = ProcessRunner(),
        commandBuilder: FFmpegCommandBuilder = FFmpegCommandBuilder()
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.commandBuilder = commandBuilder
    }

    @discardableResult
    func export(_ request: ExportRequest) async throws -> URL {
        try await export(request, onProgress: nil)
    }

    @discardableResult
    func export(_ originalRequest: ExportRequest, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        var request = originalRequest
        let destinationBlockers = ExportPlan.destinationBlockers(request: request)
        if !destinationBlockers.isEmpty { throw ExportValidationError(blockers: destinationBlockers) }
        if case .media = request.operation {
            if request.configuration.mode == .streamCopy, request.editing.simpleTrimRange() != nil {
                let video = request.configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }
                request.configuration.copyTrimIndex = try await QuickTrimIndex.scan(
                    url: video?.resolvedSourceURL(primarySourceURL: request.sourceURL) ?? request.sourceURL,
                    streamIndex: video?.streamIndex ?? request.sourceVideo?.index ?? 0,
                    duration: request.editing.sourceDuration,
                    ffprobe: executableURL.deletingLastPathComponent().appendingPathComponent("ffprobe"), runner: runner)
            }
            try ExportPlan(request: request).validate()
            let fileBlockers = ExportPlan.fileBlockers(configuration: request.configuration, primarySourceURL: request.sourceURL)
                + request.editing.referencedURLs.filter { !FileManager.default.isReadableFile(atPath: $0.path) }.map { "素材已不可用：\($0.lastPathComponent)" }
            if !fileBlockers.isEmpty { throw ExportValidationError(blockers: fileBlockers) }
        }
        if !request.configuration.advanced.overwriteExisting {
            try ensureDestinationDoesNotExist(request.destinationURL)
        }
        // Never write over a prior export until a complete, verified replacement is ready.
        let temporaryURL = request.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".VideoBox-\(UUID().uuidString)")
            .appendingPathExtension(request.destinationURL.pathExtension)
        var workingRequest = request
        workingRequest.destinationURL = temporaryURL
        workingRequest.configuration.advanced.overwriteExisting = false
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-export-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assetDirectory) }
        let prepared = try await ExportPreparedAssets.make(request: request, directory: assetDirectory, ffmpeg: executableURL, runner: runner)
        let duration: TimeInterval?
        if case let .trackExtraction(track) = request.operation {
            duration = track.sourceDuration ?? request.sourceDuration
        } else {
            duration = request.editing.trimmedDuration ?? request.sourceDuration
        }
        let progressParser = FFmpegProgressParser(duration: duration)
        let result = try await runner.run(
            CLICommand(executableURL: executableURL, arguments: commandBuilder.arguments(for: workingRequest, prepared: prepared)),
            onStandardOutput: { chunk in
                if let progress = progressParser.consume(chunk) { onProgress?(progress) }
            }
        )
        try validate(result, tool: "FFmpeg")
        try Task.checkCancellation()
        try await validateEncodedVideo(at: temporaryURL, request: request)
        try await validateDynamicHDRCopy(at: temporaryURL, request: request)
        try Task.checkCancellation()
        // Recheck immediately before replacing in case a source alias appeared while encoding.
        let finalDestinationBlockers = ExportPlan.destinationBlockers(request: request)
        if !finalDestinationBlockers.isEmpty { throw ExportValidationError(blockers: finalDestinationBlockers) }
        if request.configuration.advanced.overwriteExisting,
           FileManager.default.fileExists(atPath: request.destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(request.destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: request.destinationURL)
        }
        return request.destinationURL
    }

    private func validateEncodedVideo(at url: URL, request: ExportRequest) async throws {
        guard case .media = request.operation, request.configuration.mode == .transcode else { return }
        let ffprobeURL = executableURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else {
            throw ExportValidationError(blockers: ["找不到随包 ffprobe，无法核对实际导出位深与色度采样"])
        }
        let probe = try await FFprobeEngine(executableURL: ffprobeURL, runner: runner).probe(url)
        let videoStreams = probe.streams.filter { $0.kind == .video && !$0.isAttachedPicture }
        let plan = ExportPlan(request: request)
        let sourceVideo = request.configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }?.sourceStream ?? request.sourceVideo
        let colorPlan = ColorConversionPlan(settings: request.configuration.color, source: sourceVideo)
        guard !videoStreams.isEmpty else { throw ExportValidationError(blockers: ["导出结果缺少视频轨道"]) }
        for stream in videoStreams {
            guard stream.codecName == request.configuration.video.codec.mediaCodecName,
                  let depth = stream.bitDepth, depth >= (plan.pixelFormat.bitDepth ?? 8),
                  stream.chromaSubsampling == plan.pixelFormat.chromaSubsampling else {
                throw ExportValidationError(blockers: [
                    "编码器实际输出 \(stream.codecName ?? "未知") / \(stream.bitDepth.map { "\($0)-bit" } ?? "未知位深") / \(stream.chromaSubsampling?.displayName ?? "未知采样")，与请求的 \(plan.pixelFormat.displayName) 不符；未替换目标文件"
                ])
            }
            if colorPlan.needsConversion, let expected = colorPlan.output {
                guard stream.colorPrimaries == expected.primaries, stream.colorTransfer == expected.transfer,
                      stream.colorSpace == expected.matrix, VideoColorSpec.range(stream.colorRange) == expected.range else {
                    throw ExportValidationError(blockers: ["实际导出的色彩标签或范围与转换目标不符，未替换目标文件"])
                }
            }
            if (colorPlan.needsConversion || request.configuration.color.discardsDynamicHDR) && stream.hasDynamicHDR {
                throw ExportValidationError(blockers: ["转换结果残留了动态 HDR 标记，未替换目标文件"])
            }
        }
    }

    private func validateDynamicHDRCopy(at url: URL, request: ExportRequest) async throws {
        guard case .media = request.operation, request.configuration.mode == .streamCopy else { return }
        var videos = request.configuration.trackSettings.filter { $0.isIncluded && $0.kind == .video }
        if videos.isEmpty, let source = request.sourceVideo {
            videos = [TrackExportSettings(sourceURL: request.sourceURL, stream: source, sourceDuration: request.sourceDuration)]
        }
        guard videos.contains(where: { $0.sourceStream?.hasDynamicHDR == true }) else { return }
        let probe = try await FFprobeEngine(executableURL: executableURL.deletingLastPathComponent().appendingPathComponent("ffprobe"), runner: runner).probe(url)
        let outputs = probe.streams.filter { $0.kind == .video }
        for (position, track) in videos.enumerated() where track.sourceStream?.hasDynamicHDR == true {
            guard outputs.indices.contains(position), outputs[position].hdrDescription == track.sourceStream?.hdrDescription,
                  outputs[position].dolbyVisionProfile == track.sourceStream?.dolbyVisionProfile,
                  outputs[position].dolbyVisionCompatibilityID == track.sourceStream?.dolbyVisionCompatibilityID else {
                throw ExportValidationError(blockers: ["目标容器没有完整保留动态 HDR 标记，请保持原容器；未替换目标文件"])
            }
            let before = try await videoPacketHash(url: track.resolvedSourceURL(primarySourceURL: request.sourceURL), stream: track.streamIndex)
            let after = try await videoPacketHash(url: url, stream: outputs[position].index)
            guard before == after else { throw ExportValidationError(blockers: ["动态 HDR 视频包的完整性核对未通过，请保持源容器；未替换目标文件"]) }
        }
    }

    private func videoPacketHash(url: URL, stream: Int) async throws -> String {
        let result = try await runner.run(CLICommand(executableURL: executableURL,
            arguments: ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:\(stream)", "-c", "copy", "-f", "streamhash", "-hash", "sha256", "-"]))
        try validate(result, tool: "动态 HDR 完整性核对")
        guard let hash = result.standardOutput.split(separator: "\n").first(where: { $0.contains("SHA256=") }) else {
            throw ExportValidationError(blockers: ["无法读取动态 HDR 视频包校验值"])
        }
        return String(hash.split(separator: "=").last ?? "")
    }
}

struct TrackPreviewRequest: Sendable {
    let primarySourceURL: URL
    let destinationURL: URL
    let tracks: [TrackExportSettings]
    let duration: TimeInterval?
    let subtitleOffset: TimeInterval
}

struct TrackPreviewAsset: Sendable {
    let mediaURL: URL
    let subtitleURL: URL?
}

actor FFmpegTrackPreviewEngine {
    private let executableURL: URL
    private let runner: any CLIProcessRunning
    private let commandBuilder: FFmpegCommandBuilder

    init(
        executableURL: URL,
        runner: any CLIProcessRunning = ProcessRunner(),
        commandBuilder: FFmpegCommandBuilder = FFmpegCommandBuilder()
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.commandBuilder = commandBuilder
    }

    func createPreview(_ request: TrackPreviewRequest) async throws -> TrackPreviewAsset {
        let subtitleURL = request.tracks.contains(where: { $0.kind == .subtitle })
            ? request.destinationURL.deletingPathExtension().appendingPathExtension("srt")
            : nil
        do {
            try await createPlayableMedia(for: request)
            if let subtitleURL {
                let subtitleResult = try await runner.run(
                    CLICommand(
                        executableURL: executableURL,
                        arguments: commandBuilder.previewSubtitleArguments(
                            for: request,
                            destinationURL: subtitleURL
                        )
                    )
                )
                try validate(subtitleResult, tool: "FFmpeg 字幕预览")
            }
            return TrackPreviewAsset(
                mediaURL: request.destinationURL,
                subtitleURL: subtitleURL
            )
        } catch {
            try? FileManager.default.removeItem(at: request.destinationURL)
            if let subtitleURL {
                try? FileManager.default.removeItem(at: subtitleURL)
            }
            throw error
        }
    }

    private func createPlayableMedia(for request: TrackPreviewRequest) async throws {
        let preferredResult = try await runner.run(
            CLICommand(
                executableURL: executableURL,
                arguments: commandBuilder.previewArguments(for: request)
            )
        )
        if preferredResult.succeeded,
           await MediaPlaybackCompatibility.isPlayableVideo(at: request.destinationURL) {
            return
        }

        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: request.destinationURL)

        let compatibilityResult = try await runner.run(
            CLICommand(
                executableURL: executableURL,
                arguments: commandBuilder.previewArguments(
                    for: request,
                    forceCompatibilityTranscode: true
                )
            )
        )
        try validate(compatibilityResult, tool: "FFmpeg 兼容预览")

        guard await MediaPlaybackCompatibility.isPlayableVideo(at: request.destinationURL) else {
            throw MediaEngineError.previewNotPlayable
        }
    }
}

struct FFmpegCommandBuilder: Sendable {
    func arguments(for request: ExportRequest, prepared: ExportPreparedAssets = ExportPreparedAssets()) -> [String] {
        if case let .trackExtraction(track) = request.operation {
            return trackExtractionArguments(for: request, track: track)
        }

        let configuration = request.configuration
        let editing = request.editing
        let effectiveMode = configuration.mode
        let usesComposition = effectiveMode == .transcode && (editing.requiresFilterComposition || editing.simpleTrimRange() != nil)
        let simpleTrimRange = editing.simpleTrimRange()
        let usesOffsetSubtitleInput = abs(configuration.subtitles.timeOffsetSeconds) > 0.000_1
            && configuration.subtitles.mode != .remove
            && configuration.subtitles.mode != .burn
            && !usesComposition
            && prepared.subtitleURLs == nil
        let inputPlan = FFmpegInputPlan(
            primarySourceURL: request.sourceURL,
            tracks: configuration.trackSettings.filter { track in
                guard track.isIncluded else { return false }
                if track.kind == .audio, configuration.audio.codec == .none { return false }
                if track.kind == .attachment, !configuration.includeAttachments { return false }
                if track.kind == .data, !configuration.includeDataStreams { return false }
                return track.kind != .subtitle
                    || (configuration.subtitles.mode != .remove
                        && configuration.subtitles.mode != .burn
                        && !usesComposition && prepared.subtitleURLs == nil)
            },
            subtitleOffset: usesOffsetSubtitleInput ? configuration.subtitles.timeOffsetSeconds : nil,
            includeFallbackSubtitleInput: configuration.trackSettings.isEmpty && usesOffsetSubtitleInput,
            additionalURLs: editing.referencedURLs
        )
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-progress", "pipe:1", "-nostats",
            configuration.advanced.overwriteExisting ? "-y" : "-n"
        ]

        if effectiveMode == .transcode, configuration.advanced.hardwareDecoding {
            arguments += ["-hwaccel", "videotoolbox"]
        }

        let inputSeek = effectiveMode == .streamCopy ? simpleTrimRange?.start : nil
        arguments += inputPlan.arguments(inputSeek: inputSeek)
        let subtitleStartIndex = inputPlan.entries.count
        for url in prepared.subtitleURLs ?? [] { arguments += ["-i", url.path] }
        let chapterIndex = inputPlan.entries.count + (prepared.subtitleURLs?.count ?? 0)
        if let url = prepared.chapterURL { arguments += ["-f", "ffmetadata", "-i", url.path] }

        if effectiveMode == .transcode,
           !usesComposition,
           let simpleTrimRange,
           simpleTrimRange.start > 0 {
            arguments += ["-ss", formatTime(simpleTrimRange.start)]
        }
        if !usesComposition, let simpleTrimRange, simpleTrimRange.duration > 0 {
            arguments += ["-t", formatTime(simpleTrimRange.duration)]
        }

        if usesComposition {
            arguments += compositionArguments(for: request, inputPlan: inputPlan, prepared: prepared)
        } else {
            var mappingConfiguration = configuration
            if prepared.subtitleURLs != nil { mappingConfiguration.subtitles.mode = .remove }
            arguments += mappingArguments(
                configuration: mappingConfiguration,
                inputPlan: inputPlan,
                usesOffsetSubtitleInput: usesOffsetSubtitleInput
            )
        }
        for index in (prepared.subtitleURLs ?? []).indices {
            arguments += ["-map", "\(subtitleStartIndex + index):s:0"]
        }

        switch effectiveMode {
        case .streamCopy:
            arguments += ["-c", "copy"]
            if configuration.audio.codec == .none { arguments.append("-an") }
            arguments += subtitleArguments(
                configuration: configuration,
                usesComposition: usesComposition,
                hasPreparedSubtitles: prepared.subtitleURLs != nil
            )
        case .transcode:
            arguments += videoArguments(for: request, includesSimpleFilters: !usesComposition, prepared: prepared)
            arguments += audioArguments(for: request, includesSimpleFilters: !usesComposition)
            arguments += subtitleArguments(
                configuration: configuration,
                usesComposition: usesComposition,
                hasPreparedSubtitles: prepared.subtitleURLs != nil
            )
        }

        if let range = request.previewOutputRange {
            arguments += ["-ss", decimal(range.start), "-t", decimal(range.duration)]
        }
        arguments += containerArguments(configuration: configuration, changesSourceTiming: editing.changesSourceTimingForExport)
        if prepared.chapterURL != nil { arguments += ["-map_chapters", String(chapterIndex)] }
        arguments += playbackTagArguments(
            configuration: configuration,
            effectiveMode: effectiveMode
        )
        arguments += trackMetadataArguments(
            configuration: configuration,
            usesComposition: usesComposition,
            hasPreparedSubtitles: prepared.subtitleURLs != nil
        )
        arguments += metadataArguments(configuration: configuration)
        if effectiveMode == .transcode {
            arguments += colorPlan(for: request).outputArguments
        }

        if !usesComposition,
           simpleTrimRange == nil,
           configuration.trackSettings.contains(where: {
               $0.isIncluded
                   && $0.resolvedSourceURL(primarySourceURL: request.sourceURL).standardizedFileURL
                       != request.sourceURL.standardizedFileURL
           }),
           let duration = editing.trimmedDuration ?? request.sourceDuration,
           duration > 0 {
            arguments += ["-t", formatTime(duration)]
        }

        if configuration.advanced.threadCount > 0 {
            arguments += ["-threads", String(configuration.advanced.threadCount)]
        }

        arguments += splitAdditionalArguments(configuration.advanced.additionalArguments)
        arguments.append(request.destinationURL.path)
        return arguments
    }

    func commandPreview(for request: ExportRequest, executableName: String = "ffmpeg") -> String {
        ([executableName] + arguments(for: request))
            .map(shellQuoted)
            .joined(separator: " ")
    }

    func previewArguments(
        for request: TrackPreviewRequest,
        forceCompatibilityTranscode: Bool = false
    ) -> [String] {
        let inputPlan = FFmpegInputPlan(
            primarySourceURL: request.primarySourceURL,
            tracks: request.tracks.filter { $0.kind != .subtitle },
            subtitleOffset: nil,
            includeFallbackSubtitleInput: false
        )
        var result = ["-hide_banner", "-nostdin", "-y"]
        result += inputPlan.arguments(inputSeek: nil)

        for track in request.tracks where track.kind != .subtitle {
            result += ["-map", "\(inputPlan.inputIndex(for: track)):\(track.streamIndex)"]
        }
        result += previewVideoArguments(
            for: request.tracks.first { $0.kind == .video },
            forceCompatibilityTranscode: forceCompatibilityTranscode
        )
        result += previewAudioArguments(
            for: request.tracks.first { $0.kind == .audio },
            forceCompatibilityTranscode: forceCompatibilityTranscode
        )
        result += ["-sn"]
        result += ["-map_metadata", "0", "-map_chapters", "0"]

        for kind in [MediaStreamKind.video, .audio] {
            guard let track = request.tracks.first(where: { $0.kind == kind }) else { continue }
            let specifier = kind == .video ? "v" : "a"
            if !track.title.isEmpty {
                result += ["-metadata:s:\(specifier):0", "title=\(track.title)"]
                result += ["-metadata:s:\(specifier):0", "handler_name=\(track.title)"]
            }
            if !track.language.isEmpty {
                result += ["-metadata:s:\(specifier):0", "language=\(track.language)"]
            }
            result += ["-disposition:\(specifier):0", "default"]
        }
        if let duration = request.duration, duration > 0 {
            result += ["-t", formatTime(duration)]
        }
        result += ["-movflags", "+faststart", request.destinationURL.path]
        return result
    }

    func previewSubtitleArguments(
        for request: TrackPreviewRequest,
        destinationURL: URL
    ) -> [String] {
        guard let track = request.tracks.first(where: { $0.kind == .subtitle }) else {
            return []
        }
        let sourceURL = track.resolvedSourceURL(primarySourceURL: request.primarySourceURL)
        var result = ["-hide_banner", "-nostdin", "-y"]
        if abs(request.subtitleOffset) > 0.000_1 {
            result += ["-itsoffset", decimal(request.subtitleOffset)]
        }
        result += [
            "-i", sourceURL.path,
            "-map", "0:\(track.streamIndex)",
            "-c:s", "srt"
        ]
        if let duration = request.duration, duration > 0 {
            result += ["-t", formatTime(duration)]
        }
        result.append(destinationURL.path)
        return result
    }

    private func previewVideoArguments(
        for track: TrackExportSettings?,
        forceCompatibilityTranscode: Bool
    ) -> [String] {
        guard let track else { return ["-vn"] }
        let nativeCodecs = Set(["h264", "hevc", "h265", "mpeg4", "prores", "mjpeg"])
        if (forceCompatibilityTranscode || !nativeCodecs.contains(track.codecName?.lowercased() ?? "")),
           (track.sourceStream?.bitDepth ?? 8) > 8 {
            return ["-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-profile:v", "main10",
                    "-b:v", "16000k", "-vf", "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,format=p010le",
                    "-pix_fmt", "p010le", "-tag:v", "hvc1"]
        }
        if forceCompatibilityTranscode {
            return [
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-profile:v", "high",
                "-b:v", "6000k",
                "-vf",
                "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,format=yuv420p",
                "-pix_fmt", "yuv420p",
                "-tag:v", "avc1"
            ]
        }

        switch track.codecName?.lowercased() {
        case "h264":
            return ["-c:v", "copy", "-tag:v", "avc1"]
        case "hevc", "h265":
            return ["-c:v", "copy", "-tag:v", "hvc1"]
        case "mpeg4", "prores", "mjpeg":
            return ["-c:v", "copy"]
        default:
            return [
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "1",
                "-b:v", "6000k",
                "-pix_fmt", "yuv420p",
                "-tag:v", "avc1"
            ]
        }
    }

    private func previewAudioArguments(
        for track: TrackExportSettings?,
        forceCompatibilityTranscode: Bool
    ) -> [String] {
        guard let track else { return ["-an"] }
        if forceCompatibilityTranscode {
            return ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
        }
        let copyCompatibleCodecs = Set(["aac", "alac", "mp3", "ac3", "eac3"])
        if let codec = track.codecName?.lowercased(), copyCompatibleCodecs.contains(codec) {
            return ["-c:a", "copy"]
        }
        return ["-c:a", "aac", "-b:a", "192k"]
    }

    private func trackExtractionArguments(
        for request: ExportRequest,
        track: TrackExportSettings
    ) -> [String] {
        let sourceURL = track.resolvedSourceURL(primarySourceURL: request.sourceURL)
        var result = [
            "-hide_banner",
            "-nostdin",
            "-progress", "pipe:1", "-nostats",
            request.configuration.advanced.overwriteExisting ? "-y" : "-n",
            "-i", sourceURL.path,
            "-map", "0:\(track.streamIndex)",
            "-map_metadata", "-1",
            "-map_chapters", "-1"
        ]

        if track.kind == .subtitle {
            switch request.destinationURL.pathExtension.lowercased() {
            case "srt": result += ["-c:s", "srt"]
            case "ass", "ssa": result += ["-c:s", "ass"]
            case "vtt": result += ["-c:s", "webvtt"]
            default: result += ["-c", "copy"]
            }
        } else {
            result += ["-c", "copy"]
        }

        let specifier: String
        switch track.kind {
        case .video: specifier = "v"
        case .audio: specifier = "a"
        case .subtitle: specifier = "s"
        default: specifier = ""
        }
        if !specifier.isEmpty {
            if !track.title.isEmpty {
                result += ["-metadata:s:\(specifier):0", "title=\(track.title)"]
                if ["mov", "mp4", "m4a"].contains(request.destinationURL.pathExtension.lowercased()) {
                    result += ["-metadata:s:\(specifier):0", "handler_name=\(track.title)"]
                }
            }
            if !track.language.isEmpty {
                result += ["-metadata:s:\(specifier):0", "language=\(track.language)"]
            }
            result += ["-disposition:\(specifier):0", track.isDefault ? "default" : "0"]
        }
        if ["mov", "mp4", "m4a"].contains(request.destinationURL.pathExtension.lowercased()) {
            if track.kind == .video,
               let tag = quickTimeVideoTag(for: track.codecName) {
                result += ["-tag:v:0", tag]
            }
            result += ["-movflags", "+faststart"]
        }
        result.append(request.destinationURL.path)
        return result
    }

    private func mappingArguments(
        configuration: ExportConfiguration,
        inputPlan: FFmpegInputPlan,
        usesOffsetSubtitleInput: Bool
    ) -> [String] {
        var result: [String] = []

        if !configuration.trackSettings.isEmpty {
            let includedTracks = configuration.trackSettings
                .filter { track in
                    guard track.isIncluded else { return false }
                    if track.kind == .audio, configuration.audio.codec == .none { return false }
                    if track.kind == .attachment || track.kind == .data { return false }
                    if track.kind == .subtitle {
                        return configuration.subtitles.mode != .remove
                            && configuration.subtitles.mode != .burn
                    }
                    return true
                }

            for track in includedTracks {
                let inputIndex = inputPlan.inputIndex(for: track)
                result += ["-map", "\(inputIndex):\(track.streamIndex)?"]
            }
            result += auxiliaryMappingArguments(configuration: configuration, inputPlan: inputPlan)
        } else if usesOffsetSubtitleInput {
            let subtitleInputIndex = inputPlan.fallbackSubtitleInputIndex ?? 1
            result += [
                "-map", "0:v?",
                "-map", "0:a?",
                "-map", "\(subtitleInputIndex):s?"
            ]
            if configuration.streamSelection == .all, configuration.includeAttachments {
                result += ["-map", "0:t?"]
            }
            if configuration.streamSelection == .all, configuration.includeDataStreams {
                result += ["-map", "0:d?"]
            }
        } else if configuration.streamSelection == .all {
            result += ["-map", "0"]
        } else {
            result += ["-map", "0:v:0?", "-map", "0:a:0?"]
            if configuration.subtitles.mode != .remove, configuration.subtitles.mode != .burn {
                result += ["-map", "0:s?"]
            }
        }

        if configuration.trackSettings.isEmpty,
           configuration.streamSelection == .all,
           !configuration.includeAttachments {
            result += ["-map", "-0:t?"]
        }
        if !configuration.includeDataStreams {
            result.append("-dn")
        }
        return result
    }

    private func auxiliaryMappingArguments(configuration: ExportConfiguration, inputPlan: FFmpegInputPlan) -> [String] {
        var result: [String] = []
        for (kind, enabled, specifier) in [(MediaStreamKind.attachment, configuration.includeAttachments, "t"),
                                            (.data, configuration.includeDataStreams, "d")] where enabled {
            let tracks = configuration.trackSettings.filter { $0.kind == kind }
            if tracks.isEmpty {
                result += ["-map", "0:\(specifier)?"]
            } else {
                for track in tracks where track.isIncluded {
                    result += ["-map", "\(inputPlan.inputIndex(for: track)):\(track.streamIndex)?"]
                }
            }
        }
        return result
    }

    private func compositionArguments(
        for request: ExportRequest,
        inputPlan: FFmpegInputPlan,
        prepared: ExportPreparedAssets
    ) -> [String] {
        if request.editing.requiresRenderedPreview { return advancedCompositionArguments(for: request, inputPlan: inputPlan, prepared: prepared) }
        let clips = request.editing.clips
        guard !clips.isEmpty else { return [] }

        let configuration = request.configuration
        let videoInput = selectedVideoInput(configuration: configuration, inputPlan: inputPlan)
        let audioInputs = selectedAudioInputs(configuration: configuration, inputPlan: inputPlan)
        let clipCount = clips.count
        let canvas = compositionCanvasDimensions(for: request)
        var graph: [String] = []

        let videoSources: [String]
        if clipCount == 1 {
            videoSources = [videoInput]
        } else {
            videoSources = clips.indices.map { "[vsource\($0)]" }
            graph.append("\(videoInput)split=\(clipCount)\(videoSources.joined())")
        }

        for (index, clip) in clips.enumerated() {
            let chain = clipVideoFilters(
                clip,
                request: request,
                canvas: canvas,
                prepared: prepared
            )
            graph.append("\(videoSources[index])\(chain.joined(separator: ","))[vclip\(index)]")
        }

        for (audioIndex, input) in audioInputs.enumerated() {
            let sources: [String]
            if clipCount == 1 {
                sources = [input]
            } else {
                sources = clips.indices.map { "[asource\(audioIndex)_\($0)]" }
                graph.append("\(input)asplit=\(clipCount)\(sources.joined())")
            }

            for (clipIndex, clip) in clips.enumerated() {
                let filters = clipAudioFilters(clip)
                graph.append(
                    "\(sources[clipIndex])\(filters.joined(separator: ","))[aclip\(audioIndex)_\(clipIndex)]"
                )
            }
        }

        var concatInputs = ""
        for clipIndex in clips.indices {
            concatInputs += "[vclip\(clipIndex)]"
            for audioIndex in audioInputs.indices {
                concatInputs += "[aclip\(audioIndex)_\(clipIndex)]"
            }
        }

        let normalizeAudio = configuration.audio.normalizeLoudness
            && configuration.audio.codec != .none
            && configuration.audio.codec != .copy
        let audioConcatOutputs = audioInputs.indices.map {
            normalizeAudio ? "[aconcat\($0)]" : "[aout\($0)]"
        }.joined()
        let concatVideo = prepared.burnSubtitleURL == nil ? "vout" : "vconcat"
        graph.append("\(concatInputs)concat=n=\(clipCount):v=1:a=\(audioInputs.count)[\(concatVideo)]\(audioConcatOutputs)")
        if let burnURL = prepared.burnSubtitleURL {
            graph.append("[vconcat]subtitles=filename='\(escapeFilterPath(burnURL.path))'[vout]")
        }

        if normalizeAudio {
            for audioIndex in audioInputs.indices {
                graph.append(
                    "[aconcat\(audioIndex)]loudnorm=I=\(decimal(configuration.audio.targetLoudnessLUFS)):TP=-1.5:LRA=11[aout\(audioIndex)]"
                )
            }
        }

        var result = ["-filter_complex", graph.joined(separator: ";"), "-map", "[vout]"]
        for audioIndex in audioInputs.indices {
            result += ["-map", "[aout\(audioIndex)]"]
        }
        result += auxiliaryMappingArguments(configuration: configuration, inputPlan: inputPlan)
        if !configuration.includeDataStreams {
            result.append("-dn")
        }
        return result
    }

    private func advancedCompositionArguments(for request: ExportRequest, inputPlan: FFmpegInputPlan, prepared: ExportPreparedAssets) -> [String] {
        let edit = request.editing, config = request.configuration, clips = edit.clips
        guard !clips.isEmpty, let canvas = compositionCanvasDimensions(for: request) else { return [] }
        let fps = edit.compositionFrameRate(configuration: config, source: request.sourceVideo)
        let primaryVideo = selectedVideoInput(configuration: config, inputPlan: inputPlan)
        let primaryAudio = selectedAudioInputs(configuration: config, inputPlan: inputPlan)
        let audibleLayers = edit.overlayClips.filter { $0.audioGain > 0 && !$0.media.audio.isEmpty }
        let hasExtraAudio = clips.contains { !($0.media?.audio ?? []).isEmpty } || !audibleLayers.isEmpty
        let audioCount = config.audio.codec == .none ? 0 : max(primaryAudio.count, hasExtraAudio ? 1 : 0)
        var graph: [String] = []
        var connections: [(input: String, output: String, audio: Bool)] = []
        for (i, clip) in clips.enumerated() {
            let input = clip.sourceURL.map { "[\(inputPlan.inputIndex(for: $0)):\(clip.media?.video?.index ?? 0)]" } ?? primaryVideo
            connections.append((input, "[vs\(i)]", false))
            for a in 0..<audioCount {
                let audio: String?
                if let source = clip.sourceURL {
                    let tracks = clip.media?.audio ?? []
                    audio = tracks.indices.contains(a) ? "[\(inputPlan.inputIndex(for: source)):\(tracks[a].index)]" : nil
                } else { audio = primaryAudio.indices.contains(a) ? primaryAudio[a] : nil }
                if let audio { connections.append((audio, "[as\(a)_\(i)]", true)) }
                else { graph.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(decimal(clip.sourceRange.end))[as\(a)_\(i)]") }
            }
        }
        for (i, layer) in edit.overlayClips.enumerated() {
            let input = inputPlan.inputIndex(for: layer.sourceURL)
            if let video = layer.media.video { connections.append(("[\(input):\(video.index)]", "[ls\(i)]", false)) }
            if audioCount > 0, layer.audioGain > 0, let audio = layer.media.audio.first { connections.append(("[\(input):\(audio.index)]", "[las\(i)]", true)) }
        }
        let groups = Dictionary(grouping: connections, by: \.input)
        for input in groups.keys.sorted() {
            let group = groups[input]!
            graph.append(input + (group.count > 1 ? "\(group[0].audio ? "asplit" : "split")=\(group.count)" : (group[0].audio ? "anull" : "null")) + group.map(\.output).joined())
        }
        for (i, clip) in clips.enumerated() {
            var filters = clipVideoFilters(clip, request: request, canvas: canvas, prepared: prepared)
            filters += ["fps=\(decimal(fps))", "format=yuv444p16le", "settb=AVTB", "setpts=PTS-STARTPTS"]
            if let frames = clip.keyframes, !frames.isEmpty {
                let z = VisualKeyframe.expression(frames, key: \.scale, variable: "on/\(decimal(fps))")
                let x = VisualKeyframe.expression(frames, key: \.x, variable: "on/\(decimal(fps))")
                let y = VisualKeyframe.expression(frames, key: \.y, variable: "on/\(decimal(fps))")
                filters.append("zoompan=z='\(z)':x='max(0,min(iw-iw/zoom,iw*(\(x))-iw/zoom/2))':y='max(0,min(ih-ih/zoom,ih*(\(y))-ih/zoom/2))':d=1:s=\(canvas.width)x\(canvas.height):fps=\(decimal(fps))")
                let alpha = VisualKeyframe.expression(frames, key: \.opacity, variable: "T")
                filters += ["format=gbrp16le", "geq=r='r(X,Y)*(\(alpha))':g='g(X,Y)*(\(alpha))':b='b(X,Y)*(\(alpha))'", "format=yuv444p16le", "settb=AVTB"]
            }
            // Ensure all cuts have their declared length, including short or empty audio streams.
            filters += ["tpad=stop_mode=clone:stop_duration=1", "trim=duration=\(decimal(clip.outputDuration))"]
            graph.append("[vs\(i)]" + filters.joined(separator: ",") + "[vc\(i)]")
            for a in 0..<audioCount {
                let filters = clipAudioFilters(clip) + ["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=stereo", "apad", "atrim=duration=\(decimal(clip.outputDuration))", "asetpts=PTS-STARTPTS"]
                graph.append("[as\(a)_\(i)]" + filters.joined(separator: ",") + "[ac\(a)_\(i)]")
            }
        }
        var video = "[vc0]", audio = (0..<audioCount).map { "[ac\($0)_0]" }
        var duration = clips[0].outputDuration
        for i in clips.indices.dropFirst() {
            let overlap = edit.transitionDuration(at: i), nextVideo = "[joinedv\(i)]"
            if overlap > 0 {
                graph.append("\(video)[vc\(i)]xfade=transition=\(clips[i].transition?.style ?? "fade"):duration=\(decimal(overlap)):offset=\(decimal(duration - overlap))\(nextVideo)")
            } else { graph.append("\(video)[vc\(i)]concat=n=2:v=1:a=0,settb=AVTB\(nextVideo)") }
            video = nextVideo
            for a in 0..<audioCount {
                let next = "[joineda\(a)_\(i)]"
                graph.append("\(audio[a])[ac\(a)_\(i)]" + (overlap > 0 ? "acrossfade=d=\(decimal(overlap)):c1=tri:c2=tri" : "concat=n=2:v=0:a=1") + next)
                audio[a] = next
            }
            duration += clips[i].outputDuration - overlap
        }
        for (i, layer) in edit.overlayClips.enumerated() {
            let start = decimal(layer.startTime), end = decimal(min(edit.outputDuration, layer.startTime + layer.sourceRange.duration))
            if let stream = layer.media.video {
                var layerRequest = request; layerRequest.sourceVideo = stream
                layerRequest.configuration.trackSettings = []
                let color = colorPlan(for: layerRequest).filters(lutFilters: prepared.lutFilters)
                let width = max(2, Int(Double(canvas.width) * layer.pose.scale) / 2 * 2)
                var filters = ["trim=start=\(decimal(layer.sourceRange.start)):duration=\(decimal(layer.sourceRange.duration))", "setpts=PTS-STARTPTS"] + color
                filters += ["scale=\(width):-2", "setsar=1", "format=gbrap16le"]
                if layer.keyframes.isEmpty { filters.append("colorchannelmixer=aa=\(decimal(layer.pose.opacity))") }
                else {
                    let alpha = VisualKeyframe.expression(layer.keyframes, key: \.opacity, variable: "T")
                    filters.append("geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*(\(alpha))'")
                }
                filters.append("setpts=PTS+\(start)/TB")
                graph.append("[ls\(i)]" + filters.joined(separator: ",") + "[lv\(i)]")
                let x = layer.keyframes.isEmpty ? decimal(layer.pose.x) : VisualKeyframe.expression(layer.keyframes, key: \.x, variable: "t-\(start)")
                let y = layer.keyframes.isEmpty ? decimal(layer.pose.y) : VisualKeyframe.expression(layer.keyframes, key: \.y, variable: "t-\(start)")
                let output = "[layered\(i)]"
                graph.append("\(video)[lv\(i)]overlay=x='W*(\(x))-w/2':y='H*(\(y))-h/2':enable='between(t,\(start),\(end))':eof_action=pass:repeatlast=0:format=auto\(output)")
                video = output
            }
            if audioCount > 0, layer.audioGain > 0, !layer.media.audio.isEmpty {
                graph.append("[las\(i)]atrim=start=\(decimal(layer.sourceRange.start)):duration=\(decimal(layer.sourceRange.duration)),asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,volume=\(decimal(layer.audioGain)),adelay=\(Int(layer.startTime * 1000)):all=1[la\(i)]")
                let out = "[mixed\(i)]"
                graph.append("\(audio[0])[la\(i)]amix=inputs=2:duration=first:normalize=0\(out)"); audio[0] = out
            }
        }
        let finalVideoFilter = prepared.burnSubtitleURL.map { "subtitles=filename='\(escapeFilterPath($0.path))'," } ?? ""
        graph.append(video + finalVideoFilter + "trim=duration=\(decimal(edit.outputDuration)),setpts=PTS-STARTPTS[vout]")
        var result = ["-filter_complex", "", "-map", "[vout]"]
        for a in 0..<audioCount {
            let normalize = config.audio.normalizeLoudness ? "loudnorm=I=\(decimal(config.audio.targetLoudnessLUFS)):TP=-1.5:LRA=11," : ""
            graph.append(audio[a] + normalize + "atrim=duration=\(decimal(edit.outputDuration)),asetpts=PTS-STARTPTS[aout\(a)]")
            result += ["-map", "[aout\(a)]"]
        }
        result[1] = graph.joined(separator: ";")
        result += ["-t", decimal(edit.outputDuration)]
        result += auxiliaryMappingArguments(configuration: config, inputPlan: inputPlan)
        return result
    }

    private func selectedVideoInput(
        configuration: ExportConfiguration,
        inputPlan: FFmpegInputPlan
    ) -> String {
        if let track = configuration.trackSettings
            .filter({ $0.kind == .video && $0.isIncluded })
            .first {
            return "[\(inputPlan.inputIndex(for: track)):\(track.streamIndex)]"
        }
        return "[0:v:0]"
    }

    private func selectedAudioInputs(
        configuration: ExportConfiguration,
        inputPlan: FFmpegInputPlan
    ) -> [String] {
        guard configuration.audio.codec != .none else { return [] }
        return configuration.trackSettings
            .filter { $0.kind == .audio && $0.isIncluded }
            .map { "[\(inputPlan.inputIndex(for: $0)):\($0.streamIndex)]" }
    }

    private func clipVideoFilters(
        _ clip: EditSegment,
        request: ExportRequest,
        canvas: (width: Int, height: Int)?,
        prepared: ExportPreparedAssets
    ) -> [String] {
        var filters = [
            "trim=start=\(decimal(clip.sourceRange.start)):duration=\(decimal(clip.sourceRange.duration))"
        ]

        var clipRequest = request
        if let media = clip.media {
            clipRequest.sourceVideo = media.video
            for index in clipRequest.configuration.trackSettings.indices where clipRequest.configuration.trackSettings[index].kind == .video {
                clipRequest.configuration.trackSettings[index].sourceStream = media.video
            }
        }
        filters += colorPlan(for: clipRequest).filters(lutFilters: prepared.lutFilters)
        filters += clip.effects?.filters ?? []
        if let crop = clip.transform.crop {
            filters.append("crop=w='max(2,trunc(iw*\(decimal(crop.width))/2)*2)':h='max(2,trunc(ih*\(decimal(crop.height))/2)*2)':x='trunc(iw*\(decimal(crop.x))/2)*2':y='trunc(ih*\(decimal(crop.y))/2)*2'")
        }

        if clip.sourceURL == nil && request.configuration.subtitles.mode == .burn && prepared.burnSubtitleURL == nil {
            let escapedPath = escapeFilterPath(request.sourceURL.path)
            filters.append(
                "subtitles=filename='\(escapedPath)':si=\(max(0, request.configuration.subtitles.burnStreamIndex))"
            )
        }

        filters.append("setpts=(PTS-STARTPTS)/\(decimal(clip.playbackRate))")

        switch normalizedQuarterTurns(clip.transform.quarterTurnsClockwise) {
        case 1:
            filters.append("transpose=clock")
        case 2:
            filters += ["transpose=clock", "transpose=clock"]
        case 3:
            filters.append("transpose=cclock")
        default:
            break
        }
        if clip.transform.isFlippedHorizontally { filters.append("hflip") }
        if clip.transform.isFlippedVertically { filters.append("vflip") }

        if let canvas {
            let upscalingLimit = request.configuration.video.allowUpscaling
                ? "min(\(canvas.width)/iw,\(canvas.height)/ih)"
                : "min(1,min(\(canvas.width)/iw,\(canvas.height)/ih))"
            let zoom = decimal(min(2, max(0.5, clip.scale)))
            filters.append(
                "scale=w='max(2,trunc(iw*(\(upscalingLimit))*\(zoom)/2)*2)':h='max(2,trunc(ih*(\(upscalingLimit))*\(zoom)/2)*2)':eval=init"
            )
            filters.append(
                "crop=w='min(iw,\(canvas.width))':h='min(ih,\(canvas.height))':x='(iw-ow)/2':y='(ih-oh)/2'"
            )
            filters.append(
                "pad=\(canvas.width):\(canvas.height):'(ow-iw)/2':'(oh-ih)/2':color=black"
            )
            filters.append("setsar=1")
        }
        return filters
    }

    private func clipAudioFilters(_ clip: EditSegment) -> [String] {
        AudioClipProcessing.filters(clip)
    }

    func compositionCanvasDimensions(
        for request: ExportRequest
    ) -> (width: Int, height: Int)? {
        let settings = request.configuration.video
        var dimensions = settings.resolution.dimensions
        if settings.resolution == .custom {
            dimensions = (max(2, settings.customWidth), max(2, settings.customHeight))
        }
        if dimensions == nil,
           let width = request.editing.canvasWidth,
           let height = request.editing.canvasHeight {
            dimensions = (width, height)
            let turns = Set(
                request.editing.clips.map {
                    normalizedQuarterTurns($0.transform.quarterTurnsClockwise)
                }
            )
            if turns.count == 1, let turn = turns.first, turn.isMultiple(of: 2) == false {
                dimensions = (height, width)
            }
        }
        guard let dimensions else { return nil }
        return (
            max(2, dimensions.width - dimensions.width % 2),
            max(2, dimensions.height - dimensions.height % 2)
        )
    }

    private func videoArguments(
        for request: ExportRequest,
        includesSimpleFilters: Bool,
        prepared: ExportPreparedAssets
    ) -> [String] {
        let settings = request.configuration.video
        var result = ["-c:v", settings.codec.ffmpegName]

        switch settings.rateControl {
        case .constantQuality:
            if settings.codec.isHardwareAccelerated {
                result += ["-q:v", String(clamp(settings.quality, lower: 1, upper: 100))]
            } else {
                let maximumCRF = settings.codec == .av1 ? 63 : 51
                let crf = Int((Double(maximumCRF) * (1.0 - Double(settings.quality) / 100.0)).rounded())
                result += ["-crf", String(clamp(crf, lower: 0, upper: maximumCRF))]
            }
        case .averageBitrate:
            result += bitrateArguments(settings: settings, averageKbps: settings.averageBitrateKbps)
        case .targetSize:
            let targetBitrate = targetVideoBitrateKbps(for: request)
            result += bitrateArguments(settings: settings, averageKbps: targetBitrate)
        }

        if settings.codec.supportsSoftwarePreset {
            result += ["-preset", settings.preset.ffmpegValue(for: settings.codec)]
            if let tune = settings.tune.ffmpegValue, settings.codec != .av1 {
                result += ["-tune", tune]
            }
        }

        if settings.codec == .av1, settings.profile == .main {
            result += ["-profile:v", "0"]
        } else if let profile = settings.profile.ffmpegValue {
            result += ["-profile:v", profile]
        }

        var videoFilters = includesSimpleFilters
            ? simpleVideoFilters(request: request, prepared: prepared)
            : []
        if includesSimpleFilters, request.configuration.subtitles.mode == .burn {
            let escapedPath = escapeFilterPath((prepared.burnSubtitleURL ?? request.sourceURL).path)
            videoFilters.append(
                "subtitles=filename='\(escapedPath)':si=\(prepared.burnSubtitleURL == nil ? max(0, request.configuration.subtitles.burnStreamIndex) : 0)"
            )
        }
        if !videoFilters.isEmpty {
            result += ["-vf", videoFilters.joined(separator: ",")]
        }

        let frameRate = settings.frameRate.value
            ?? (settings.frameRate == .custom ? max(1, settings.customFrameRate) : nil)
        if let frameRate {
            result += ["-r", decimal(frameRate)]
        }

        let outputFormat = ExportPlan(request: request).pixelFormat
        // VideoToolbox accepts the semiplanar 10-bit equivalent, not planar yuv420p10le.
        let encoderPixelFormat = settings.codec == .hevcVideoToolbox && outputFormat == .yuv420p10le
            ? "p010le" : outputFormat.rawValue
        result += ["-pix_fmt", encoderPixelFormat]

        if settings.keyframeIntervalSeconds > 0 {
            let sourceRate = request.configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }?.sourceStream?.frameRate
                ?? request.sourceVideo?.frameRate
            if let actualRate = frameRate ?? sourceRate, actualRate.isFinite, actualRate > 0 {
                let interval = max(1, Int((settings.keyframeIntervalSeconds * actualRate).rounded()))
                result += ["-g", String(interval)]
            }
            // A time-based bound also handles variable-frame-rate footage.
            result += ["-force_key_frames", "expr:gte(t,n_forced*\(decimal(settings.keyframeIntervalSeconds)))"]
        }
        result += ["-bf", String(clamp(settings.bFrames, lower: 0, upper: 16))]
        return result
    }

    private func bitrateArguments(settings: VideoExportSettings, averageKbps: Int) -> [String] {
        let average = max(100, averageKbps)
        var result = ["-b:v", "\(average)k"]
        if settings.maximumBitrateKbps > 0 {
            result += ["-maxrate", "\(max(average, settings.maximumBitrateKbps))k"]
        }
        if settings.bufferSizeKbps > 0 {
            result += ["-bufsize", "\(settings.bufferSizeKbps)k"]
        }
        return result
    }

    private func targetVideoBitrateKbps(for request: ExportRequest) -> Int {
        TargetSizeBudget(configuration: request.configuration,
                         duration: request.editing.trimmedDuration ?? request.sourceDuration).videoKbps
    }

    private func simpleVideoFilters(request: ExportRequest, prepared: ExportPreparedAssets) -> [String] {
        let configuration = request.configuration
        let settings = configuration.video
        var filters = colorPlan(for: request).filters(lutFilters: prepared.lutFilters)

        let dimensions = settings.resolution.dimensions
            ?? (settings.resolution == .custom
                ? (max(2, settings.customWidth), max(2, settings.customHeight))
                : nil)
        if let dimensions {
            if settings.allowUpscaling {
                filters.append(
                    "scale=\(dimensions.0):\(dimensions.1):force_original_aspect_ratio=decrease:force_divisible_by=2"
                )
            } else {
                filters.append(
                    "scale=w='min(\(dimensions.0),iw)':h='min(\(dimensions.1),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
                )
            }
        }

        return filters
    }

    private func colorPlan(for request: ExportRequest) -> ColorConversionPlan {
        let source = request.configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }?.sourceStream ?? request.sourceVideo
        return ColorConversionPlan(settings: request.configuration.color, source: source)
    }

    private func audioArguments(
        for request: ExportRequest,
        includesSimpleFilters: Bool
    ) -> [String] {
        let settings = request.configuration.audio
        guard let codec = settings.codec.ffmpegName else { return ["-an"] }

        var result = ["-c:a", codec]
        guard settings.codec != .copy else { return result }

        if settings.codec.usesBitrate {
            result += ["-b:a", "\(max(32, settings.bitrateKbps))k"]
        }
        if settings.sampleRate != .source {
            result += ["-ar", String(settings.sampleRate.rawValue)]
        }
        if settings.channels != .source {
            result += ["-ac", String(settings.channels.rawValue)]
        }

        var filters: [String] = []
        if includesSimpleFilters, settings.normalizeLoudness {
            filters.append("loudnorm=I=\(decimal(settings.targetLoudnessLUFS)):TP=-1.5:LRA=11")
        }
        if !filters.isEmpty {
            result += ["-af", filters.joined(separator: ",")]
        }
        return result
    }

    private func subtitleArguments(
        configuration: ExportConfiguration,
        usesComposition: Bool,
        hasPreparedSubtitles: Bool = false
    ) -> [String] {
        if hasPreparedSubtitles {
            return ["-c:s", configuration.container == .mkv ? "ass" : subtitleCodec(for: configuration.container)]
        }
        if usesComposition, configuration.subtitles.mode != .burn {
            return ["-sn"]
        }

        return switch configuration.subtitles.mode {
        case .copy:
            ["-c:s", "copy"]
        case .convert:
            ["-c:s", subtitleCodec(for: configuration.container)]
        case .burn, .remove:
            ["-sn"]
        }
    }

    private func subtitleCodec(for container: MediaContainer) -> String {
        switch container {
        case .mp4, .mov: "mov_text"
        case .webm: "webvtt"
        case .mkv: "srt"
        }
    }

    private func containerArguments(configuration: ExportConfiguration, changesSourceTiming: Bool) -> [String] {
        var result: [String] = []
        result += configuration.containerOptions.preserveMetadata
            ? ["-map_metadata", "0"]
            : ["-map_metadata", "-1"]
        result += configuration.containerOptions.preserveChapters && !changesSourceTiming
            ? ["-map_chapters", "0"]
            : ["-map_chapters", "-1"]

        if configuration.containerOptions.fastStart, configuration.container.supportsFastStart {
            result += ["-movflags", "+faststart"]
        }
        if configuration.containerOptions.normalizeTimestamps {
            result.append("-start_at_zero")
        }
        if configuration.mode == .transcode {
            // Encoder reorder / priming DTS can legitimately be negative. Shifting all
            // packets to make DTS zero moves the first displayed video frame away from
            // the edited subtitle and chapter clock. These containers support this delay.
            result += ["-avoid_negative_ts", "disabled"]
        } else if configuration.containerOptions.preventNegativeTimestamps {
            result += ["-avoid_negative_ts", "make_zero"]
        }
        return result
    }

    private func playbackTagArguments(
        configuration: ExportConfiguration,
        effectiveMode: ExportMode
    ) -> [String] {
        guard configuration.container == .mp4 || configuration.container == .mov else {
            return []
        }

        if effectiveMode == .transcode {
            switch configuration.video.codec {
            case .h264VideoToolbox, .h264:
                return ["-tag:v", "avc1"]
            case .hevcVideoToolbox, .hevc:
                return ["-tag:v", "hvc1"]
            case .av1, .proRes:
                return []
            }
        }

        return configuration.trackSettings
            .filter { $0.kind == .video && $0.isIncluded }
            .enumerated()
            .flatMap { outputIndex, track -> [String] in
                guard let tag = quickTimeVideoTag(for: track.codecName) else { return [] }
                return ["-tag:v:\(outputIndex)", tag]
            }
    }

    private func quickTimeVideoTag(for codecName: String?) -> String? {
        switch codecName?.lowercased() {
        case "h264": "avc1"
        case "hevc", "h265": "hvc1"
        default: nil
        }
    }

    private func trackMetadataArguments(
        configuration: ExportConfiguration,
        usesComposition: Bool,
        hasPreparedSubtitles: Bool = false
    ) -> [String] {
        guard !configuration.trackSettings.isEmpty else { return [] }
        var result: [String] = []

        for kind in [MediaStreamKind.video, .audio, .subtitle] {
            if kind == .audio, configuration.audio.codec == .none {
                continue
            }
            if kind == .subtitle,
               configuration.subtitles.mode == .remove
                || configuration.subtitles.mode == .burn
                || (usesComposition && !hasPreparedSubtitles) {
                continue
            }

            var tracks = configuration.trackSettings
                .filter { $0.kind == kind && $0.isIncluded }
            if usesComposition, kind == .video {
                tracks = Array(tracks.prefix(1))
            }
            let specifier: String
            switch kind {
            case .video: specifier = "v"
            case .audio: specifier = "a"
            case .subtitle: specifier = "s"
            default: continue
            }

            for (outputIndex, track) in tracks.enumerated() {
                if !track.title.isEmpty {
                    result += ["-metadata:s:\(specifier):\(outputIndex)", "title=\(track.title)"]
                    if configuration.container == .mp4 || configuration.container == .mov {
                        result += [
                            "-metadata:s:\(specifier):\(outputIndex)",
                            "handler_name=\(track.title)"
                        ]
                    }
                }
                if !track.language.isEmpty {
                    result += ["-metadata:s:\(specifier):\(outputIndex)", "language=\(track.language)"]
                }
                result += [
                    "-disposition:\(specifier):\(outputIndex)",
                    track.isDefault ? "default" : "0"
                ]
            }
        }
        return result
    }

    private func metadataArguments(configuration: ExportConfiguration) -> [String] {
        configuration.metadataEntries.flatMap { entry -> [String] in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return [] }
            return ["-metadata", "\(key)=\(entry.value)"]
        }
    }

    private func normalizedQuarterTurns(_ value: Int) -> Int {
        ((value % 4) + 4) % 4
    }

    private func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(upper, max(lower, value))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        decimal(max(0, seconds))
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func escapeFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func splitAdditionalArguments(_ input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:=+-"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct FFmpegInputPlan {
    struct Entry {
        let sourceURL: URL
        let subtitleOffset: TimeInterval?
    }

    let entries: [Entry]
    let fallbackSubtitleInputIndex: Int?
    private let trackInputIndices: [String: Int]

    init(
        primarySourceURL: URL,
        tracks: [TrackExportSettings],
        subtitleOffset: TimeInterval?,
        includeFallbackSubtitleInput: Bool,
        additionalURLs: [URL] = []
    ) {
        var plannedEntries = [Entry(sourceURL: primarySourceURL, subtitleOffset: nil)]
        var indicesByKey = [Self.key(for: primarySourceURL, subtitleOffset: nil): 0]
        var indicesByTrack: [String: Int] = [:]

        for track in tracks {
            let sourceURL = track.resolvedSourceURL(primarySourceURL: primarySourceURL)
            let offset = track.kind == .subtitle ? subtitleOffset : nil
            let key = Self.key(for: sourceURL, subtitleOffset: offset)
            let inputIndex: Int
            if let existingIndex = indicesByKey[key] {
                inputIndex = existingIndex
            } else {
                inputIndex = plannedEntries.count
                plannedEntries.append(Entry(sourceURL: sourceURL, subtitleOffset: offset))
                indicesByKey[key] = inputIndex
            }
            indicesByTrack[track.id] = inputIndex
        }
        for sourceURL in additionalURLs {
            let key = Self.key(for: sourceURL, subtitleOffset: nil)
            if indicesByKey[key] == nil {
                indicesByKey[key] = plannedEntries.count
                plannedEntries.append(Entry(sourceURL: sourceURL, subtitleOffset: nil))
            }
        }

        var fallbackIndex: Int?
        if includeFallbackSubtitleInput, let subtitleOffset {
            let key = Self.key(for: primarySourceURL, subtitleOffset: subtitleOffset)
            if let existingIndex = indicesByKey[key] {
                fallbackIndex = existingIndex
            } else {
                fallbackIndex = plannedEntries.count
                plannedEntries.append(Entry(sourceURL: primarySourceURL, subtitleOffset: subtitleOffset))
            }
        }

        entries = plannedEntries
        trackInputIndices = indicesByTrack
        fallbackSubtitleInputIndex = fallbackIndex
    }

    func inputIndex(for track: TrackExportSettings) -> Int {
        trackInputIndices[track.id] ?? 0
    }
    func inputIndex(for url: URL) -> Int {
        entries.firstIndex { $0.sourceURL.standardizedFileURL == url.standardizedFileURL && $0.subtitleOffset == nil } ?? 0
    }

    func arguments(inputSeek: TimeInterval?) -> [String] {
        entries.flatMap { entry in
            var result: [String] = []
            if let inputSeek, inputSeek > 0 {
                result += ["-ss", Self.decimal(inputSeek)]
            }
            if let offset = entry.subtitleOffset, abs(offset) > 0.000_1 {
                result += ["-itsoffset", Self.decimal(offset)]
            }
            result += ["-i", entry.sourceURL.path]
            return result
        }
    }

    private static func key(for sourceURL: URL, subtitleOffset: TimeInterval?) -> String {
        let offset = subtitleOffset.map(decimal) ?? "none"
        return "\(sourceURL.standardizedFileURL.path)::\(offset)"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private func ensureDestinationDoesNotExist(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw MediaEngineError.destinationAlreadyExists(url)
    }
}

private func validate(_ result: CLIResult, tool: String) throws {
    guard result.succeeded else {
        let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
        throw MediaEngineError.commandFailed(
            tool: tool,
            status: result.terminationStatus,
            message: message
        )
    }
}

private struct FFprobePayload: Decodable {
    struct Format: Decodable {
        let formatName: String?
        let duration: String?
        let size: String?
        let bitRate: String?
        let tags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case duration
            case size
            case bitRate = "bit_rate"
            case tags
        }
    }

    struct Stream: Decodable {
        struct Tags: Decodable {
            let values: [String: String]
            var language: String? { values["language"] }
            var title: String? { values["title"] }
            var handlerName: String? { values["handler_name"] }
            init(from decoder: Decoder) throws { values = try decoder.singleValueContainer().decode([String: String].self) }
        }

        struct Disposition: Decodable {
            let isDefault: Int?
            let attachedPicture: Int?

            enum CodingKeys: String, CodingKey {
                case isDefault = "default"
                case attachedPicture = "attached_pic"
            }
        }

        struct SideData: Decodable {
            let type: String?
            let doviProfile: Int?
            let doviCompatibilityID: Int?

            enum CodingKeys: String, CodingKey {
                case type = "side_data_type"
                case doviProfile = "dv_profile"
                case doviCompatibilityID = "dv_bl_signal_compatibility_id"
            }
        }

        let index: Int
        let codecName: String?
        let codecProfile: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let averageFrameRate: String?
        let sampleRate: String?
        let channels: Int?
        let bitRate: String?
        let pixelFormat: String?
        let bitsPerRawSample: String?
        let colorSpace: String?
        let colorTransfer: String?
        let colorPrimaries: String?
        let colorRange: String?
        let chromaLocation: String?
        let tags: Tags?
        let disposition: Disposition?
        let sideDataList: [SideData]?

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case codecProfile = "profile"
            case codecType = "codec_type"
            case width
            case height
            case averageFrameRate = "avg_frame_rate"
            case sampleRate = "sample_rate"
            case channels
            case bitRate = "bit_rate"
            case pixelFormat = "pix_fmt"
            case bitsPerRawSample = "bits_per_raw_sample"
            case colorSpace = "color_space"
            case colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries"
            case colorRange = "color_range"
            case chromaLocation = "chroma_location"
            case tags
            case disposition
            case sideDataList = "side_data_list"
        }
    }

    struct Chapter: Decodable {
        struct Tags: Decodable {
            let title: String?
        }

        let id: Int
        let startTime: String?
        let endTime: String?
        let tags: Tags?

        enum CodingKeys: String, CodingKey {
            case id
            case startTime = "start_time"
            case endTime = "end_time"
            case tags
        }
    }

    let format: Format?
    let streams: [Stream]
    let chapters: [Chapter]?
    struct Frame: Decodable {
        let streamIndex: Int?
        let sideDataList: [Stream.SideData]?
        enum CodingKeys: String, CodingKey { case streamIndex = "stream_index", sideDataList = "side_data_list" }
    }
    let frames: [Frame]?

    func mediaProbe(sourceURL: URL) -> MediaProbe {
        MediaProbe(
            sourceURL: sourceURL,
            formatName: format?.formatName,
            duration: format?.duration.flatMap(TimeInterval.init),
            sizeInBytes: format?.size.flatMap(Int64.init),
            streams: streams.map { stream in
                var result = MediaStream(
                    index: stream.index,
                    kind: MediaStreamKind(rawValue: stream.codecType ?? "") ?? .unknown,
                    codecName: stream.codecName,
                    codecProfile: stream.codecProfile,
                    width: stream.width,
                    height: stream.height,
                    averageFrameRate: stream.averageFrameRate,
                    sampleRate: stream.sampleRate.flatMap(Int.init),
                    channels: stream.channels,
                    language: stream.tags?.language,
                    title: preferredTrackTitle(from: stream.tags),
                    isDefault: stream.disposition?.isDefault == 1,
                    bitRate: stream.bitRate.flatMap(Int64.init),
                    pixelFormat: stream.pixelFormat,
                    bitsPerRawSample: stream.bitsPerRawSample.flatMap(Int.init),
                    colorSpace: stream.colorSpace,
                    colorTransfer: stream.colorTransfer,
                    colorPrimaries: stream.colorPrimaries,
                    colorRange: stream.colorRange,
                    chromaLocation: stream.chromaLocation,
                    isAttachedPicture: stream.disposition?.attachedPicture == 1,
                    sideDataTypes: Array(Set((stream.sideDataList?.compactMap(\.type) ?? [])
                        + (frames ?? []).filter { $0.streamIndex == stream.index }.flatMap { $0.sideDataList?.compactMap(\.type) ?? [] })).sorted()
                )
                result.metadata = (format?.tags ?? [:]).merging(stream.tags?.values ?? [:], uniquingKeysWith: { _, new in new })
                result.dolbyVisionProfile = stream.sideDataList?.compactMap(\.doviProfile).first
                result.dolbyVisionCompatibilityID = stream.sideDataList?.compactMap(\.doviCompatibilityID).first
                return result
            },
            metadata: format?.tags ?? [:],
            bitRate: format?.bitRate.flatMap(Int64.init),
            chapters: (chapters ?? []).compactMap { chapter in
                guard let start = chapter.startTime.flatMap(TimeInterval.init),
                      let end = chapter.endTime.flatMap(TimeInterval.init) else { return nil }
                return MediaChapter(
                    id: chapter.id,
                    startTime: start,
                    endTime: end,
                    title: chapter.tags?.title
                )
            }
        )
    }

    private func preferredTrackTitle(from tags: Stream.Tags?) -> String? {
        if let title = tags?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        guard let handlerName = tags?.handlerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handlerName.isEmpty else { return nil }
        let genericHandlerNames: Set<String> = [
            "videohandler",
            "soundhandler",
            "subtitlehandler",
            "mediahandler",
            "datahandler",
            "core media video",
            "core media audio"
        ]
        return genericHandlerNames.contains(handlerName.lowercased()) ? nil : handlerName
    }
}
