import Foundation
import XCTest
@testable import VideoBox

@MainActor
final class AppEnvironmentIntegrationTests: XCTestCase {
    func testQueuedExportRunsAutomaticallyWhenFFmpegIsAvailable() async throws {
        let locator = ExecutableLocator()
        guard let ffmpegURL = locator.locate(.ffmpeg) else {
            throw XCTSkip("FFmpeg is not installed")
        }

        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/videobox-smoke.mp4")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("Integration sample is unavailable")
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-queue-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.container = .mp4
        configuration.advanced.overwriteExisting = true
        let request = ExportRequest(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            configuration: configuration,
            editing: EditSettings()
        )

        let environment = AppEnvironment(
            toolchainInspector: ToolchainInspector(
                locator: ExecutableLocator(
                    searchDirectories: [ffmpegURL.deletingLastPathComponent()]
                )
            )
        )
        await environment.refreshToolchain()
        let jobID = environment.enqueueExport(request)

        for _ in 0..<100 {
            if let job = environment.jobQueue.jobs.first(where: { $0.id == jobID }),
               job.state.isTerminal {
                guard case let .completed(outputURL) = job.state else {
                    XCTFail("Queued export ended in \(job.state.displayName)")
                    return
                }
                XCTAssertEqual(outputURL, destinationURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Queued export did not finish in time")
    }
}
