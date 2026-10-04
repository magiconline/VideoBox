import Foundation
import XCTest
@testable import VideoBox

final class FFmpegCommandBuilderTests: XCTestCase {
    func testStreamCopyUsesEveryStreamWithoutReencoding() {
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.container = .mkv
        let request = makeRequest(configuration: configuration)

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-map", "0"]))
        XCTAssertTrue(arguments.containsSequence(["-c", "copy"]))
        XCTAssertFalse(arguments.contains("h264_videotoolbox"))
    }

    func testTranscodeBuildsVideoAudioAndScaleArguments() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.video.codec = .hevcVideoToolbox
        configuration.video.rateControl = .averageBitrate
        configuration.video.averageBitrateKbps = 6_000
        configuration.video.resolution = .fullHD1080
        configuration.audio.codec = .aac
        configuration.audio.bitrateKbps = 192
        let request = makeRequest(configuration: configuration)

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-c:v", "hevc_videotoolbox"]))
        XCTAssertTrue(arguments.containsSequence(["-b:v", "6000k"]))
        XCTAssertTrue(arguments.containsSequence(["-c:a", "aac"]))
        XCTAssertTrue(arguments.containsSequence(["-b:a", "192k"]))
        XCTAssertTrue(arguments.contains("-vf"))
    }

    func testTargetSizeUsesKnownDuration() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.video.rateControl = .targetSize
        configuration.video.targetSizeMB = 100
        configuration.audio.bitrateKbps = 128
        let request = ExportRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/input.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            sourceDuration: 100,
            configuration: configuration,
            editing: EditSettings()
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-b:v", "8003k"]))
    }

    func testTrackEditorControlsMappingAndPerTrackMetadata() {
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.trackSettings = [
            TrackExportSettings(
                streamIndex: 0,
                kind: .video,
                title: "Main picture",
                language: "und",
                isDefault: true
            ),
            TrackExportSettings(
                streamIndex: 1,
                kind: .audio,
                isIncluded: false,
                title: "Commentary",
                language: "eng"
            ),
            TrackExportSettings(
                streamIndex: 2,
                kind: .audio,
                title: "中文",
                language: "zho",
                isDefault: true
            )
        ]
        let request = makeRequest(configuration: configuration)

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-map", "0:0?"]))
        XCTAssertFalse(arguments.containsSequence(["-map", "0:1?"]))
        XCTAssertTrue(arguments.containsSequence(["-map", "0:2?"]))
        XCTAssertTrue(arguments.containsSequence(["-metadata:s:v:0", "title=Main picture"]))
        XCTAssertTrue(arguments.containsSequence(["-metadata:s:a:0", "language=zho"]))
        XCTAssertTrue(arguments.containsSequence(["-disposition:a:0", "default"]))
    }

    func testMetadataEditorWritesGlobalMetadataOverrides() {
        var configuration = ExportConfiguration()
        configuration.metadataEntries = [
            MetadataExportEntry(key: "title", value: "旅行视频"),
            MetadataExportEntry(key: "comment", value: "Created in VideoBox"),
            MetadataExportEntry(key: "   ", value: "ignored")
        ]
        let request = makeRequest(configuration: configuration)

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-metadata", "title=旅行视频"]))
        XCTAssertTrue(arguments.containsSequence(["-metadata", "comment=Created in VideoBox"]))
        XCTAssertFalse(arguments.contains("   =ignored"))
    }

    func testAttachmentAndDataRetentionRespectsBothGlobalAndPerTrackChoices() {
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.trackSettings = [TrackExportSettings(streamIndex: 0, kind: .video),
            TrackExportSettings(streamIndex: 3, kind: .attachment), TrackExportSettings(streamIndex: 4, kind: .data)]
        configuration.includeAttachments = false
        configuration.includeDataStreams = false
        var args = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertFalse(args.containsSequence(["-map", "0:3?"]))
        XCTAssertFalse(args.containsSequence(["-map", "0:4?"]))
        configuration.includeAttachments = true
        configuration.includeDataStreams = true
        args = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertTrue(args.containsSequence(["-map", "0:3?"]))
        XCTAssertTrue(args.containsSequence(["-map", "0:4?"]))
        XCTAssertFalse(args.containsSequence(["-map", "0:t?"]))
        XCTAssertFalse(args.containsSequence(["-map", "0:d?"]))
        configuration.trackSettings[1].isIncluded = false
        args = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertFalse(args.containsSequence(["-map", "0:3?"]))
        XCTAssertFalse(args.containsSequence(["-map", "0:t?"]))
    }

    func testMultipleSourceTracksUseDistinctInputsAndKeepUserOrder() {
        let primaryURL = URL(fileURLWithPath: "/tmp/input.mov")
        let externalURL = URL(fileURLWithPath: "/tmp/mandarin.m4a")
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.trackSettings = [
            TrackExportSettings(
                sourceURL: primaryURL,
                streamIndex: 0,
                kind: .video,
                codecName: "h264"
            ),
            TrackExportSettings(
                sourceURL: externalURL,
                streamIndex: 0,
                kind: .audio,
                title: "普通话",
                codecName: "aac"
            ),
            TrackExportSettings(
                sourceURL: primaryURL,
                streamIndex: 2,
                kind: .audio,
                title: "Original",
                codecName: "aac"
            )
        ]
        let request = ExportRequest(
            sourceURL: primaryURL,
            destinationURL: URL(fileURLWithPath: "/tmp/output.mov"),
            configuration: configuration,
            editing: EditSettings()
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-i", primaryURL.path]))
        XCTAssertTrue(arguments.containsSequence(["-i", externalURL.path]))
        XCTAssertTrue(arguments.containsSequence([
            "-map", "0:0?",
            "-map", "1:0?",
            "-map", "0:2?"
        ]))
        XCTAssertTrue(arguments.containsSequence(["-metadata:s:a:0", "title=普通话"]))
        XCTAssertTrue(arguments.containsSequence(["-metadata:s:a:1", "title=Original"]))
    }

    func testPreviewUsesSelectedExternalMediaAndBuildsSubtitleSidecar() {
        let primaryURL = URL(fileURLWithPath: "/tmp/input.mov")
        let audioURL = URL(fileURLWithPath: "/tmp/voice.flac")
        let subtitleURL = URL(fileURLWithPath: "/tmp/chinese.srt")
        let tracks = [
            TrackExportSettings(
                sourceURL: primaryURL,
                streamIndex: 0,
                kind: .video,
                codecName: "h264"
            ),
            TrackExportSettings(
                sourceURL: audioURL,
                streamIndex: 0,
                kind: .audio,
                codecName: "flac"
            ),
            TrackExportSettings(
                sourceURL: subtitleURL,
                streamIndex: 0,
                kind: .subtitle,
                codecName: "subrip"
            )
        ]
        let request = TrackPreviewRequest(
            primarySourceURL: primaryURL,
            destinationURL: URL(fileURLWithPath: "/tmp/preview.mov"),
            tracks: tracks,
            duration: 12,
            subtitleOffset: 1.25
        )

        let arguments = FFmpegCommandBuilder().previewArguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-i", primaryURL.path]))
        XCTAssertTrue(arguments.containsSequence(["-i", audioURL.path]))
        XCTAssertFalse(arguments.containsSequence(["-i", subtitleURL.path]))
        XCTAssertTrue(arguments.containsSequence([
            "-map", "0:0",
            "-map", "1:0"
        ]))
        XCTAssertTrue(arguments.containsSequence(["-c:v", "copy", "-tag:v", "avc1"]))
        XCTAssertTrue(arguments.containsSequence(["-c:a", "aac"]))
        XCTAssertTrue(arguments.contains("-sn"))
        XCTAssertTrue(arguments.containsSequence(["-t", "12.000"]))

        let subtitleArguments = FFmpegCommandBuilder().previewSubtitleArguments(
            for: request,
            destinationURL: URL(fileURLWithPath: "/tmp/preview.srt")
        )
        XCTAssertTrue(subtitleArguments.containsSequence(["-i", subtitleURL.path]))
        XCTAssertTrue(subtitleArguments.containsSequence(["-itsoffset", "1.250"]))
        XCTAssertTrue(subtitleArguments.containsSequence(["-map", "0:0"]))
        XCTAssertTrue(subtitleArguments.containsSequence(["-c:s", "srt"]))
        XCTAssertTrue(subtitleArguments.containsSequence(["-t", "12.000"]))
    }

    func testHEVCPreviewUsesAppleCompatibleHVC1Tag() {
        let sourceURL = URL(fileURLWithPath: "/tmp/input.mkv")
        let request = TrackPreviewRequest(
            primarySourceURL: sourceURL,
            destinationURL: URL(fileURLWithPath: "/tmp/preview.mov"),
            tracks: [
                TrackExportSettings(
                    sourceURL: sourceURL,
                    streamIndex: 0,
                    kind: .video,
                    codecName: "hevc"
                ),
                TrackExportSettings(
                    sourceURL: sourceURL,
                    streamIndex: 1,
                    kind: .audio,
                    codecName: "eac3"
                )
            ],
            duration: 30,
            subtitleOffset: 0
        )

        let arguments = FFmpegCommandBuilder().previewArguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-c:v", "copy", "-tag:v", "hvc1"]))
        XCTAssertTrue(arguments.containsSequence(["-c:a", "copy"]))
    }

    func testCompatibilityPreviewFallsBackToUniversalVideoAndAudio() {
        let sourceURL = URL(fileURLWithPath: "/tmp/input.webm")
        let request = TrackPreviewRequest(
            primarySourceURL: sourceURL,
            destinationURL: URL(fileURLWithPath: "/tmp/preview.mov"),
            tracks: [
                TrackExportSettings(
                    sourceURL: sourceURL,
                    streamIndex: 0,
                    kind: .video,
                    codecName: "vp9"
                ),
                TrackExportSettings(
                    sourceURL: sourceURL,
                    streamIndex: 1,
                    kind: .audio,
                    codecName: "opus"
                )
            ],
            duration: 30,
            subtitleOffset: 0
        )

        let arguments = FFmpegCommandBuilder().previewArguments(
            for: request,
            forceCompatibilityTranscode: true
        )

        XCTAssertTrue(arguments.containsSequence(["-c:v", "h264_videotoolbox"]))
        XCTAssertTrue(arguments.containsSequence(["-allow_sw", "1"]))
        XCTAssertTrue(arguments.containsSequence(["-pix_fmt", "yuv420p"]))
        XCTAssertTrue(arguments.containsSequence(["-tag:v", "avc1"]))
        XCTAssertTrue(arguments.containsSequence([
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2"
        ]))
    }

    func testHEVCTrackExtractionUsesAppleCompatibleTag() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let track = TrackExportSettings(
            sourceURL: sourceURL,
            streamIndex: 0,
            kind: .video,
            codecName: "hevc"
        )
        let request = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: URL(fileURLWithPath: "/tmp/extracted.mov"),
            configuration: ExportConfiguration(),
            editing: EditSettings(),
            operation: .trackExtraction(track)
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-tag:v:0", "hvc1"]))
    }

    func testQuickTimeStreamCopyTagsHEVCTracksForApplePlayback() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.container = .mov
        configuration.trackSettings = [
            TrackExportSettings(
                sourceURL: sourceURL,
                streamIndex: 0,
                kind: .video,
                codecName: "hevc"
            )
        ]
        let request = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: URL(fileURLWithPath: "/tmp/output.mov"),
            configuration: configuration,
            editing: EditSettings()
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-tag:v:0", "hvc1"]))
    }

    func testBitmapSubtitleExtractionKeepsACompatibleContainer() {
        let subtitle = TrackExportSettings(
            streamIndex: 3,
            kind: .subtitle,
            codecName: "dvd_subtitle"
        )

        XCTAssertEqual(subtitle.suggestedExtractionExtension, "mkv")
    }

    func testTrackExtractionCopiesMediaAndConvertsTextSubtitle() {
        let track = TrackExportSettings(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
            streamIndex: 3,
            kind: .subtitle,
            language: "zho",
            codecName: "mov_text"
        )
        let request = ExportRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/primary.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/subtitle.srt"),
            configuration: ExportConfiguration(),
            editing: EditSettings(),
            operation: .trackExtraction(track)
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)

        XCTAssertTrue(arguments.containsSequence(["-i", "/tmp/source.mov"]))
        XCTAssertTrue(arguments.containsSequence(["-map", "0:3"]))
        XCTAssertTrue(arguments.containsSequence(["-c:s", "srt"]))
        XCTAssertTrue(arguments.containsSequence(["-metadata:s:s:0", "language=zho"]))
    }

    func testTrackReorderingOnlyChangesMatchingMediaKind() {
        let primaryURL = URL(fileURLWithPath: "/tmp/input.mov")
        var configuration = ExportConfiguration()
        configuration.trackSettings = [
            TrackExportSettings(sourceURL: primaryURL, streamIndex: 0, kind: .video),
            TrackExportSettings(sourceURL: primaryURL, streamIndex: 1, kind: .audio, title: "A"),
            TrackExportSettings(sourceURL: primaryURL, streamIndex: 2, kind: .subtitle),
            TrackExportSettings(sourceURL: primaryURL, streamIndex: 3, kind: .audio, title: "B")
        ]
        let secondAudioID = configuration.trackSettings[3].id
        let firstAudioID = configuration.trackSettings[1].id

        configuration.moveTrack(id: secondAudioID, to: firstAudioID)

        XCTAssertEqual(
            configuration.trackSettings.filter { $0.kind == .audio }.map(\.title),
            ["B", "A"]
        )
        XCTAssertEqual(configuration.trackSettings[0].kind, .video)
        XCTAssertEqual(configuration.trackSettings[2].kind, .subtitle)
    }

    func testClipCompositionBuildsSplitFiltersInExplicitTranscodeMode() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.trackSettings = [
            TrackExportSettings(streamIndex: 0, kind: .video),
            TrackExportSettings(streamIndex: 1, kind: .audio)
        ]

        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1_280, canvasHeight: 720)
        XCTAssertNotNil(editing.split(atOutputTime: 4))
        editing.clips[0].playbackRate = 2
        editing.clips[0].transform.quarterTurnsClockwise = 1
        editing.clips[0].volume = 0.5
        editing.clips[0].scale = 1.25

        let request = ExportRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            sourceDuration: 10,
            configuration: configuration,
            editing: editing
        )

        let arguments = FFmpegCommandBuilder().arguments(for: request)
        let filter = arguments.value(after: "-filter_complex") ?? ""

        XCTAssertTrue(filter.contains("split=2"))
        XCTAssertTrue(filter.contains("transpose=clock"))
        XCTAssertTrue(filter.contains("atempo=2.000"))
        XCTAssertTrue(filter.contains("volume=0.500"))
        XCTAssertTrue(filter.contains("concat=n=2:v=1:a=1"))
        XCTAssertTrue(arguments.containsSequence(["-map", "[vout]"]))
        XCTAssertTrue(arguments.containsSequence(["-map", "[aout0]"]))
        XCTAssertTrue(arguments.containsSequence(["-c:v", "hevc_videotoolbox"]))
        XCTAssertTrue(arguments.contains("-sn"))
        XCTAssertFalse(arguments.contains("-c:s"))
        XCTAssertFalse(arguments.containsSequence(["-c", "copy"]))
    }

    func testLUTTranscodeTagsRec709Output() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.color.isLUTEnabled = true
        configuration.color.lutFile = LUTFileReference(
            url: URL(fileURLWithPath: "/tmp/DJI D-Log M.cube")
        )
        configuration.color.outputColorSpace = .rec709SDR
        configuration.color.outputRange = .limited
        configuration.video.pixelFormat = .yuv420p10le
        let request = makeRequest(configuration: configuration)

        let arguments = FFmpegCommandBuilder().arguments(for: request)
        let filters = arguments.value(after: "-vf") ?? ""

        XCTAssertTrue(filters.contains("lut3d=file='/tmp/DJI D-Log M.cube':interp=trilinear"))
        XCTAssertTrue(filters.contains("setparams=range=limited"))
        XCTAssertTrue(arguments.containsSequence(["-c:v", "hevc_videotoolbox"]))
        XCTAssertTrue(arguments.containsSequence(["-pix_fmt", "p010le"]))
        XCTAssertTrue(arguments.containsSequence(["-color_primaries", "bt709"]))
        XCTAssertTrue(arguments.containsSequence(["-color_trc", "bt709"]))
        XCTAssertTrue(arguments.containsSequence(["-colorspace", "bt709"]))
        XCTAssertTrue(arguments.containsSequence(["-color_range", "tv"]))
        XCTAssertFalse(arguments.containsSequence(["-c", "copy"]))
    }

    func testMatchingColorDeclarationsNeverChangeQuickExportIntoTranscode() throws {
        var configuration = ExportConfiguration()
        configuration.color.outputColorSpace = .rec709SDR
        configuration.color.outputRange = .limited
        let source = MediaStream(index: 0, kind: .video, codecName: "h264", width: 1920, height: 1080,
                                 sampleRate: nil, channels: nil, language: nil, pixelFormat: "yuv420p",
                                 colorSpace: "bt709", colorTransfer: "bt709", colorPrimaries: "bt709", colorRange: "tv")
        let request = ExportRequest(sourceURL: URL(fileURLWithPath: "/tmp/input.mp4"),
                                    destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                                    sourceVideo: source, configuration: configuration, editing: EditSettings())
        try ExportPlan(request: request).validate()
        let arguments = FFmpegCommandBuilder().arguments(for: request)
        XCTAssertTrue(arguments.containsSequence(["-c", "copy"]))
        XCTAssertFalse(arguments.contains("-c:v"))
        XCTAssertFalse(arguments.contains("-vf"))
        XCTAssertFalse(arguments.contains("-color_trc"))
    }

    func testQuickExportRemovesAudioWithoutReencodingVideo() {
        var configuration = ExportConfiguration()
        configuration.audio.codec = .none
        configuration.trackSettings = [TrackExportSettings(streamIndex: 0, kind: .video),
                                       TrackExportSettings(streamIndex: 1, kind: .audio)]
        let arguments = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertTrue(arguments.containsSequence(["-map", "0:0?"]))
        XCTAssertFalse(arguments.containsSequence(["-map", "0:1?"]))
        XCTAssertTrue(arguments.containsSequence(["-c", "copy"]))
        XCTAssertTrue(arguments.contains("-an"))
        XCTAssertFalse(arguments.contains("-c:v"))
    }

    func testAV1UsesNumericPresetAndMainProfile() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.video.codec = .av1
        configuration.video.profile = .main
        configuration.video.rateControl = .constantQuality
        configuration.video.quality = 50
        let arguments = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertTrue(arguments.containsSequence(["-preset", "6"]))
        XCTAssertTrue(arguments.containsSequence(["-profile:v", "0"]))
        XCTAssertTrue(arguments.containsSequence(["-crf", "32"]))
    }

    func test480pScaleConstrainsBothDimensionsToEvenValues() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.video.codec = .h264
        configuration.video.resolution = .sd480
        let arguments = FFmpegCommandBuilder().arguments(for: makeRequest(configuration: configuration))
        XCTAssertTrue(arguments.value(after: "-vf")?.contains("force_divisible_by=2") == true)
    }

    func testInvalidQuickLUTRequestIsRejectedRatherThanChangingModes() {
        var configuration = ExportConfiguration()
        configuration.color.isLUTEnabled = true
        configuration.color.lutFile = LUTFileReference(url: URL(fileURLWithPath: "/tmp/sample.cube"))
        let request = makeRequest(configuration: configuration)
        XCTAssertThrowsError(try ExportPlan(request: request).validate())
        let arguments = FFmpegCommandBuilder().arguments(for: request)
        XCTAssertTrue(arguments.containsSequence(["-c", "copy"]))
        XCTAssertFalse(arguments.contains("-c:v"))
    }

    func testChangedTimelineRemovesSourceChaptersWhileUnchangedSplitCanKeepThem() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1920, canvasHeight: 1080)
        _ = editing.split(atOutputTime: 4)
        var request = ExportRequest(sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
                                    destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                                    configuration: configuration, editing: editing)
        XCTAssertFalse(editing.changesSourceTimingForExport)
        XCTAssertTrue(FFmpegCommandBuilder().arguments(for: request).containsSequence(["-map_chapters", "0"]))
        editing.clips.removeLast()
        request.editing = editing
        XCTAssertTrue(editing.changesSourceTimingForExport)
        XCTAssertTrue(FFmpegCommandBuilder().arguments(for: request).containsSequence(["-map_chapters", "-1"]))
    }

    private func makeRequest(configuration: ExportConfiguration) -> ExportRequest {
        ExportRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/input.mov"),
            destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            configuration: configuration,
            editing: EditSettings()
        )
    }
}

private extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.dropLast(sequence.count - 1).contains { start in
            Array(self[start..<(start + sequence.count)]) == sequence
        }
    }


    func value(after element: Element) -> Element? {
        guard let index = firstIndex(of: element), indices.contains(index + 1) else { return nil }
        return self[index + 1]
    }
}
