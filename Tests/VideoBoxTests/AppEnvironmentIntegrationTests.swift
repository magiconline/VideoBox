import AVFoundation
import Foundation
import XCTest
@testable import VideoBox

@MainActor
final class AppEnvironmentIntegrationTests: XCTestCase {
    func testQueuedExportRunsAutomaticallyWhenFFmpegIsAvailable() async throws {
        let locator = ExecutableLocator()
        guard let ffmpegURL = locator.locate(.ffmpeg) else {
            throw XCTSkip("FFmpeg is not installed")
        }

        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/videobox-smoke.mp4")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("Integration sample is unavailable")
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-queue-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.container = .mp4
        configuration.advanced.overwriteExisting = true
        let request = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            configuration: configuration,
            editing: EditSettings()
        )

        let environment = AppEnvironment(
            toolchainInspector: ToolchainInspector(
                locator: ExecutableLocator(
                    searchDirectories: [ffmpegURL.deletingLastPathComponent()]
                )
            )
        )
        await environment.refreshToolchain()
        let jobID = environment.enqueueExport(request)

        for _ in 0..<100 {
            if let job = environment.jobQueue.jobs.first(where: { $0.id == jobID }),
               job.state.isTerminal {
                guard case let .completed(outputURL) = job.state else {
                    XCTFail("Queued export ended in \(job.state.displayName)")
                    return
                }
                XCTAssertEqual(outputURL, destinationURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Queued export did not finish in time")
    }

    func testExternalTracksCanBeMuxedPreviewedAndExtracted() async throws {
        let locator = ExecutableLocator()
        guard let ffmpegURL = locator.locate(.ffmpeg),
              let ffprobeURL = locator.locate(.ffprobe) else {
            throw XCTSkip("FFmpeg and ffprobe are required")
        }

        let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = projectURL.appendingPathComponent("work/videobox-smoke.mp4")
        let subtitleURL = projectURL.appendingPathComponent("work/smoke-subtitle.srt")
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              FileManager.default.fileExists(atPath: subtitleURL.path) else {
            throw XCTSkip("Integration samples are unavailable")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-tracks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let externalMediaURL = temporaryDirectory.appendingPathComponent("external.mp4")
        try FileManager.default.copyItem(at: sourceURL, to: externalMediaURL)
        let probeEngine = FFprobeEngine(executableURL: ffprobeURL)
        let primaryProbe = try await probeEngine.probe(sourceURL)
        let externalProbe = try await probeEngine.probe(externalMediaURL)
        let subtitleProbe = try await probeEngine.probe(subtitleURL)
        XCTAssertNil(
            primaryProbe.streams.first(where: { $0.kind == .video })?.title,
            "Generic QuickTime handler names should not appear as editable track titles"
        )
        guard let externalVideo = externalProbe.streams.first(where: { $0.kind == .video }),
              let primaryAudio = primaryProbe.streams.first(where: { $0.kind == .audio }),
              let externalAudio = externalProbe.streams.last(where: { $0.kind == .audio }),
              let subtitle = subtitleProbe.streams.first(where: { $0.kind == .subtitle }) else {
            return XCTFail("Samples do not contain the expected tracks")
        }

        var videoTrack = TrackExportSettings(
            sourceURL: externalMediaURL,
            stream: externalVideo,
            sourceDuration: externalProbe.duration
        )
        videoTrack.title = "Picture"
        var externalAudioTrack = TrackExportSettings(
            sourceURL: externalMediaURL,
            stream: externalAudio,
            sourceDuration: externalProbe.duration
        )
        externalAudioTrack.title = "External first"
        externalAudioTrack.isDefault = true
        var primaryAudioTrack = TrackExportSettings(
            sourceURL: sourceURL,
            stream: primaryAudio,
            sourceDuration: primaryProbe.duration
        )
        primaryAudioTrack.title = "Primary second"
        primaryAudioTrack.isDefault = false
        let subtitleTrack = TrackExportSettings(
            sourceURL: subtitleURL,
            stream: subtitle,
            sourceDuration: subtitleProbe.duration
        )

        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.container = .mov
        configuration.subtitles.mode = .convert
        configuration.advanced.overwriteExisting = true
        configuration.trackSettings = [
            videoTrack,
            externalAudioTrack,
            primaryAudioTrack,
            subtitleTrack
        ]
        let outputURL = temporaryDirectory.appendingPathComponent("ordered.mov")
        let exportRequest = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            sourceDuration: primaryProbe.duration,
            configuration: configuration,
            editing: EditSettings()
        )
        _ = try await FFmpegExportEngine(executableURL: ffmpegURL).export(exportRequest)

        let outputProbe = try await probeEngine.probe(outputURL)
        XCTAssertEqual(outputProbe.streams.first(where: { $0.kind == .video })?.title, "Picture")
        XCTAssertEqual(
            outputProbe.streams.filter { $0.kind == .audio }.map(\.title),
            ["External first", "Primary second"]
        )
        XCTAssertEqual(outputProbe.streams.filter { $0.kind == .subtitle }.count, 1)

        let previewURL = temporaryDirectory.appendingPathComponent("preview.mov")
        let previewRequest = TrackPreviewRequest(
            primarySourceURL: sourceURL,
            destinationURL: previewURL,
            tracks: [videoTrack, externalAudioTrack, subtitleTrack],
            duration: min(2, primaryProbe.duration ?? 2),
            subtitleOffset: 0
        )
        let previewAsset = try await FFmpegTrackPreviewEngine(executableURL: ffmpegURL)
            .createPreview(previewRequest)
        let previewProbe = try await probeEngine.probe(previewAsset.mediaURL)
        XCTAssertEqual(previewProbe.streams.filter { $0.kind == .video }.count, 1)
        XCTAssertEqual(previewProbe.streams.filter { $0.kind == .audio }.count, 1)
        XCTAssertEqual(previewProbe.streams.filter { $0.kind == .subtitle }.count, 0)
        let isPreviewPlayable = await MediaPlaybackCompatibility.isPlayableVideo(
            at: previewAsset.mediaURL
        )
        XCTAssertTrue(isPreviewPlayable, "The generated preview must be accepted by AVFoundation")
        let previewSubtitleURL = try XCTUnwrap(previewAsset.subtitleURL)
        let previewCues = try SubtitleCueParser.parse(contentsOf: previewSubtitleURL)
        XCTAssertEqual(previewCues.count, 1)
        XCTAssertEqual(previewCues.first?.text, "VideoBox timeline smoke test")

        let extractedURL = temporaryDirectory.appendingPathComponent("extracted.srt")
        let extractionRequest = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: extractedURL,
            configuration: ExportConfiguration(),
            editing: EditSettings(),
            operation: .trackExtraction(subtitleTrack)
        )
        _ = try await FFmpegExportEngine(executableURL: ffmpegURL).export(extractionRequest)
        XCTAssertFalse(try String(contentsOf: extractedURL, encoding: .utf8).isEmpty)
    }
}
