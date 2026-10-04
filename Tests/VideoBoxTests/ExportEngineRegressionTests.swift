import Foundation
import XCTest
@testable import VideoBox

final class ExportEngineRegressionTests: XCTestCase {
    func testEngineRejectsSourceAsDestinationEvenWhenOverwriteIsEnabled() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-protected-\(UUID().uuidString).mp4")
        let original = Data("original media".utf8)
        try original.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var configuration = ExportConfiguration()
        configuration.advanced.overwriteExisting = true
        let runner = PartialOutputRunner()
        let engine = FFmpegExportEngine(executableURL: URL(fileURLWithPath: "/usr/bin/false"), runner: runner)
        let request = ExportRequest(sourceURL: source, destinationURL: source, configuration: configuration, editing: EditSettings())
        do {
            _ = try await engine.export(request)
            XCTFail("An export must never overwrite its input")
        } catch let error as ExportValidationError {
            XCTAssertTrue(error.blockers.contains(where: { $0.contains("不能覆盖源视频") }))
        }
        let launchedOutput = await runner.outputURL
        XCTAssertNil(launchedOutput, "Validation must run before launching the encoder")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancellingExportPreservesExistingDestinationAndRemovesPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-cancel-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("existing.mp4")
        let original = Data("previous successful export".utf8)
        try Data("input".utf8).write(to: source)
        try original.write(to: destination)
        var settings = ExportConfiguration()
        settings.mode = .transcode
        settings.advanced.overwriteExisting = true
        let request = ExportRequest(sourceURL: source, destinationURL: destination,
                                    configuration: settings, editing: EditSettings())
        let runner = PartialOutputRunner()
        let engine = FFmpegExportEngine(executableURL: URL(fileURLWithPath: "/usr/bin/false"), runner: runner)
        let task = Task { try await engine.export(request) }
        for _ in 0..<100 {
            if await runner.outputURL != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let partial = await runner.outputURL
        XCTAssertNotNil(partial)
        XCTAssertNotEqual(partial, destination)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled export must throw")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: destination), original)
            if let partial { XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path)) }
        }
    }

    func testActualEngineExportsSilentCopyEven480pAndAV1() async throws {
        let toolsDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/VideoBox.app/Contents/Helpers")
        let ffmpeg = toolsDirectory.appendingPathComponent("ffmpeg")
        let ffprobe = toolsDirectory.appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            throw XCTSkip("Packaged FFmpeg runtime is required for export regression checks")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-export-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        let generated = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000", "-t", "0.5",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", sourceURL.path
        ]))
        XCTAssertTrue(generated.succeeded, generated.standardError)
        let probeEngine = FFprobeEngine(executableURL: ffprobe)
        let source = try await probeEngine.probe(sourceURL)
        let engine = FFmpegExportEngine(executableURL: ffmpeg)
        var settings = ExportConfiguration()
        settings.audio.codec = .none
        settings.advanced.hardwareDecoding = false
        settings.trackSettings = source.streams.map { TrackExportSettings(sourceURL: sourceURL, stream: $0, sourceDuration: source.duration) }

        func request(_ name: String) -> ExportRequest {
            ExportRequest(sourceURL: sourceURL, destinationURL: directory.appendingPathComponent(name),
                          sourceDuration: source.duration, sourceVideo: source.primaryVideoStream,
                          configuration: settings, editing: EditSettings())
        }

        let silentURL = try await engine.export(request("silent.mp4"))
        let silent = try await probeEngine.probe(silentURL)
        XCTAssertEqual(silent.streams.map(\.kind), [.video])
        XCTAssertEqual(silent.primaryVideoStream?.codecName, "h264")
        let sourceHash = try await videoPacketHash(url: sourceURL, ffmpeg: ffmpeg)
        let silentHash = try await videoPacketHash(url: silentURL, ffmpeg: ffmpeg)
        XCTAssertEqual(sourceHash, silentHash, "Quick export must preserve video packets exactly")

        settings.mode = .transcode
        settings.video.codec = .h264
        settings.video.preset = .ultrafast
        settings.video.resolution = .sd480
        let scaledURL = try await engine.export(request("480p.mp4"))
        let scaled = try await probeEngine.probe(scaledURL)
        XCTAssertEqual(scaled.primaryVideoStream?.width, 854)
        XCTAssertEqual(scaled.primaryVideoStream?.height, 480)
        XCTAssertEqual(scaled.primaryVideoStream?.pixelFormat, "yuv420p")

        settings.container = .webm
        settings.video.codec = .av1
        settings.video.preset = .medium
        settings.video.profile = .main
        settings.video.rateControl = .constantQuality
        settings.video.quality = 50
        let av1URL = try await engine.export(request("av1.webm"))
        let av1 = try await probeEngine.probe(av1URL)
        XCTAssertEqual(av1.primaryVideoStream?.codecName, "av1")
        XCTAssertEqual(av1.primaryVideoStream?.codecProfile, "Main")
        XCTAssertEqual(av1.primaryVideoStream?.bitDepth, 8)
        XCTAssertEqual(av1.primaryVideoStream?.chromaSubsampling, .fourTwoZero)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".VideoBox-") }))
    }

    private func videoPacketHash(url: URL, ffmpeg: URL) async throws -> String {
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: [
            "-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"
        ]))
        XCTAssertTrue(result.succeeded, result.standardError)
        return result.standardOutput
    }
}

private actor PartialOutputRunner: CLIProcessRunning {
    private(set) var outputURL: URL?

    func run(_ command: CLICommand) async throws -> CLIResult {
        let output = URL(fileURLWithPath: try XCTUnwrap(command.arguments.last))
        try Data("incomplete new export".utf8).write(to: output)
        outputURL = output
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
