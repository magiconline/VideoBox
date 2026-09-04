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
