import Foundation
import XCTest
@testable import VideoBox

final class AdvancedCompositionTests: XCTestCase {
    private var ffmpeg: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ffmpeg-runtime/arm64/bin/ffmpeg") }
    private var ffprobe: URL { ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe") }
    func testActualMultisourceTransitionLayerAndSilentSecondClip() async throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Runtime required") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-composition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let red = dir.appendingPathComponent("red.mp4"), blue = dir.appendingPathComponent("blue.mp4"), green = dir.appendingPathComponent("green.mp4")
        try await generate(red, color: "red", audio: true); try await generate(blue, color: "blue", audio: false); try await generate(green, color: "lime", audio: false)
        let probe = FFprobeEngine(executableURL: ffprobe)
        let a = try await probe.probe(red), b = try await probe.probe(blue), c = try await probe.probe(green)
        var edit = EditSettings(); edit.initialize(duration: 2, canvasWidth: 320, canvasHeight: 180); edit.clips[0].sourceRange.duration = 1
        edit.clips[0].volume = 0.1
        var second = EditSegment(sourceRange: TimelineRange(start: 0, duration: 1)); second.sourceURL = blue; second.media = ClipMedia(b); second.transition = ClipTransition(duration: 0.3)
        edit.clips.append(second)
        edit.overlayClips = [OverlayClip(sourceURL: green, media: ClipMedia(c), sourceRange: TimelineRange(start: 0, duration: 0.4), startTime: 0.2, pose: VisualPose(x: 0.5, y: 0.5, scale: 0.2))]
        var audioMedia = ClipMedia(a); audioMedia.video = nil
        edit.overlayClips.append(OverlayClip(sourceURL: red, media: audioMedia, sourceRange: TimelineRange(start: 0, duration: 0.4), startTime: 0.2, audioGain: 1))
        var config = settings(a); let output = dir.appendingPathComponent("out.mp4")
        let request = ExportRequest(sourceURL: red, destinationURL: output, sourceDuration: a.duration, sourceVideo: a.primaryVideoStream, configuration: config, editing: edit)
        XCTAssertTrue(ExportPlan(request: request).blockers.isEmpty)
        try await FFmpegExportEngine(executableURL: ffmpeg).export(request)
        let exported = try await probe.probe(output)
        XCTAssertEqual(exported.duration ?? 0, 1.7, accuracy: 0.06); XCTAssertTrue(exported.streams.contains { $0.kind == .audio })
        let first = try await pixel(output, at: 0.35, dir: dir), last = try await pixel(output, at: 1.4, dir: dir)
        XCTAssertGreaterThan(first[1], 170); XCTAssertLessThan(first[0], 60)
        XCTAssertGreaterThan(last[2], 170); XCTAssertLessThan(last[0], 60)
        let loud = try await audioRMS(output, at: 0.3, dir: dir), quiet = try await audioRMS(output, at: 0.65, dir: dir), silence = try await audioRMS(output, at: 1.4, dir: dir)
        XCTAssertGreaterThan(loud, quiet * 3); XCTAssertLessThan(silence, 0.001)
        var preview = RenderedPreviewRequest.make(request, at: 0.85, length: 0.5).request
        preview.destinationURL = dir.appendingPathComponent("preview.mp4")
        XCTAssertEqual(preview.editing.clips, edit.clips, "Composition preview must not restart transition or animation timing")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(preview)
        let previewProbe = try await probe.probe(preview.destinationURL)
        XCTAssertEqual(previewProbe.duration ?? 0, 0.5, accuracy: 0.06)
        config.mode = .streamCopy
        XCTAssertFalse(ExportPlan(configuration: config, editing: edit, sourceVideo: a.primaryVideoStream).blockers.isEmpty)
    }
    func testActualAnimatedPanMovesBetweenDifferentSourceRegions() async throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Runtime required") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-pan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("regions.mp4")
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2,drawbox=x=160:y=0:w=160:h=180:color=blue:t=fill", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", source.path]))
        XCTAssertTrue(result.succeeded, result.standardError)
        let info = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        var edit = EditSettings(); edit.initialize(duration: 2, canvasWidth: 320, canvasHeight: 180)
        edit.clips[0].keyframes = [VisualKeyframe(time: 0, pose: VisualPose(x: 0, scale: 2)), VisualKeyframe(time: 1.5, pose: VisualPose(x: 1, scale: 2))]
        let output = dir.appendingPathComponent("pan.mp4")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(ExportRequest(sourceURL: source, destinationURL: output, sourceDuration: 2, sourceVideo: info.primaryVideoStream, configuration: settings(info), editing: edit))
        let early = try await pixel(output, at: 0.1, dir: dir), late = try await pixel(output, at: 1.6, dir: dir)
        XCTAssertGreaterThan(early[0], 180); XCTAssertLessThan(early[2], 60)
        XCTAssertGreaterThan(late[2], 180); XCTAssertLessThan(late[0], 60)
    }
    func testActualCropGradingAndOpacityKeyframes() async throws {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Runtime required") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-animation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mp4")
        try await generate(source, color: "gray", audio: false)
        let info = try await FFprobeEngine(executableURL: ffprobe).probe(source)
        var edit = EditSettings(); edit.initialize(duration: 2, canvasWidth: 320, canvasHeight: 180)
        edit.clips[0].transform.crop = NormalizedCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        edit.clips[0].effects = ClipEffects(exposure: 0.5, temperature: 0.2)
        edit.clips[0].keyframes = [VisualKeyframe(time: 0, pose: VisualPose(opacity: 0.1)), VisualKeyframe(time: 1.5, pose: VisualPose(scale: 1.5, opacity: 1))]
        let output = dir.appendingPathComponent("out.mp4")
        try await FFmpegExportEngine(executableURL: ffmpeg).export(ExportRequest(sourceURL: source, destinationURL: output, sourceDuration: 2, sourceVideo: info.primaryVideoStream, configuration: settings(info), editing: edit))
        let early = try await pixel(output, at: 0.1, dir: dir), late = try await pixel(output, at: 1.6, dir: dir)
        XCTAssertGreaterThan(late[0], early[0] + 60); XCTAssertGreaterThan(late[0], late[2])
    }
    private func settings(_ probe: MediaProbe) -> ExportConfiguration {
        var config = ExportConfiguration(); config.mode = .transcode; config.video.codec = .h264; config.video.preset = .ultrafast
        config.video.allowUpscaling = true; config.audio.codec = .aac; config.subtitles.mode = .remove
        config.advanced.hardwareDecoding = false; config.containerOptions.preserveChapters = false
        config.trackSettings = probe.streams.map { TrackExportSettings(sourceURL: probe.sourceURL, stream: $0, sourceDuration: probe.duration) }
        return config
    }
    private func generate(_ url: URL, color: String, audio: Bool) async throws {
        var args = ["-v", "error", "-f", "lavfi", "-i", "color=c=\(color):s=320x180:r=30:d=2"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2"] }
        args += ["-t", "2", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", "-c:a", "aac", url.path]
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: args)); XCTAssertTrue(result.succeeded, result.standardError)
    }
    private func pixel(_ url: URL, at time: Double, dir: URL) async throws -> [Int] {
        let frame = dir.appendingPathComponent("frame-\(UUID().uuidString).rgb")
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: ["-v", "error", "-ss", "\(time)", "-i", url.path, "-vf", "crop=2:2:158:88", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", frame.path]))
        XCTAssertTrue(result.succeeded, result.standardError)
        let bytes = [UInt8](try Data(contentsOf: frame)); XCTAssertGreaterThanOrEqual(bytes.count, 3)
        return bytes.prefix(3).map(Int.init)
    }
    private func audioRMS(_ url: URL, at time: Double, dir: URL) async throws -> Double {
        let raw = dir.appendingPathComponent("audio-\(UUID().uuidString).f32")
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: ["-v", "error", "-ss", "\(time)", "-i", url.path, "-t", "0.05", "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", "-f", "f32le", raw.path]))
        XCTAssertTrue(result.succeeded, result.standardError)
        let values = try Data(contentsOf: raw).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertFalse(values.isEmpty)
        return sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, values.count)))
    }
}
