import Foundation
import XCTest
@testable import VideoBox

final class JobQueueTests: XCTestCase {
    @MainActor
    func testEnqueueAndCancel() {
        let queue = JobQueue()
        let request = makeRequest(mode: .streamCopy)

        let id = queue.enqueue(request)

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.id, id)
        XCTAssertEqual(queue.jobs.first?.state, .queued)

        queue.cancel(id: id)
        XCTAssertEqual(queue.jobs.first?.state, .cancelled)
    }

    @MainActor
    func testClearFinishedKeepsPendingJobs() {
        let queue = JobQueue()
        let completedID = queue.enqueue(makeRequest(mode: .transcode, outputName: "first.mp4"))
        queue.enqueue(makeRequest(mode: .streamCopy, outputName: "second.mkv"))
        queue.update(id: completedID, state: .completed(outputURL: nil))

        queue.clearFinished()

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.request.exportMode, .streamCopy)
    }

    @MainActor
    func testLateProgressDoesNotReviveCancellingOrCompletedJob() {
        let queue = JobQueue()
        queue.onCancel = { _ in }
        let id = queue.enqueue(makeRequest(mode: .transcode))
        queue.update(id: id, state: .running(progress: nil))
        queue.updateProgress(id: id, progress: 0.4)
        XCTAssertEqual(queue.jobs.first?.state, .running(progress: 0.4))
        queue.cancel(id: id)
        queue.updateProgress(id: id, progress: 0.8)
        XCTAssertEqual(queue.jobs.first?.state, .cancelling)
        queue.update(id: id, state: .completed(outputURL: nil))
        queue.updateProgress(id: id, progress: 0.9)
        XCTAssertEqual(queue.jobs.first?.state, .completed(outputURL: nil))
    }

    private func makeRequest(
        mode: ExportMode,
        outputName: String = "output.mp4"
    ) -> MediaJobRequest {
        var configuration = ExportConfiguration()
        configuration.mode = mode
        return MediaJobRequest(
            exportRequest: ExportRequest(
                sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                destinationURL: URL(fileURLWithPath: "/tmp/\(outputName)"),
                configuration: configuration,
                editing: EditSettings()
            )
        )
    }
}
