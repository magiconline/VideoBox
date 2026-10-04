import Foundation
import XCTest
@testable import VideoBox

final class ExportPlanTests: XCTestCase {
    func testExternalAndOffsetTextSubtitleBurnAreNowAllowed() {
        let primary = URL(fileURLWithPath: "/tmp/source.mp4")
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.subtitles.mode = .burn
        configuration.subtitles.timeOffsetSeconds = 1
        configuration.trackSettings = [
            TrackExportSettings(sourceURL: primary, streamIndex: 0, kind: .video, codecName: "h264"),
            TrackExportSettings(sourceURL: URL(fileURLWithPath: "/tmp/subtitle.srt"), streamIndex: 0, kind: .subtitle, codecName: "subrip")
        ]
        let blocked = ExportPlan(configuration: configuration, editing: EditSettings(), primarySourceURL: primary)
        XCTAssertTrue(blocked.blockers.isEmpty, blocked.blockers.joined())
        configuration.subtitles.mode = .remove
        XCTAssertTrue(ExportPlan(configuration: configuration, editing: EditSettings(), primarySourceURL: primary).blockers.isEmpty)
    }

    func testSourceFileCannotBeOverwrittenThroughPathSymlinkOrHardLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-source-protection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let symbolicLink = directory.appendingPathComponent("symbolic.mp4")
        let hardLink = directory.appendingPathComponent("hard.mp4")
        try Data("source video".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardLink)
        var configuration = ExportConfiguration()
        configuration.advanced.overwriteExisting = true
        for destination in [source, symbolicLink, hardLink] {
            let request = ExportRequest(sourceURL: source, destinationURL: destination, configuration: configuration, editing: EditSettings())
            XCTAssertFalse(ExportPlan.destinationBlockers(request: request).isEmpty)
        }
        let track = TrackExportSettings(sourceURL: source, streamIndex: 0, kind: .video)
        let extraction = ExportRequest(sourceURL: directory.appendingPathComponent("unrelated.mp4"), destinationURL: hardLink,
                                       configuration: configuration, editing: EditSettings(), operation: .trackExtraction(track))
        XCTAssertFalse(ExportPlan.destinationBlockers(request: extraction).isEmpty)
    }

    func testHardwarePixelFormatDowngradesAreBlockedButSoftwareIsAllowed() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.video.codec = .hevcVideoToolbox
        configuration.video.pixelFormat = .yuv444p10le
        XCTAssertFalse(plan(configuration).blockers.isEmpty)
        configuration.video.codec = .hevc
        XCTAssertTrue(plan(configuration).blockers.isEmpty)
        configuration.video.codec = .h264VideoToolbox
        configuration.video.pixelFormat = .automatic
        XCTAssertFalse(plan(configuration, source: sourceVideo(format: "yuv420p10le")).blockers.isEmpty)
        configuration.video.codec = .hevcVideoToolbox
        let resolved = plan(configuration, source: sourceVideo(format: "yuv420p10le"))
        XCTAssertTrue(resolved.blockers.isEmpty)
        XCTAssertEqual(resolved.pixelFormat, .yuv420p10le)
    }

    func testContainerAndCodecCompatibilityAppliesToBothModes() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.container = .webm
        configuration.video.codec = .hevc
        configuration.audio.codec = .aac
        let invalid = plan(configuration).blockers
        XCTAssertTrue(invalid.contains(where: { $0.contains("WebM".uppercased()) && $0.contains("hevc") }))
        XCTAssertTrue(invalid.contains(where: { $0.contains("aac") }))
        configuration.video.codec = .av1
        configuration.audio.codec = .opus
        XCTAssertTrue(plan(configuration).blockers.isEmpty)
        configuration.container = .mp4
        configuration.video.codec = .proRes
        configuration.video.pixelFormat = .yuv422p10le
        XCTAssertTrue(plan(configuration).blockers.contains(where: { $0.contains("prores") }))
        configuration.container = .mov
        configuration.audio.codec = .pcm
        XCTAssertTrue(plan(configuration).blockers.isEmpty)

        configuration.mode = .streamCopy
        configuration.container = .webm
        configuration.video.pixelFormat = .automatic
        XCTAssertTrue(plan(configuration, source: sourceVideo(format: "yuv420p")).blockers.contains(where: { $0.contains("h264") }))
    }

    func testQuickExportAccountsForAudioProcessingAndRemoval() {
        var configuration = ExportConfiguration()
        configuration.audio.sampleRate = .hz48000
        configuration.audio.channels = .stereo
        configuration.audio.normalizeLoudness = true
        XCTAssertEqual(plan(configuration).blockers.filter { $0.contains("音频") || $0.contains("响度") }.count, 3)
        configuration.audio.codec = .none
        XCTAssertTrue(plan(configuration).blockers.isEmpty)
    }

    func testCopiedAudioCannotSilentlyIgnoreResamplingOrGain() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.audio.codec = .copy
        configuration.audio.normalizeLoudness = true
        XCTAssertTrue(plan(configuration).blockers.contains(where: { $0.contains("音频处理需要重新编码") }))
    }

    func testColorConversionRequiresKnownInputAndHDRDepth() {
        var configuration = ExportConfiguration()
        configuration.mode = .transcode
        configuration.color.outputColorSpace = .rec2020PQ
        XCTAssertTrue(plan(configuration).blockers.contains(where: { $0.contains("输入色彩标签不完整") || $0.contains("10-bit") }))
        configuration.color.isLUTEnabled = true
        configuration.color.lutFile = LUTFileReference(url: URL(fileURLWithPath: "/tmp/test.cube"))
        XCTAssertTrue(plan(configuration).blockers.contains(where: { $0.contains("无法确认素材") }))
        configuration.color.outputColorSpace = .rec709SDR
        configuration.color.confirmsLUTCompatibility = true
        XCTAssertTrue(plan(configuration).blockers.isEmpty)
    }

    func testColorMatchRequiresExactTransferAndMatrixNotOnlyPrimaries() {
        let wrongMatrix = MediaStream(index: 0, kind: .video, codecName: "h264", width: 1920, height: 1080,
                                      sampleRate: nil, channels: nil, language: nil, colorSpace: "bt470bg",
                                      colorTransfer: "bt709", colorPrimaries: "bt709")
        XCTAssertFalse(OutputColorSpace.rec709SDR.matches(wrongMatrix, declaredInput: .automatic))
    }

    func testPixelFormatInferenceRecognizesSemiplanarAndHighDepthRGB() {
        for (format, expectedDepth, expectedChroma) in [
            ("p010le", 10, ChromaSubsampling.fourTwoZero),
            ("p016le", 16, .fourTwoZero),
            ("p210le", 10, .fourTwoTwo),
            ("rgb48le", 16, .fourFourFour)
        ] {
            let source = sourceVideo(format: format)
            XCTAssertEqual(source.bitDepth, expectedDepth, format)
            XCTAssertEqual(source.chromaSubsampling, expectedChroma, format)
        }
    }

    func testMissingTransferIsUnknownEvenWhenMatrixIsPresent() {
        let source = MediaStream(index: 0, kind: .video, codecName: "h264", width: 1920, height: 1080,
                                 sampleRate: nil, channels: nil, language: nil, colorSpace: "bt709")
        XCTAssertEqual(source.hdrDescription, "未标记")
    }

    private func plan(_ configuration: ExportConfiguration, source: MediaStream? = nil) -> ExportPlan {
        ExportPlan(configuration: configuration, editing: EditSettings(), sourceVideo: source)
    }

    private func sourceVideo(format: String) -> MediaStream {
        MediaStream(index: 0, kind: .video, codecName: "h264", width: 1920, height: 1080,
                    sampleRate: nil, channels: nil, language: nil, pixelFormat: format)
    }
}
