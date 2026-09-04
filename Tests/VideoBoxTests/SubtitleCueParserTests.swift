import XCTest
@testable import VideoBox

final class SubtitleCueParserTests: XCTestCase {
    func testParsesSRTTimestampsTextAndFormatting() {
        let cues = SubtitleCueParser.parse(
            """
            1\r
            00:00:00,500 --> 00:00:03,500\r
            <i>Hello &amp; goodbye</i>\r
            \r
            2\r
            00:00:04.000 --> 00:00:08.000 align:center\r
            {\\an8}轨道与元数据测试\r
            """
        )

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SubtitleCue(startTime: 0.5, endTime: 3.5, text: "Hello & goodbye"))
        XCTAssertEqual(cues[1], SubtitleCue(startTime: 4, endTime: 8, text: "轨道与元数据测试"))
    }

    func testSkipsMalformedAndEmptyCues() {
        let cues = SubtitleCueParser.parse(
            """
            bad block

            1
            00:00:05,000 --> 00:00:04,000
            reversed

            2
            00:00:01,000 --> 00:00:02,000
            valid
            """
        )

        XCTAssertEqual(cues, [SubtitleCue(startTime: 1, endTime: 2, text: "valid")])
    }
}
