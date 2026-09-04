import Foundation
import XCTest
@testable import VideoBox

final class ToolchainInspectorTests: XCTestCase {
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
