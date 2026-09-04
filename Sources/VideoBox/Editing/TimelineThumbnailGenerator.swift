import AVFoundation
import CoreGraphics
import Foundation

enum TimelineThumbnailGenerator {
    static func generate(
        sourceURL: URL,
        duration: TimeInterval,
        count: Int = 12
    ) async -> [CGImage] {
        await Task.detached(priority: .utility) {
            guard duration.isFinite, duration > 0, count > 0 else { return [] }

            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

            return (0..<count).compactMap { index in
                let fraction = count == 1 ? 0.5 : Double(index) / Double(count - 1)
                let seconds = min(max(0, duration - 0.01), duration * fraction)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                return try? generator.copyCGImage(at: time, actualTime: nil)
            }
        }.value
    }
}
