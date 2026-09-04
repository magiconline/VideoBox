import Foundation
import XCTest
@testable import VideoBox

final class ToolchainInspectorTests: XCTestCase {
    func testBundledExecutableTakesPriorityOverPath() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundle = temporaryDirectory.appendingPathComponent("VideoBox.app", isDirectory: true)
        let bundledDirectory = appBundle
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
        let pathDirectory = temporaryDirectory.appendingPathComponent("path-bin", isDirectory: true)
        let bundledFFmpeg = bundledDirectory.appendingPathComponent("ffmpeg")
        let pathFFmpeg = pathDirectory.appendingPathComponent("ffmpeg")

        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(
            at: bundledDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pathDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: bundledFFmpeg.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: pathFFmpeg.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledFFmpeg.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pathFFmpeg.path
        )

        let locator = ExecutableLocator(
            environment: ["PATH": pathDirectory.path],
            bundleURL: appBundle
        )

        XCTAssertEqual(locator.locate(.ffmpeg), bundledFFmpeg)
    }

    func testMissingExecutableReturnsNil() {
        let locator = ExecutableLocator(
            searchDirectories: [URL(fileURLWithPath: "/definitely/not/a/video/tool/path")]
        )

        XCTAssertNil(locator.locate(.ffmpeg))
    }

    func testUncheckedReportContainsEveryTool() {
        XCTAssertEqual(ToolchainReport.unchecked.entries.count, CLITool.allCases.count)
        XCTAssertEqual(Set(CLITool.allCases.map(\.rawValue)), ["ffmpeg", "ffprobe"])
        XCTAssertNil(ToolchainReport.unchecked.checkedAt)
    }
}
