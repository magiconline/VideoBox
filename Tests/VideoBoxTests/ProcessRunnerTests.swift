import Foundation
import XCTest
@testable import VideoBox

final class ProcessRunnerTests: XCTestCase {
    func testReportsStandardOutputBeforeProcessExits() async throws {
        let outputReceived = expectation(description: "Output is streamed before process exits")
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(
                CLICommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 'out_time_us=1000000\\nprogress=continue\\n'; sleep 2"]
                ),
                onStandardOutput: { chunk in
                    if chunk.contains("progress=continue") {
                        outputReceived.fulfill()
                    }
                }
            )
        }
        await fulfillment(of: [outputReceived], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled streaming command should throw")
        } catch is CancellationError {
            // Output arrived while the process was running.
        }
    }

    func testCancellationEscalatesWhenProcessIgnoresTerminate() async throws {
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(CLICommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("SIGTERM-resistant process should be killed")
        } catch is CancellationError {
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(3))
        }
    }

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
