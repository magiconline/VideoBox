import AVFoundation
import XCTest
@testable import VideoBox

@MainActor
final class PreviewTimelineTests: XCTestCase {
    func testCompositionUsesOutputTimeForReorderedDuplicatedAndRetimedClips() async throws {
        let url = try sampleURL()
        let first = EditSegment(sourceRange: TimelineRange(start: 6, duration: 2), playbackRate: 2)
        let second = EditSegment(sourceRange: TimelineRange(start: 1, duration: 2), playbackRate: 0.5, volume: 0.4)
        let duplicate = EditSegment(sourceRange: first.sourceRange, playbackRate: first.playbackRate)
        var editing = EditSettings()
        editing.clips = [first, second, duplicate]
        editing.sourceDuration = 10
        let preview = try await PreviewTimelineBuilder.make(asset: AVURLAsset(url: url), editing: editing)
        XCTAssertEqual(preview.duration, 6, accuracy: 0.00001)
        let duration = try await preview.asset.load(.duration)
        XCTAssertEqual(duration.seconds, editing.outputDuration, accuracy: 0.00001)
        let tracks = try await preview.asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first as? AVCompositionTrack)
        let segments = try await track.load(.segments)
        XCTAssertEqual(segments.count, 3)
        for (index, expected) in editing.clips.enumerated() {
            XCTAssertEqual(segments[index].timeMapping.source.start.seconds, expected.sourceRange.start, accuracy: 0.00001)
            XCTAssertEqual(segments[index].timeMapping.target.start.seconds, editing.outputStart(of: expected.id)!, accuracy: 0.00001)
            XCTAssertEqual(segments[index].timeMapping.target.duration.seconds, expected.outputDuration, accuracy: 0.00001)
        }
        let audio = try await preview.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "Do not mix all original audio tracks by accident")
        XCTAssertNotNil(preview.audioMix)
        XCTAssertEqual(editing.location(atOutputTime: 5.5)?.clipID, duplicate.id)
        XCTAssertEqual(editing.location(atOutputTime: 5.5)?.sourceTime, 7)
    }

    func testControllerClampsDeletedFootageAndKeepsMonitoringIndependent() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        controller.load(url: try sampleURL())
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1280, canvasHeight: 720)
        editing.clips[0].sourceRange = TimelineRange(start: 3, duration: 2)
        editing.clips[0].volume = 0.6
        controller.updateTimeline(editing: editing)
        try await waitUntil { !controller.isPreparingTimeline }
        XCTAssertNil(controller.playbackErrorMessage)
        XCTAssertEqual(controller.outputDuration, 2, accuracy: 0.00001)
        controller.seekOutput(to: 8)
        XCTAssertEqual(controller.outputTime, 2)
        XCTAssertEqual(controller.currentTime, 5)
        controller.skip(by: -5)
        XCTAssertEqual(controller.outputTime, 0)
        XCTAssertEqual(controller.currentTime, 3)
        controller.monitoringVolume = 0.25
        controller.toggleMonitoringMute()
        XCTAssertTrue(controller.player.isMuted)
        XCTAssertEqual(controller.player.volume, 0.25)
        XCTAssertEqual(controller.activeClip?.volume, 0.6)
        controller.monitoringVolume = 4
        XCTAssertEqual(controller.monitoringVolume, 1)
        controller.adjustMonitoringVolume(by: -5)
        XCTAssertEqual(controller.monitoringVolume, 0)
    }

    func testPlaybackStopsAtEditedEndAndScrubbingResumesOnlyWhenPreviouslyPlaying() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        controller.load(url: try sampleURL())
        var editing = EditSettings()
        editing.clips = [EditSegment(sourceRange: TimelineRange(start: 2, duration: 0.5))]
        controller.updateTimeline(editing: editing)
        try await waitUntil { !controller.isPreparingTimeline && controller.player.currentItem?.status == .readyToPlay }
        controller.play()
        try await waitUntil { controller.isPlaying }
        controller.beginScrubbing()
        controller.seekOutput(to: 0.1)
        XCTAssertFalse(controller.isPlaying)
        controller.endScrubbing()
        try await waitUntil { controller.isPlaying }
        try await waitUntil { !controller.isPlaying && controller.outputTime >= 0.49 }
        XCTAssertEqual(controller.outputTime, 0.5, accuracy: 0.00001)
        controller.beginScrubbing()
        controller.seekOutput(to: 0.1)
        controller.endScrubbing()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isPlaying)
    }

    func testNativeFrameStepUsesActualSamplesAndRemainsPaused() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        controller.load(url: try sampleURL())
        var editing = EditSettings()
        editing.clips = [EditSegment(sourceRange: TimelineRange(start: 1, duration: 2))]
        controller.updateTimeline(editing: editing)
        try await waitUntil { !controller.isPreparingTimeline && controller.player.currentItem?.status == .readyToPlay }
        controller.seekOutput(to: 0.5)
        try await waitUntil { abs(controller.player.currentTime().seconds - 0.5) < 0.0001 }
        try await Task.sleep(for: .milliseconds(100))
        controller.stepFrame(1)
        try await waitUntil { controller.outputTime > 0.51 }
        XCTAssertEqual(controller.outputTime, 0.5 + 1.0 / 30, accuracy: 0.002)
        controller.stepFrame(-1)
        try await waitUntil { controller.outputTime < 0.51 }
        XCTAssertEqual(controller.outputTime, 0.5, accuracy: 0.002)
        XCTAssertFalse(controller.isPlaying)
    }

    func testNewTimelineWinsOverAnInFlightRebuild() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        controller.load(url: try sampleURL())
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1280, canvasHeight: 720)
        controller.updateTimeline(editing: editing)
        editing.clips[0].sourceRange = TimelineRange(start: 7, duration: 1)
        controller.updateTimeline(editing: editing)
        controller.seekOutput(to: 0.6)
        try await waitUntil { !controller.isPreparingTimeline }
        XCTAssertEqual(controller.outputDuration, 1)
        XCTAssertEqual(controller.outputTime, 0.6)
        XCTAssertEqual(controller.currentTime, 7.6)
    }

    func testCompositionTimeRoundingDoesNotSelectWrongSideOfCut() {
        var editing = EditSettings()
        editing.initialize(duration: 12, canvasWidth: nil, canvasHeight: nil)
        let right = editing.split(atOutputTime: 7.929934199)
        XCTAssertEqual(editing.location(atOutputTime: 7.929933333333334)?.clipID, right)
        XCTAssertEqual(editing.location(atOutputTime: 7.9)?.clipID, editing.clips.first?.id)
    }

    func testScrubbingToEndDoesNotRestartPlayback() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        controller.load(url: try sampleURL())
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: nil, canvasHeight: nil)
        controller.updateTimeline(editing: editing)
        try await waitUntil { !controller.isPreparingTimeline && controller.player.currentItem?.status == .readyToPlay }
        controller.play()
        try await waitUntil { controller.isPlaying }
        controller.beginScrubbing()
        controller.seekOutput(to: 10)
        controller.endScrubbing()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.outputTime, 10, accuracy: 0.001)
    }

    func testRepeatedToggleDuringRebuildCancelsPlayIntentAndReloadResetsScrubbing() async throws {
        let controller = PlayerController()
        defer { controller.clear() }
        let url = try sampleURL()
        controller.load(url: url)
        controller.togglePlayback()
        controller.togglePlayback()
        try await waitUntil { !controller.isPreparingTimeline }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isPlaying)
        controller.beginScrubbing()
        controller.load(url: url)
        try await waitUntil { !controller.isPreparingTimeline && controller.player.currentItem?.status == .readyToPlay }
        controller.play()
        try await waitUntil { controller.isPlaying }
    }

    private func sampleURL() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/videobox-smoke.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Integration video is unavailable") }
        return url
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Playback condition timed out", file: file, line: line)
    }
}
