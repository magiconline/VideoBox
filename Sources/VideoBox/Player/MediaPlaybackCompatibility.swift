import AVFoundation
import Foundation

enum MediaPlaybackCompatibility {
    static func isPlayableVideo(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        do {
            guard try await asset.load(.isPlayable) else { return false }
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { return false }

            let duration = try await asset.load(.duration)
            let durationSeconds = duration.seconds
            let sampleSeconds = durationSeconds.isFinite && durationSeconds > 0
                ? min(1, durationSeconds / 2)
                : 0
            let sampleTime = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true

            return await withCheckedContinuation { continuation in
                generator.generateCGImagesAsynchronously(
                    forTimes: [NSValue(time: sampleTime)]
                ) { _, image, _, result, _ in
                    continuation.resume(returning: result == .succeeded && image != nil)
                }
            }
        } catch {
            return false
        }
    }
}
