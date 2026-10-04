import AppKit
import XCTest
@testable import VideoBox

final class PlayerInputTests: XCTestCase {
    func testPlaybackAndFrameCommands() {
        XCTAssertEqual(command(49, " "), .togglePlayback)
        XCTAssertEqual(command(43, ","), .stepFrame(-1))
        XCTAssertEqual(command(47, "."), .stepFrame(1))
        XCTAssertEqual(command(3, "f"), .toggleFullscreen)
        XCTAssertEqual(command(53, "\u{1b}"), .exitFullscreen)
        XCTAssertEqual(command(46, "m"), .toggleMute)
    }

    func testNavigationUsesOutputSecondsAndMonitoringVolume() {
        XCTAssertEqual(command(123), .skip(-5))
        XCTAssertEqual(command(124), .skip(5))
        XCTAssertEqual(command(123, modifiers: .shift), .skip(-1))
        XCTAssertEqual(command(124, modifiers: .shift), .skip(1))
        XCTAssertEqual(command(125), .adjustVolume(-0.05))
        XCTAssertEqual(command(126), .adjustVolume(0.05))
    }

    func testSystemAndTextEditingModifiersAreNotConsumed() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            XCTAssertNil(command(49, " ", modifiers: modifiers))
            XCTAssertNil(command(123, modifiers: modifiers))
        }
        XCTAssertNil(command(3, "F", modifiers: .shift))
        XCTAssertNil(command(0, "a"))
        XCTAssertEqual(command(3, "F", modifiers: .capsLock), .toggleFullscreen)
    }

    func testHeldToggleDoesNotRepeatedlyToggleButNavigationRepeats() {
        XCTAssertNil(command(49, " ", repeated: true))
        XCTAssertNil(command(3, "f", repeated: true))
        XCTAssertNil(command(46, "m", repeated: true))
        XCTAssertEqual(command(124, repeated: true), .skip(5))
        XCTAssertEqual(command(47, ".", repeated: true), .stepFrame(1))
    }

    private func command(
        _ keyCode: UInt16,
        _ characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        repeated: Bool = false
    ) -> PlayerInputCommand? {
        PlayerInputCommand.resolve(
            keyCode: keyCode,
            characters: characters,
            modifiers: modifiers,
            isRepeat: repeated
        )
    }
}
