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
