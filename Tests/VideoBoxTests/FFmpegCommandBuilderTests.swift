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

        XCTAssertTrue(arguments.containsSequence(["-b:v", "8064k"]))
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

    func testClipCompositionBuildsSplitFiltersAndForcesTranscode() {
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
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
