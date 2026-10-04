import Foundation
import XCTest
@testable import VideoBox

final class ColorPipelineTests: XCTestCase {
    func testParsesThreeDimensionalCubeIntoRGBAFloatData() throws {
        let cube = """
        TITLE "Tiny test LUT"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        let lut = try CubeLUT.parse(cube)

        XCTAssertEqual(lut.stages.first?.size, 2)
        XCTAssertEqual(lut.title, "Tiny test LUT")
        XCTAssertEqual(lut.stages.first?.rgbaData.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
    }

    func testRejectsIncompleteCube() {
        let cube = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        """

        XCTAssertThrowsError(try CubeLUT.parse(cube)) { error in
            XCTAssertEqual(error as? LUT3DError, .invalidEntryCount(expected: 8, actual: 1))
        }
    }

    func testQuickExportExplainsLUTAndColorChangeWithoutFalseBitDepthBlocker() {
        var configuration = ExportConfiguration()
        configuration.color.isLUTEnabled = true
        configuration.color.lutFile = LUTFileReference(url: URL(fileURLWithPath: "/tmp/camera.cube"))
        configuration.color.inputProfile = .dLogM
        configuration.color.outputColorSpace = .rec709SDR
        configuration.video.pixelFormat = .yuv420p10le
        let source = MediaStream(
            index: 0,
            kind: .video,
            codecName: "hevc",
            width: 3_840,
            height: 2_160,
            sampleRate: nil,
            channels: nil,
            language: nil,
            pixelFormat: "yuv420p10le"
        )

        let blockers = QuickExportEligibility.blockers(
            configuration: configuration,
            editing: EditSettings(),
            sourceVideo: source
        )

        XCTAssertTrue(blockers.contains("已应用 LUT"))
        XCTAssertTrue(blockers.contains("输出色彩空间与源视频不同"))
        XCTAssertFalse(blockers.contains("输出位深与源视频不同"))
        XCTAssertFalse(blockers.contains("色度采样与源视频不同"))
    }
}
