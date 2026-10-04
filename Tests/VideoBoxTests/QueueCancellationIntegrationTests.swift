import Darwin
import Foundation
import XCTest
@testable import VideoBox

final class QueueCancellationIntegrationTests: XCTestCase {
    @MainActor
    func testCancelTerminatesWriterBeforeNextQueuedJobStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-QueueTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidURL = directory.appendingPathComponent("writer.pid")
        let firstURL = directory.appendingPathComponent("first.mp4")
        let nextURL = directory.appendingPathComponent("next.mp4")
        let runner = ProcessRunner()
        let environment = AppEnvironment { request, onProgress in
            if request.destinationURL == firstURL {
                _ = try await runner.run(CLICommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "echo $$ > \"$1\"; while :; do printf x >> \"$2\"; sleep 0.02; done",
                        "queue-test", pidURL.path, firstURL.path
                    ]
                ))
            } else {
                let pid = Int32(try String(contentsOf: pidURL).trimmingCharacters(in: .whitespacesAndNewlines))!
                guard Darwin.kill(pid, 0) != 0 else {
                    throw NSError(domain: "QueueTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Previous export still running"])
                }
                onProgress(0.5)
                try Data("complete".utf8).write(to: request.destinationURL)
            }
            return request.destinationURL
        }
        let firstID = environment.enqueueExport(makeRequest(destination: firstURL))
        let nextID = environment.enqueueExport(makeRequest(destination: nextURL))
        defer {
            environment.jobQueue.cancel(id: firstID)
            environment.jobQueue.cancel(id: nextID)
        }

        try await waitUntil("writer launch", diagnostics: { String(describing: environment.jobQueue.jobs.map(\.state)) }) {
            FileManager.default.fileExists(atPath: firstURL.path)
        }
        environment.jobQueue.cancel(id: firstID)
        XCTAssertEqual(environment.jobQueue.jobs.first?.state, .cancelling)
        try await waitUntil("cancelled writer and next job completion", diagnostics: { String(describing: environment.jobQueue.jobs.map(\.state)) }) {
            environment.jobQueue.jobs.allSatisfy { $0.state.isTerminal }
        }

        XCTAssertEqual(environment.jobQueue.jobs.first?.state, .cancelled)
        XCTAssertEqual(environment.jobQueue.jobs.last?.state, .completed(outputURL: nextURL))
        let lengthAfterCancellation = try Data(contentsOf: firstURL).count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: firstURL).count, lengthAfterCancellation)
    }

    @MainActor
    func testCancellingQueuedJobNeverStartsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-QueueTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.mp4")
        let environment = AppEnvironment { request, _ in
            try Data("unexpected".utf8).write(to: request.destinationURL)
            return request.destinationURL
        }
        let id = environment.enqueueExport(makeRequest(destination: destination))
        environment.jobQueue.cancel(id: id)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(environment.jobQueue.jobs.first?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    private func waitUntil(_ description: String, diagnostics: () -> String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description): \(diagnostics())", file: file, line: line)
                throw NSError(domain: "QueueTestTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeRequest(destination: URL) -> ExportRequest {
        ExportRequest(
            sourceURL: destination.deletingLastPathComponent().appendingPathComponent("source.mov"),
            destinationURL: destination,
            sourceDuration: 10,
            configuration: ExportConfiguration(),
            editing: EditSettings()
        )
    }
}
