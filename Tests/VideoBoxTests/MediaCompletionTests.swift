import AVFoundation
import CoreImage
import XCTest
@testable import VideoBox

final class MediaCompletionTests: XCTestCase {
    private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    private var ffmpeg: URL { root.appendingPathComponent(".build/ffmpeg-runtime/arm64/bin/ffmpeg") }
    private var ffprobe: URL { root.appendingPathComponent(".build/ffmpeg-runtime/arm64/bin/ffprobe") }

    func testBudgetCountsEveryTrackAndRejectsUnknownCopiedBitrates() {
        var configuration = ExportConfiguration()
        configuration.video.targetSizeMB = 100
        configuration.trackSettings = [TrackExportSettings(streamIndex: 0, kind: .video)]
            + (1...2).map { index in
                let stream = MediaStream(index: index, kind: .audio, codecName: "aac", width: nil, height: nil,
                                         sampleRate: 48_000, channels: 2, language: nil, bitRate: 192_000)
                return TrackExportSettings(sourceURL: root, stream: stream, sourceDuration: 100)
            }
        XCTAssertEqual(TargetSizeBudget(configuration: configuration, duration: 100).audioKbps, 512)
        configuration.audio.codec = .copy
        XCTAssertEqual(TargetSizeBudget(configuration: configuration, duration: 100).audioKbps, 384)
        configuration.trackSettings[1].sourceStream = nil
        XCTAssertFalse(TargetSizeBudget(configuration: configuration, duration: 100).blockers.isEmpty)
        configuration.audio.codec = .none
        XCTAssertEqual(TargetSizeBudget(configuration: configuration, duration: 100).audioKbps, 0)
        configuration.audio.codec = .aac
        configuration.video.targetSizeMB = 1
        XCTAssertFalse(TargetSizeBudget(configuration: configuration, duration: 100).blockers.isEmpty)
    }

