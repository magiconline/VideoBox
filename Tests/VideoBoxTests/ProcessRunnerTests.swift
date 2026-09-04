import Foundation
import XCTest
@testable import VideoBox

final class ProcessRunnerTests: XCTestCase {
    func testCancellationTerminatesRunningProcess() async throws {
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(
                CLICommand(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"]
                )
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled command must not run to completion")
        } catch is CancellationError {
            // Expected.
        }
    }
}
