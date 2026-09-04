import AVFoundation
import Combine
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var sourceURL: URL?
    @Published private(set) var currentTime = 0.0
    private var timeObserver: Any?
    private var previewRate = 1.0

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func load(url: URL) {
        pause()
        sourceURL = url
        currentTime = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: Float(previewRate))
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        currentTime = max(0, seconds)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func applyPreviewSettings(rate: Double, volume: Double) {
        previewRate = min(2, max(0.5, rate))
        player.defaultRate = Float(previewRate)
        player.volume = Float(min(2, max(0, volume)))
        if isPlaying {
            player.rate = Float(previewRate)
        }
    }
}