    func testSource60FPSProduces120FrameTwoSecondGOP() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        let video = MediaStream(index: 0, kind: .video, codecName: "hevc", width: 320, height: 180,
                                averageFrameRate: "60000/1001", sampleRate: nil, channels: nil, language: nil)
        let request = ExportRequest(sourceURL: root, destinationURL: root.appendingPathComponent("out.mp4"),
                                    sourceVideo: video, configuration: configuration, editing: EditSettings())
        let args = FFmpegCommandBuilder().arguments(for: request)
        XCTAssertEqual(args[try! XCTUnwrap(args.firstIndex(of: "-g")) + 1], "120")
        XCTAssertTrue(args.contains("expr:gte(t,n_forced*2.000)"))
    }

    func testCameraModelAndLUTFilenameNeverBecomeSourceLogEvidence() {
        var source = MediaStream(index: 0, kind: .video, codecName: "hevc", width: 320, height: 180,
                                 sampleRate: nil, channels: nil, language: nil)
        source.metadata = ["model": "DJI OSMO Action 5 Pro", "comment": "D-Log M"]
        XCTAssertNil(CameraLogEvidence.read(source).profile)
        source.metadata["gamma"] = "D-Log M"
        XCTAssertEqual(CameraLogEvidence.read(source).profile, .dLogM)
        var settings = ColorExportSettings()
        settings.isLUTEnabled = true
        settings.lutFile = LUTFileReference(url: root.appendingPathComponent("Sony S-Log3 to Rec709.cube"))
        XCTAssertTrue(ColorConversionPlan(settings: settings, source: source).blockers.contains { $0.contains("素材声明为") })
    }

    func testOneDimensionalAndShaperLUTUseExactSeparateStages() throws {
        let text = "LUT_1D_SIZE 2\nLUT_3D_SIZE 2\nLUT_1D_INPUT_RANGE -1 1\n1 1 1\n0 0 0\n" + identity3D
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.stages.map(\.is1D), [true, false])
        XCTAssertEqual(lut.stages[0].minimum.x, -1)
        XCTAssertEqual(lut.stages[1].minimum.x, 0)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = try XCTUnwrap(LUTPreviewRenderer.apply(lut, to: source))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        XCTAssertEqual(pixel[0], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel[1], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel[2], 0.5, accuracy: 0.002)
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n"))
    }

    func testRemappingSplitsCuesAndReordersChapters() {
        let edit = sampleEditing()
        let ranges = TimedMetadataRemapper.ranges(start: 1, end: 3, editing: edit, offset: 0.5)
        XCTAssertEqual(ranges, [TimelineRange(start: 0, duration: 0.25), TimelineRange(start: 4, duration: 1)])
        let chapters = TimedMetadataRemapper.chapters([
            MediaChapter(id: 1, startTime: 0, endTime: 3, title: "A"),
            MediaChapter(id: 2, startTime: 3, endTime: 6, title: "B")
        ], editing: edit)
        XCTAssertEqual(chapters.map(\.title), ["B", "A"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 1])
        XCTAssertEqual(chapters.map(\.endTime), [1, 5])
    }

    func testActualSubtitleChapterAndMultipleAudioExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory)
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        var settings = baseSettings(probe)
        settings.container = .mkv
        settings.subtitles.mode = .copy
        settings.subtitles.timeOffsetSeconds = 0.5
        let output = directory.appendingPathComponent("edited.mkv")
        let request = ExportRequest(sourceURL: source, destinationURL: output, sourceDuration: probe.duration,
            sourceVideo: probe.primaryVideoStream, configuration: settings, editing: sampleEditing())
        try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
        let result = try await FFprobeEngine(executableURL: ffprobe).probe(output)
        XCTAssertEqual(result.duration ?? 0, 5, accuracy: 0.1)
        XCTAssertEqual(result.streams.filter { $0.kind == .audio }.count, 2)
        XCTAssertEqual(result.streams.filter { $0.kind == .subtitle }.count, 1)
        XCTAssertEqual(result.chapters.map(\.title), ["B", "A"])
        XCTAssertEqual(result.chapters[1].startTime, 1, accuracy: 0.05)
        let srt = directory.appendingPathComponent("result.srt")
        try await run(["-i", output.path, "-map", "0:s:0", srt.path])
        let cues = try SubtitleCueParser.parse(contentsOf: srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].endTime, 0.25, accuracy: 0.05)
        XCTAssertEqual(cues[1].startTime, 4, accuracy: 0.05)
        XCTAssertEqual(cues[1].endTime, 5, accuracy: 0.05)

        settings.subtitles.mode = .burn
        settings.container = .mp4
        // External subtitle input, also after edits and with non-zero offset.
        settings.trackSettings.removeAll { $0.kind == .subtitle }
        settings.trackSettings.append(TrackExportSettings(sourceURL: directory.appendingPathComponent("source.srt"), streamIndex: 0, kind: .subtitle, codecName: "subrip"))
        var burn = request
        burn.configuration = settings
        burn.destinationURL = directory.appendingPathComponent("burn.mp4")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(burn)
        let burned = try await FFprobeEngine(executableURL: ffprobe).probe(burn.destinationURL)
        XCTAssertFalse(burned.streams.contains { $0.kind == .subtitle })
        XCTAssertEqual(burned.duration ?? 0, 5, accuracy: 0.1)
    }

    func testActualHDRToSDRAndP3ConversionWithCorrectMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pq.mp4")
        try await run(["-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12", "-t", "0.5",
                       "-vf", "zscale=pin=bt709:tin=bt709:min=bt709:rin=limited:p=bt2020:t=smpte2084:m=bt2020nc:r=limited:npl=100,format=yuv420p10le",
                       "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
                       "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-color_range", "tv", source.path])
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        XCTAssertEqual(probe.primaryVideoStream?.hdrDescription, "PQ（静态 HDR 信息未标记）")
        for space in [OutputColorSpace.rec709SDR, .displayP3SDR, .rec2020HLG] {
            var settings = baseSettings(probe)
            settings.color.outputColorSpace = space
            settings.video.pixelFormat = .yuv420p10le
            settings.video.codec = .hevc
            let output = directory.appendingPathComponent("\(space.rawValue).mp4")
            let request = ExportRequest(sourceURL: source, destinationURL: output, sourceDuration: probe.duration,
                sourceVideo: probe.primaryVideoStream, configuration: settings, editing: EditSettings())
            try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
            let result = try await FFprobeEngine(executableURL: ffprobe).probe(output)
            XCTAssertEqual(result.primaryVideoStream?.colorPrimaries, space.ffmpegPrimaries)
            XCTAssertEqual(result.primaryVideoStream?.colorTransfer, space.ffmpegTransfer)
            XCTAssertEqual(result.primaryVideoStream?.bitDepth, 10)
        }
    }

    func testDefaultBFramesDoNotShiftEditedVideoSubtitlesOrChapters() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory)
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        for container in [MediaContainer.mp4, .mkv] {
            var settings = baseSettings(probe)
            settings.container = container
            settings.video.bFrames = ExportConfiguration().video.bFrames
            settings.subtitles.mode = .copy
            settings.subtitles.timeOffsetSeconds = 0.5
            let output = directory.appendingPathComponent("bframes.\(container.rawValue)")
            let request = ExportRequest(sourceURL: source, destinationURL: output, sourceDuration: probe.duration,
                sourceVideo: probe.primaryVideoStream, configuration: settings, editing: sampleEditing())
            try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
            let frames = try await ProcessRunner().run(CLICommand(executableURL: ffprobe, arguments: [
                "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#8", "-show_frames",
                "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", output.path
            ]))
            let firstTime = frames.standardOutput.split(whereSeparator: \.isNewline)
                .compactMap { Double($0.split(separator: ",").first.map(String.init) ?? "") }.first
            XCTAssertEqual(try XCTUnwrap(firstTime), 0, accuracy: 0.002, container.rawValue)
            let result = try await FFprobeEngine(executableURL: ffprobe).probe(output)
            XCTAssertEqual(result.chapters[1].startTime, 1, accuracy: 0.002)
            let srt = directory.appendingPathComponent("bframes-\(container.rawValue).srt")
            try await run(["-i", output.path, "-map", "0:s:0", srt.path])
            let cues = try SubtitleCueParser.parse(contentsOf: srt)
            XCTAssertEqual(cues[1].startTime, 4, accuracy: 0.025, container.rawValue)
        }
    }

    func testActualOneDimensionalShaperExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await run(["-f", "lavfi", "-i", "color=gray:size=160x96:rate=12", "-t", "0.25", "-c:v", "libx264", source.path])
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        let lut = directory.appendingPathComponent("shaper.cube")
        try ("LUT_1D_SIZE 2\nLUT_3D_SIZE 2\nLUT_1D_INPUT_RANGE -1 1\n0 0 0\n1 1 1\n" + identity3D).write(to: lut, atomically: true, encoding: .utf8)
        var settings = baseSettings(probe)
        settings.color.lutFile = LUTFileReference(url: lut)
        settings.color.isLUTEnabled = true
        settings.color.confirmsLUTCompatibility = true
        settings.color.outputColorSpace = .rec709SDR
        let output = directory.appendingPathComponent("lut.mp4")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(ExportRequest(sourceURL: source, destinationURL: output,
            sourceDuration: probe.duration, sourceVideo: probe.primaryVideoStream, configuration: settings, editing: EditSettings()))
        let result = try await FFprobeEngine(executableURL: ffprobe).probe(output)
        XCTAssertEqual(result.primaryVideoStream?.colorPrimaries, "bt709")
        let pixelsURL = directory.appendingPathComponent("pixels.rgb")
        try await run(["-i", output.path, "-frames:v", "1", "-vf", "scale=in_color_matrix=bt709:in_range=limited,format=rgb24", "-f", "rawvideo", pixelsURL.path])
        let pixels = try Data(contentsOf: pixelsURL)
        XCTAssertEqual(Double(pixels[pixels.count / 2]), 191, accuracy: 5,
                       "The -1...1 shaper must brighten gray to approximately 0.75, not just retag it")
    }

    func testActualTwelveBitHEVCPreservation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("12bit.mkv")
        try await run(["-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12", "-t", "0.25", "-c:v", "libx265", "-preset", "ultrafast",
                       "-x265-params", "log-level=error", "-pix_fmt", "yuv420p12le", source.path])
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        XCTAssertEqual(probe.primaryVideoStream?.bitDepth, 12)
        var settings = baseSettings(probe); settings.video.codec = .hevc
        XCTAssertEqual(ExportPlan(configuration: settings, editing: EditSettings(), sourceVideo: probe.primaryVideoStream).pixelFormat, .yuv420p12le)
        let output = directory.appendingPathComponent("preserved.mkv")
        settings.container = .mkv
        try await FFmpegExportEngine(executableURL: ffmpeg).export(ExportRequest(sourceURL: source, destinationURL: output,
            sourceDuration: probe.duration, sourceVideo: probe.primaryVideoStream, configuration: settings, editing: EditSettings()))
        let result = try await FFprobeEngine(executableURL: ffprobe).probe(output)
        XCTAssertEqual(result.primaryVideoStream?.bitDepth, 12)
    }

    func testActualPreviewAndExportGainAbove100PercentAndPitchAfterRetiming() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory)
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        var edit = EditSettings(); edit.sourceDuration = 6; edit.canvasWidth = 320; edit.canvasHeight = 180
        edit.clips = [EditSegment(sourceRange: TimelineRange(start: 1, duration: 2), playbackRate: 2, volume: 2)]
        let preview = try await PreviewTimelineBuilder.make(asset: AVURLAsset(url: source), editing: edit)
        let tracks = try await preview.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertNotNil(preview.audioResource, "Retiming and gain must reuse export's audio processing")
        let reader = try AVAssetReader(asset: preview.asset)
        let audio = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
        ])
        audio.audioMix = preview.audioMix; audio.audioTimePitchAlgorithm = .spectral
        reader.add(audio)
        XCTAssertTrue(reader.startReading())
        var previewSamples: [Float] = []
        while let buffer = audio.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            previewSamples += samples
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        let rmsPreview = rms(Array(previewSamples.dropFirst(9_600).prefix(24_000)))
        XCTAssertEqual(rmsPreview, 0.1767, accuracy: 0.03, "200% monitoring must really amplify rather than clamp to 100%")

        var settings = baseSettings(probe); settings.subtitles.mode = .remove
        let output = directory.appendingPathComponent("gain.mp4")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(ExportRequest(sourceURL: source, destinationURL: output,
            sourceDuration: probe.duration, sourceVideo: probe.primaryVideoStream, configuration: settings, editing: edit))
        for track in 0...1 {
            let pcm = directory.appendingPathComponent("gain-\(track).f32")
            try await run(["-i", output.path, "-ss", "0.2", "-t", "0.5", "-map", "0:a:\(track)", "-ac", "1", "-ar", "48000", "-f", "f32le", pcm.path])
            let data = try Data(contentsOf: pcm)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertEqual(rms(samples), rmsPreview, accuracy: 0.025)
            let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let frequency = Double(crossings) / (Double(samples.count) / 48_000)
            XCTAssertEqual(frequency, track == 0 ? 440 : 880, accuracy: 12, "Retiming must retain pitch on each audio track")
        }
    }

    func testSameFrameComparisonCoordinatesFollowRotationAndZoom() {
        let state = LUTComparisonState()
        let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        state.update(fraction: 0.5, viewport: CGSize(width: 960, height: 540))
        XCTAssertEqual(state.originalRegion(extent: extent, outputTime: 0), CGRect(x: 0, y: 0, width: 960, height: 1080))
        var edit = EditSettings(); edit.initialize(duration: 5, canvasWidth: 1920, canvasHeight: 1080)
        edit.clips[0].transform.quarterTurnsClockwise = 1
        state.update(viewport: CGSize(width: 540, height: 960), editing: edit)
        let region = state.originalRegion(extent: extent, outputTime: 0)
        XCTAssertEqual(region.width, 1920, accuracy: 0.001)
        XCTAssertEqual(region.height, 540, accuracy: 0.001)
        XCTAssertEqual(region.minY, 0, accuracy: 0.001)
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    func testActualQuickTrimRejectsUnalignedCutsAndOffersAlignedRange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeSource(in: directory)
        let probe = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        let index = try await QuickTrimIndex.scan(url: source, streamIndex: 0, duration: 6, ffprobe: ffprobe)
        let range = TimelineRange(start: 1, duration: 2)
        XCTAssertFalse(index.isAligned(range))
        XCTAssertEqual(index.expandedRange(range), TimelineRange(start: 0, duration: 4))
        var edit = EditSettings(); edit.initialize(duration: 6, canvasWidth: 320, canvasHeight: 180)
        edit.clips[0].sourceRange = range
        var settings = baseSettings(probe)
        settings.mode = .streamCopy; settings.audio.codec = .copy
        var request = ExportRequest(sourceURL: source, destinationURL: directory.appendingPathComponent("trim.mp4"), sourceDuration: 6,
            sourceVideo: probe.primaryVideoStream, configuration: settings, editing: edit)
        do {
            try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
            XCTFail("Unaligned copy must not silently include extra video")
        } catch let error as ExportValidationError { XCTAssertTrue(error.blockers.contains { $0.contains("未对齐关键帧") }) }
        request.editing.clips[0].sourceRange = TimelineRange(start: 2, duration: 2)
        try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
        let result = try await FFprobeEngine(executableURL: ffprobe).probe(request.destinationURL)
        XCTAssertEqual(result.duration ?? 0, 2, accuracy: 0.15)
    }

    private func run(_ args: [String]) async throws {
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: ["-v", "error", "-nostdin", "-n"] + args))
        guard result.succeeded else { throw ExportValidationError(blockers: [result.standardError]) }
    }
    private func temporaryDirectory() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Bundled runtime required") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-completion-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func baseSettings(_ probe: MediaProbe) -> ExportConfiguration {
        var settings = ExportConfiguration()
        settings.mode = .transcode; settings.video.codec = .h264; settings.video.preset = .ultrafast
        settings.video.bFrames = 0; settings.advanced.hardwareDecoding = false
        settings.includeAttachments = false; settings.includeDataStreams = false
        settings.trackSettings = probe.streams.map { TrackExportSettings(sourceURL: probe.sourceURL, stream: $0, sourceDuration: probe.duration) }
        return settings
    }
    private func sampleEditing() -> EditSettings {
        var edit = EditSettings(); edit.sourceDuration = 6; edit.canvasWidth = 320; edit.canvasHeight = 180
        edit.clips = [EditSegment(sourceRange: TimelineRange(start: 3, duration: 2), playbackRate: 2, volume: 2),
                      EditSegment(sourceRange: TimelineRange(start: 0, duration: 2), playbackRate: 0.5)]
        return edit
    }
    private func makeSource(in directory: URL) async throws -> URL {
        let srt = directory.appendingPathComponent("source.srt")
        try "1\n00:00:01,000 --> 00:00:03,000\nTIMED CAPTION\n".write(to: srt, atomically: true, encoding: .utf8)
        let chapters = directory.appendingPathComponent("chapters.ffmetadata")
        try ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=3000\ntitle=A\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=3000\nEND=6000\ntitle=B\n".write(to: chapters, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("source.mp4")
        try await run(["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                       "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-i", srt.path, "-i", chapters.path,
                       "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map_chapters", "4", "-t", "6",
                       "-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-keyint_min", "60", "-sc_threshold", "0", "-bf", "2",
                       "-c:a", "aac", "-b:a", "96k", "-c:s", "mov_text", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", source.path])
        return source
    }
    private var identity3D: String { "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n" }
}
