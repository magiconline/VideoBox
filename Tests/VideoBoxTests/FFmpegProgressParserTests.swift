import XCTest
@testable import VideoBox

final class FFmpegProgressParserTests: XCTestCase {
    func testReadsFragmentedProgressRecordsAndDoesNotRegress() {
        let parser = FFmpegProgressParser(duration: 10)
        XCTAssertNil(parser.consume("frame=12\nout_time_us=25"))
        XCTAssertEqual(parser.consume("00000\nprogress=continue\n"), 0.25)
        XCTAssertEqual(parser.consume("out_time_us=1000000\nprogress=continue\n"), 0.25)
        XCTAssertEqual(parser.consume("out_time_us=10000000\nprogress=end\n"), 0.999)
    }

    func testUnknownDurationDoesNotInventPercentage() {
        let durations: [Double?] = [nil, 0, -.infinity, .nan]
        for duration in durations {
            let parser = FFmpegProgressParser(duration: duration)
            XCTAssertNil(parser.consume("out_time_us=1000000\nprogress=continue\n"))
        }
    }

    func testHistoricalMicrosecondsFieldAndInvalidTimestamp() {
        let parser = FFmpegProgressParser(duration: 4)
        XCTAssertNil(parser.consume("out_time_ms=N/A\nprogress=continue\n"))
        XCTAssertEqual(parser.consume("out_time_ms=2000000\nprogress=continue\n"), 0.5)
    }
}
