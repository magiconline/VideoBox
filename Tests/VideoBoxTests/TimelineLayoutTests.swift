import XCTest
@testable import VideoBox

final class TimelineLayoutTests: XCTestCase {
    func testMinimumClipWidthIsIncludedInScrollableContent() {
        let layout = TimelineLayout(durations: [1, 99], viewportWidth: 600)

        XCTAssertEqual(layout.segments[0].width, 24)
        XCTAssertGreaterThan(layout.contentWidth, 600)
        XCTAssertEqual(layout.contentWidth, layout.segments.last!.endX, accuracy: 0.000_001)
        XCTAssertEqual(layout.time(atX: layout.contentWidth), 100, accuracy: 0.000_001)
        XCTAssertEqual(layout.time(atX: layout.x(atTime: 99.9)), 99.9, accuracy: 0.000_001)
    }

    func testLongTimelineUsesContentCoordinatesForEveryVisibleRegion() {
        let layout = TimelineLayout(durations: Array(repeating: 1, count: 20), viewportWidth: 600)
        let scrollOffset = 900.0
        let visibleX = 300.0
        let contentX = scrollOffset + visibleX
        let rulerTime = layout.time(atX: contentX)

        XCTAssertGreaterThan(layout.contentWidth, 600)
        XCTAssertGreaterThan(rulerTime, 10)
        XCTAssertEqual(layout.x(atTime: rulerTime), contentX, accuracy: 0.000_001)
        XCTAssertEqual(layout.x(atTime: 20), layout.contentWidth, accuracy: 0.000_001)
    }

    func testScrubAndPlayheadRoundTripAcrossUnequalEditedClips() {
        // Four source seconds at 2x, then three seconds at 0.5x, plus a short cut.
        let layout = TimelineLayout(durations: [4 / 2, 3 / 0.5, 0.05], viewportWidth: 600)

        for time in [0, 0.01, 1.99, 2, 2.001, 4, 7.999, 8, 8.025, 8.05] {
            XCTAssertEqual(layout.time(atX: layout.x(atTime: time)), time, accuracy: 0.000_001)
        }
        XCTAssertEqual(layout.time(atX: -10), 0)
        XCTAssertEqual(layout.time(atX: layout.contentWidth + 10), 8.05, accuracy: 0.000_001)
    }

    func testSpacingResolvesToCutBoundaryWithoutInventingMediaTime() {
        let layout = TimelineLayout(durations: [2, 4], viewportWidth: 600)
        let gapMiddle = (layout.segments[0].endX + layout.segments[1].startX) / 2

        XCTAssertEqual(layout.time(atX: gapMiddle), 2)
        XCTAssertEqual(layout.x(atTime: 2), layout.segments[1].startX)
    }
}
