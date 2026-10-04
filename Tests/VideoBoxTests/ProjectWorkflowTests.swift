import AppKit
import XCTest
@testable import VideoBox

final class ProjectWorkflowTests: XCTestCase {
    func testTimecodeAndTrimValidation() throws {
        XCTAssertEqual(Timecode.parse("01:02:03.125"), 3723.125)
        XCTAssertEqual(Timecode.parse("02:03.5"), 123.5)
        XCTAssertNil(Timecode.parse("00:60:01")); XCTAssertNil(Timecode.parse("nan")); XCTAssertNil(Timecode.parse("-1"))
        XCTAssertEqual(Timecode.format(3723.125), "01:02:03.125")
        var editing = EditSettings(); editing.initialize(duration: 10, canvasWidth: 320, canvasHeight: 180)
        XCTAssertFalse(editing.trimSelected(start: 2, end: 12)); XCTAssertFalse(editing.trimSelected(start: 3, end: 3))
        XCTAssertTrue(editing.trimSelected(start: 2, end: 9)); XCTAssertEqual(editing.outputDuration, 7)
    }

    @MainActor func testProjectUndoRedoSaveAndRecoveryFallback() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = directory.appendingPathComponent("recovery.vboxproject")
        let session = ProjectSession(recoveryURL: recovery)
        var edit = EditSettings(); edit.initialize(duration: 10, canvasWidth: 320, canvasHeight: 180)
        let project = VideoBoxProject(sourceURL: directory.appendingPathComponent("source.mov"), editing: edit,
            configuration: ExportConfiguration(), outputFileName: "output.mp4")
        session.begin(project)
        session.editing.clips[0].volume = 0.5
        session.editing.clips[0].scale = 1.2
        XCTAssertTrue(session.canUndo); session.undo()
        XCTAssertEqual(session.editing.clips[0].volume, 1); XCTAssertEqual(session.editing.clips[0].scale, 1)
        session.redo(); XCTAssertEqual(session.editing.clips[0].scale, 1.2)
        let saved = directory.appendingPathComponent("edit.vboxproject")
        try session.save(to: saved); XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try VideoBoxProject.read(saved).editing, session.editing)
        try Data("corrupt".utf8).write(to: recovery)
        XCTAssertNotNil(session.recovery(), "Previous valid autosave must remain recoverable")
    }

    @MainActor func testProjectCannotOverwriteSourceOrHardlink() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov"), alias = directory.appendingPathComponent("alias.vboxproject")
        try Data("media".utf8).write(to: source); try FileManager.default.linkItem(at: source, to: alias)
        let session = ProjectSession(recoveryURL: directory.appendingPathComponent("recovery"))
        session.begin(VideoBoxProject(sourceURL: source, editing: EditSettings(), configuration: ExportConfiguration(), outputFileName: "out.mp4"))
        XCTAssertThrowsError(try session.save(to: alias)); XCTAssertEqual(try Data(contentsOf: source), Data("media".utf8))
    }

    @MainActor func testTrimAndAutomaticExportModeAreOneUndoStep() {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = ProjectSession(recoveryURL: directory.appendingPathComponent("recovery"))
        var edit = EditSettings(); edit.initialize(duration: 6, canvasWidth: 320, canvasHeight: 180)
        session.begin(VideoBoxProject(sourceURL: directory.appendingPathComponent("source.mp4"), editing: edit, configuration: ExportConfiguration(), outputFileName: "out.mp4"))
        session.editing.clips[0].sourceRange = TimelineRange(start: 2, duration: 4)
        session.configuration.mode = .transcode
        session.undo()
        XCTAssertEqual(session.editing.clips[0].sourceRange, TimelineRange(start: 0, duration: 6))
        XCTAssertEqual(session.configuration.mode, .streamCopy)
        session.redo(); XCTAssertEqual(session.editing.outputDuration, 4)
    }

    @MainActor func testQueuePauseRetryAndRestartRecovery() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("queue.json")
        let queue = JobQueue(persistenceURL: store)
        let request = MediaJobRequest(exportRequest: ExportRequest(sourceURL: directory, destinationURL: directory.appendingPathComponent("out.mp4"), configuration: ExportConfiguration(), editing: EditSettings()))
        let id = queue.enqueue(request)
        queue.update(id: id, state: .running(progress: nil)); queue.pause(id: id)
        XCTAssertEqual(queue.jobs[0].state, .paused(progress: 0))
        queue.resume(id: id); XCTAssertEqual(queue.jobs[0].state, .running(progress: 0))
        let restarted = JobQueue(persistenceURL: store)
        XCTAssertEqual(restarted.jobs[0].state, .paused(progress: nil))
        restarted.resume(id: id); XCTAssertEqual(restarted.jobs[0].state, .queued)
        restarted.update(id: id, state: .failed(message: "test")); restarted.retry(id: id)
        XCTAssertEqual(restarted.jobs[0].state, .queued)
    }

    func testTransitionTimelineAndSourceAwareMetadata() {
        var edit = EditSettings(); edit.initialize(duration: 4, canvasWidth: 320, canvasHeight: 180)
        edit.clips[0].sourceRange.duration = 2
        var second = EditSegment(sourceRange: TimelineRange(start: 0, duration: 2)); second.sourceURL = URL(fileURLWithPath: "/tmp/second.mp4")
        second.transition = ClipTransition(duration: 0.5)
        edit.clips.append(second)
        XCTAssertEqual(edit.clipStartTimes, [0, 1.5]); XCTAssertEqual(edit.outputDuration, 3.5)
        XCTAssertEqual(edit.location(atOutputTime: 1.6)?.clipID, second.id)
        XCTAssertEqual(TimedMetadataRemapper.ranges(start: 0, end: 1, editing: edit), [TimelineRange(start: 0, duration: 1)])
        let frames = [VisualKeyframe(time: 0, pose: VisualPose(scale: 1)), VisualKeyframe(time: 2, pose: VisualPose(scale: 3))]
        XCTAssertEqual(VisualKeyframe.interpolate(frames, at: 1).scale, 2)
    }

    func testNewPlayerCommandsRespectFocusModifiers() {
        XCTAssertEqual(PlayerInputCommand.resolve(keyCode: 115, characters: nil, modifiers: [], isRepeat: false), .boundary(true))
        XCTAssertEqual(PlayerInputCommand.resolve(keyCode: 0, characters: "l", modifiers: [], isRepeat: false), .toggleLoop)
        XCTAssertEqual(PlayerInputCommand.resolve(keyCode: 0, characters: "i", modifiers: [.shift], isRepeat: false), .setLoopBoundary(true))
        XCTAssertNil(PlayerInputCommand.resolve(keyCode: 0, characters: "i", modifiers: [.command], isRepeat: false))
    }
    private func temporaryDirectory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-workflow-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
    }
}
