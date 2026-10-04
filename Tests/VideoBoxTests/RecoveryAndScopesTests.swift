import CoreGraphics
import Foundation
import XCTest
@testable import VideoBox

final class RecoveryAndScopesTests: XCTestCase {
    func testRealProcessPauseResumeAndCancelWhileStopped() async throws {
        let control = ProcessControl(), counter = ScopeCounter()
        let runner = ProcessRunner(control: control)
        let task = Task { try await runner.run(CLICommand(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while true; do printf 'tick\\n'; sleep 0.03; done"])) { value in counter.add(value.count) } }
        defer { task.cancel(); control.setPaused(false) }
        for _ in 0..<100 { if counter.value > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(counter.value, 0)
        control.setPaused(true); try await Task.sleep(for: .milliseconds(150))
        let stopped = counter.value; try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(counter.value, stopped, "A paused process must stop producing output")
        control.setPaused(false); try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(counter.value, stopped)
        control.setPaused(true); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled paused process must throw") } catch is CancellationError { }
        let ended = counter.value; try await Task.sleep(for: .milliseconds(150)); XCTAssertEqual(counter.value, ended)
    }
    func testScopesUseRealPixelsAndFiniteBins() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [1, 0, 0, 1])!); context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        let scopes = try XCTUnwrap(VideoScopeData.measure(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(scopes.histograms[0][255], scopes.sampleCount)
        XCTAssertEqual(scopes.histograms[1][0], scopes.sampleCount)
        XCTAssertEqual(scopes.histograms[3][54], scopes.sampleCount)
        XCTAssertEqual(scopes.waveform.count, 256)
    }
}
private final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add(_ value: Int) { lock.lock(); count += value; lock.unlock() }
}
