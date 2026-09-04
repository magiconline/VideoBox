import XCTest
@testable import VideoBox

final class EditTimelineTests: XCTestCase {
    func testSplitCreatesTwoSourceRangesAtPlayhead() {
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1_280, canvasHeight: 720)

        let rightID = editing.split(atOutputTime: 4)

        XCTAssertNotNil(rightID)
        XCTAssertEqual(editing.clips.count, 2)
        XCTAssertEqual(editing.clips[0].sourceRange, TimelineRange(start: 0, duration: 4))
        XCTAssertEqual(editing.clips[1].sourceRange, TimelineRange(start: 4, duration: 6))
        XCTAssertEqual(editing.selectedClipID, rightID)
    }

    func testTimelineLocationAccountsForClipSpeed() {
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1_280, canvasHeight: 720)
        editing.clips[0].playbackRate = 2

        let location = editing.location(atOutputTime: 2)

        XCTAssertEqual(editing.outputDuration, 5, accuracy: 0.000_1)
        XCTAssertEqual(location?.sourceTime ?? -1, 4, accuracy: 0.000_1)
    }

    func testDuplicateDeleteAndMovePreserveValidSelection() {
        var editing = EditSettings()
        editing.initialize(duration: 12, canvasWidth: 1_920, canvasHeight: 1_080)
        XCTAssertNotNil(editing.split(atOutputTime: 4))
        let duplicatedID = editing.duplicateSelectedClip()

        XCTAssertEqual(editing.clips.count, 3)
        XCTAssertEqual(editing.selectedClipID, duplicatedID)

        editing.moveSelectedClip(by: -1)
        XCTAssertEqual(editing.clips[1].id, duplicatedID)

        editing.deleteSelectedClip()
        XCTAssertEqual(editing.clips.count, 2)
        XCTAssertNotNil(editing.selectedClip)
    }

    func testDragMoveCanSwapTwoClipsInEitherDirection() {
        var editing = EditSettings()
        editing.initialize(duration: 10, canvasWidth: 1_920, canvasHeight: 1_080)
        XCTAssertNotNil(editing.split(atOutputTime: 4))
        let originalOrder = editing.clips.map(\.id)

        editing.moveClip(originalOrder[0], to: originalOrder[1])
        XCTAssertEqual(editing.clips.map(\.id), [originalOrder[1], originalOrder[0]])

        editing.moveClip(originalOrder[0], to: originalOrder[1])
        XCTAssertEqual(editing.clips.map(\.id), originalOrder)
    }

    func testHDRAndBitDepthDescriptionsUseProbeFields() {
        let stream = MediaStream(
            index: 0,
            kind: .video,
            codecName: "hevc",
            width: 3_840,
            height: 2_160,
            sampleRate: nil,
            channels: nil,
            language: nil,
            pixelFormat: "yuv420p10le",
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020"
        )

        XCTAssertEqual(stream.bitDepth, 10)
        XCTAssertEqual(stream.hdrDescription, "HDR10 / PQ")
    }
}
