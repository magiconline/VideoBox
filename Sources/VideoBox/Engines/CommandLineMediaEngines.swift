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
            return payload.mediaProbe(sourceURL: sourceURL)
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
        if !request.configuration.advanced.overwriteExisting {
            try ensureDestinationDoesNotExist(request.destinationURL)
        }

        let result = try await runner.run(
            CLICommand(
                executableURL: executableURL,
                arguments: commandBuilder.arguments(for: request)
            )
        )
        try validate(result, tool: "FFmpeg")
        return request.destinationURL
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
    func arguments(for request: ExportRequest) -> [String] {
        if case let .trackExtraction(track) = request.operation {
            return trackExtractionArguments(for: request, track: track)
        }

        let configuration = request.configuration
        let editing = request.editing
        let usesComposition = editing.requiresFilterComposition
        let effectiveMode: ExportMode = usesComposition ? .transcode : configuration.mode
        let simpleTrimRange = editing.simpleTrimRange()
        let usesOffsetSubtitleInput = abs(configuration.subtitles.timeOffsetSeconds) > 0.000_1
            && configuration.subtitles.mode != .remove
            && configuration.subtitles.mode != .burn
            && !usesComposition
        let inputPlan = FFmpegInputPlan(
            primarySourceURL: request.sourceURL,
            tracks: configuration.trackSettings.filter { track in
                guard track.isIncluded else { return false }
                return track.kind != .subtitle
                    || (configuration.subtitles.mode != .remove
                        && configuration.subtitles.mode != .burn
                        && !usesComposition)
            },
            subtitleOffset: usesOffsetSubtitleInput ? configuration.subtitles.timeOffsetSeconds : nil,
            includeFallbackSubtitleInput: configuration.trackSettings.isEmpty && usesOffsetSubtitleInput
        )
        var arguments = [
            "-hide_banner",
            "-nostdin",
            configuration.advanced.overwriteExisting ? "-y" : "-n"
        ]

        if effectiveMode == .transcode, configuration.advanced.hardwareDecoding {
            arguments += ["-hwaccel", "videotoolbox"]
        }

        let inputSeek = effectiveMode == .streamCopy ? simpleTrimRange?.start : nil
        arguments += inputPlan.arguments(inputSeek: inputSeek)

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
            arguments += compositionArguments(for: request, inputPlan: inputPlan)
        } else {
            arguments += mappingArguments(
                configuration: configuration,
                inputPlan: inputPlan,
                usesOffsetSubtitleInput: usesOffsetSubtitleInput
            )
        }

        switch effectiveMode {
        case .streamCopy:
            arguments += ["-c", "copy"]
            arguments += subtitleArguments(
                configuration: configuration,
                usesComposition: usesComposition
            )
        case .transcode:
            arguments += videoArguments(for: request, includesSimpleFilters: !usesComposition)
            arguments += audioArguments(for: request, includesSimpleFilters: !usesComposition)
            arguments += subtitleArguments(
                configuration: configuration,
                usesComposition: usesComposition
            )
        }

        arguments += containerArguments(configuration: configuration)
        arguments += playbackTagArguments(
            configuration: configuration,
            effectiveMode: effectiveMode
        )
        arguments += trackMetadataArguments(
            configuration: configuration,
            usesComposition: usesComposition
        )
        arguments += metadataArguments(configuration: configuration)

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
            if configuration.includeAttachments {
                result += ["-map", "0:t?"]
            }
            if configuration.includeDataStreams {
                result += ["-map", "0:d?"]
            }
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

    private func compositionArguments(
        for request: ExportRequest,
        inputPlan: FFmpegInputPlan
    ) -> [String] {
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
                canvas: canvas
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
        graph.append(
            "\(concatInputs)concat=n=\(clipCount):v=1:a=\(audioInputs.count)[vout]\(audioConcatOutputs)"
        )

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
        if configuration.includeAttachments {
            result += ["-map", "0:t?"]
        }
        if configuration.includeDataStreams {
            result += ["-map", "0:d?"]
        } else {
            result.append("-dn")
        }
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
        canvas: (width: Int, height: Int)?
    ) -> [String] {
        var filters = [
            "trim=start=\(decimal(clip.sourceRange.start)):duration=\(decimal(clip.sourceRange.duration))"
        ]

        if request.configuration.subtitles.mode == .burn {
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
        var filters = [
            "atrim=start=\(decimal(clip.sourceRange.start)):duration=\(decimal(clip.sourceRange.duration))",
            "asetpts=PTS-STARTPTS"
        ]
        filters += tempoFilters(for: clip.playbackRate)
        if abs(clip.volume - 1) > 0.000_1 {
            filters.append("volume=\(decimal(clip.volume))")
        }
        return filters
    }

    private func tempoFilters(for requestedRate: Double) -> [String] {
        var rate = min(100, max(0.01, requestedRate))
        var filters: [String] = []
        while rate < 0.5 {
            filters.append("atempo=0.500")
            rate /= 0.5
        }
        while rate > 2 {
            filters.append("atempo=2.000")
            rate /= 2
        }
        if abs(rate - 1) > 0.000_1 {
            filters.append("atempo=\(decimal(rate))")
        }
        return filters
    }

    private func compositionCanvasDimensions(
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
        includesSimpleFilters: Bool
    ) -> [String] {
        let settings = request.configuration.video
        var result = ["-c:v", settings.codec.ffmpegName]

        switch settings.rateControl {
        case .constantQuality:
            if settings.codec.isHardwareAccelerated {
                result += ["-q:v", String(clamp(settings.quality, lower: 1, upper: 100))]
            } else {
                let crf = Int((51.0 * (1.0 - Double(settings.quality) / 100.0)).rounded())
                result += ["-crf", String(clamp(crf, lower: 0, upper: 51))]
            }
        case .averageBitrate:
            result += bitrateArguments(settings: settings, averageKbps: settings.averageBitrateKbps)
        case .targetSize:
            let targetBitrate = targetVideoBitrateKbps(for: request)
            result += bitrateArguments(settings: settings, averageKbps: targetBitrate)
        }

        if settings.codec.supportsSoftwarePreset {
            result += ["-preset", settings.preset.rawValue]
            if let tune = settings.tune.ffmpegValue, settings.codec != .av1 {
                result += ["-tune", tune]
            }
        }

        if let profile = settings.profile.ffmpegValue {
            result += ["-profile:v", profile]
        }

        var videoFilters = includesSimpleFilters
            ? simpleVideoFilters(configuration: request.configuration)
            : []
        if includesSimpleFilters, request.configuration.subtitles.mode == .burn {
            let escapedPath = escapeFilterPath(request.sourceURL.path)
            videoFilters.append(
                "subtitles=filename='\(escapedPath)':si=\(max(0, request.configuration.subtitles.burnStreamIndex))"
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

        if let pixelFormat = settings.pixelFormat.ffmpegValue {
            result += ["-pix_fmt", pixelFormat]
        }

        if settings.keyframeIntervalSeconds > 0 {
            let assumedFrameRate = frameRate ?? 30
            let interval = max(1, Int((settings.keyframeIntervalSeconds * assumedFrameRate).rounded()))
            result += ["-g", String(interval)]
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
        let duration = request.editing.trimmedDuration ?? request.sourceDuration
        guard let duration, duration > 0 else {
            return request.configuration.video.averageBitrateKbps
        }

        let totalKbits = Double(max(1, request.configuration.video.targetSizeMB)) * 8_192
        let audioKbps = request.configuration.audio.codec.usesBitrate
            ? request.configuration.audio.bitrateKbps
            : 0
        return max(100, Int(totalKbits / duration) - audioKbps)
    }

    private func simpleVideoFilters(configuration: ExportConfiguration) -> [String] {
        let settings = configuration.video
        var filters: [String] = []

        let dimensions = settings.resolution.dimensions
            ?? (settings.resolution == .custom
                ? (max(2, settings.customWidth), max(2, settings.customHeight))
                : nil)
        if let dimensions {
            if settings.allowUpscaling {
                filters.append(
                    "scale=\(dimensions.0):\(dimensions.1):force_original_aspect_ratio=decrease"
                )
            } else {
                filters.append(
                    "scale=w='min(\(dimensions.0),iw)':h='min(\(dimensions.1),ih)':force_original_aspect_ratio=decrease"
                )
            }
        }

        return filters
    }

    private func audioArguments(
        for request: ExportRequest,
        includesSimpleFilters: Bool
    ) -> [String] {
        let settings = request.configuration.audio
        guard let codec = settings.codec.ffmpegName else { return ["-an"] }

        let outputCodec = !includesSimpleFilters && settings.codec == .copy ? "aac" : codec
        var result = ["-c:a", outputCodec]
        guard settings.codec != .copy || !includesSimpleFilters else { return result }

        if settings.codec.usesBitrate || (!includesSimpleFilters && settings.codec == .copy) {
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
        usesComposition: Bool
    ) -> [String] {
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

    private func containerArguments(configuration: ExportConfiguration) -> [String] {
        var result: [String] = []
        result += configuration.containerOptions.preserveMetadata
            ? ["-map_metadata", "0"]
            : ["-map_metadata", "-1"]
        result += configuration.containerOptions.preserveChapters
            ? ["-map_chapters", "0"]
            : ["-map_chapters", "-1"]

        if configuration.containerOptions.fastStart, configuration.container.supportsFastStart {
            result += ["-movflags", "+faststart"]
        }
        if configuration.containerOptions.normalizeTimestamps {
            result.append("-start_at_zero")
        }
        if configuration.containerOptions.preventNegativeTimestamps {
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
        usesComposition: Bool
    ) -> [String] {
        guard !configuration.trackSettings.isEmpty else { return [] }
        var result: [String] = []

        for kind in [MediaStreamKind.video, .audio, .subtitle] {
            if usesComposition, kind == .audio, configuration.audio.codec == .none {
                continue
            }
            if kind == .subtitle,
               configuration.subtitles.mode == .remove
                || configuration.subtitles.mode == .burn
                || usesComposition {
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

private struct FFmpegInputPlan {
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
        includeFallbackSubtitleInput: Bool
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
            let language: String?
            let title: String?
            let handlerName: String?

            enum CodingKeys: String, CodingKey {
                case language
                case title
                case handlerName = "handler_name"
            }
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

            enum CodingKeys: String, CodingKey {
                case type = "side_data_type"
            }
        }

        let index: Int
        let codecName: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let sampleRate: String?
        let channels: Int?
        let bitRate: String?
        let pixelFormat: String?
        let bitsPerRawSample: String?
        let colorSpace: String?
        let colorTransfer: String?
        let colorPrimaries: String?
        let tags: Tags?
        let disposition: Disposition?
        let sideDataList: [SideData]?

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case codecType = "codec_type"
            case width
            case height
            case sampleRate = "sample_rate"
            case channels
            case bitRate = "bit_rate"
            case pixelFormat = "pix_fmt"
            case bitsPerRawSample = "bits_per_raw_sample"
            case colorSpace = "color_space"
            case colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries"
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

    func mediaProbe(sourceURL: URL) -> MediaProbe {
        MediaProbe(
            sourceURL: sourceURL,
            formatName: format?.formatName,
            duration: format?.duration.flatMap(TimeInterval.init),
            sizeInBytes: format?.size.flatMap(Int64.init),
            streams: streams.map { stream in
                MediaStream(
                    index: stream.index,
                    kind: MediaStreamKind(rawValue: stream.codecType ?? "") ?? .unknown,
                    codecName: stream.codecName,
                    width: stream.width,
                    height: stream.height,
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
                    isAttachedPicture: stream.disposition?.attachedPicture == 1,
                    sideDataTypes: stream.sideDataList?.compactMap(\.type) ?? []
                )
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
