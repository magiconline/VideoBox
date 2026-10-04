import AVFoundation
import XCTest
@testable import VideoBox

final class PreviewFrameNavigatorTests: XCTestCase {
    func testVariablePresentationTimesDoNotAssumeConstantFrameDuration() throws {
        let editing = timeline([clip(0, 1)])
        XCTAssertEqual(try destination(editing, 0.1, 1), 0.2, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.2, 1), 0.36, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.2, -1), 0.1, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.25, 1), 0.36, accuracy: 0.000001)
    }

    func testTrimInsideAFrameRetainsItsClippedBeginningAndExcludesEnd() throws {
        let editing = timeline([clip(0.05, 0.4)])
        XCTAssertEqual(try destination(editing, 0, 1), 0.05, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.05, -1), 0, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.15, 1), 0.31, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.31, 1), 0.31, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.4, -1), 0.31, accuracy: 0.000001)
    }

    func testReorderDuplicateAndSpeedChangesCrossOutputClipBoundaries() throws {
        let editing = timeline([clip(0.5, 0.5, rate: 2), clip(0, 0.36, rate: 0.5), clip(0.5, 0.5, rate: 2)])
        XCTAssertEqual(try destination(editing, 0.1, 1), 0.225, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.225, 1), 0.25, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.25, -1), 0.225, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.25, 1), 0.33, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.65, 1), 0.97, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.97, -1), 0.65, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 1.22, -1), 1.195, accuracy: 0.000001)
    }

    func testStartEndAndDuplicateTimestampsDoNotEscapeTheTimeline() throws {
        let editing = timeline([clip(0, 1)])
        XCTAssertEqual(try destination(editing, 0, -1), 0, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.95, 1), 0.95, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 1, 1), 0.95, accuracy: 0.000001)
        let duplicated = [0.0, 0.1, 0.1, 0.2]
        XCTAssertEqual(try destination(editing, 0.1, -1, samples: duplicated), 0, accuracy: 0.000001)
        XCTAssertEqual(try destination(editing, 0.1, 1, samples: duplicated), 0.2, accuracy: 0.000001)
    }

    func testInvalidInputAndMissingSamplesProduceExplicitErrors() throws {
        let editing = timeline([clip(0, 1)])
        XCTAssertThrowsError(try destination(editing, .nan, 1))
        XCTAssertThrowsError(try destination(editing, 0, 0))
        XCTAssertThrowsError(try PreviewFrameNavigator.destination(
            editing: editing, outputTime: 0, direction: 1,
            sampleRange: TimelineRange(start: 0, duration: 1), makeCursor: { _ in nil }
        )) { error in
            XCTAssertEqual(error.localizedDescription, PreviewFrameNavigationError.noVideoSamples.localizedDescription)
        }
    }

    func testRealSampleCursorStepsTheThirtyFPSFixtureWithoutAPlayerLayer() async throws {
        let url = repositoryURL.appendingPathComponent("work/videobox-smoke.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local video fixture is absent") }
        let editing = timeline([clip(1, 2)])
        let forward = try await PreviewFrameNavigator.destination(sourceURL: url, editing: editing, outputTime: 0.5, direction: 1)
        XCTAssertEqual(forward, 0.5 + 1.0 / 30, accuracy: 0.00001)
        let backward = try await PreviewFrameNavigator.destination(sourceURL: url, editing: editing, outputTime: forward, direction: -1)
        XCTAssertEqual(backward, 0.5, accuracy: 0.00001)
    }

    func testRealVariableFrameRateAssetUsesPresentationOrder() async throws {
        let ffmpeg = repositoryURL.appendingPathComponent(".build/ffmpeg-runtime/arm64/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("Bundled fixture generator is absent") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-FrameNavigator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("variable-frame-rate.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=1",
            "-vf", "setpts='if(lt(N,5),N,5+(N-5)*2)'",
            "-fps_mode", "vfr", "-c:v", "libx264", "-bf", "2", "-threads", "1", url.path
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        guard process.terminationStatus == 0 else { return }
        let editing = timeline([clip(0, 1.4)])
        let next = try await PreviewFrameNavigator.destination(sourceURL: url, editing: editing, outputTime: 0.5, direction: 1)
        XCTAssertEqual(next, 0.7, accuracy: 0.00001)
        let previous = try await PreviewFrameNavigator.destination(sourceURL: url, editing: editing, outputTime: 0.7, direction: -1)
        XCTAssertEqual(previous, 0.5, accuracy: 0.00001)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func clip(_ start: Double, _ duration: Double, rate: Double = 1) -> EditSegment {
        EditSegment(sourceRange: TimelineRange(start: start, duration: duration), playbackRate: rate)
    }

    private func timeline(_ clips: [EditSegment]) -> EditSettings {
        var editing = EditSettings()
        editing.clips = clips
        return editing
    }

    private func destination(
        _ editing: EditSettings, _ time: Double, _ direction: Int,
        samples: [Double] = [0, 0.04, 0.1, 0.2, 0.36, 0.5, 0.7, 0.95]
    ) throws -> Double {
        try PreviewFrameNavigator.destination(
            editing: editing, outputTime: time, direction: direction,
            sampleRange: TimelineRange(start: 0, duration: 1),
            makeCursor: { FakeCursor(samples: samples, time: $0) }
        )
    }

    private final class FakeCursor: PreviewFrameSampleCursor {
        let samples: [Double]
        var index: Int
        init(samples: [Double], time: Double) {
            self.samples = samples
            index = samples.lastIndex(where: { $0 <= time + 0.0000001 }) ?? 0
        }
        var presentationSeconds: Double { samples[index] }
        func advance(_ direction: Int) -> Bool {
            let next = index + direction
            guard samples.indices.contains(next) else { return false }
            index = next
            return true
        }
    }
}
