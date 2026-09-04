import AVFoundation
import Combine
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var sourceURL: URL?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isUsingTrackPreview = false
    @Published private(set) var subtitleText = ""
    @Published private(set) var playbackErrorMessage: String?
    private var timeObserver: Any?
    private var itemStatusObserver: AnyCancellable?
    private var previewRate = 1.0
    private var temporaryPreviewURL: URL?
    private var temporarySubtitleURL: URL?
    private var subtitleCues: [SubtitleCue] = []

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
                    self.updateSubtitleText(at: self.currentTime)
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL)
        }
        if let temporarySubtitleURL {
            try? FileManager.default.removeItem(at: temporarySubtitleURL)
        }
    }

    func load(url: URL) {
        replaceSource(
            with: url,
            preservingTime: false,
            resumesPlayback: false,
            subtitleCues: [],
            temporarySubtitleURL: nil,
            isTemporaryPreview: false
        )
    }

    func clear() {
        pause()
        itemStatusObserver?.cancel()
        itemStatusObserver = nil
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        currentTime = 0
        isUsingTrackPreview = false
        subtitleText = ""
        playbackErrorMessage = nil
        subtitleCues = []
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL)
            self.temporaryPreviewURL = nil
        }
        if let temporarySubtitleURL {
            try? FileManager.default.removeItem(at: temporarySubtitleURL)
            self.temporarySubtitleURL = nil
        }
    }

    func loadTrackPreview(
        mediaURL: URL,
        subtitleURL: URL?,
        preservingTime: Bool,
        resumesPlayback: Bool
    ) throws {
        let cues = try subtitleURL.map(SubtitleCueParser.parse(contentsOf:)) ?? []
        replaceSource(
            with: mediaURL,
            preservingTime: preservingTime,
            resumesPlayback: resumesPlayback,
            subtitleCues: cues,
            temporarySubtitleURL: subtitleURL,
            isTemporaryPreview: true
        )
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            updatePlaybackStatus(for: item)
            return
        }
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
        updateSubtitleText(at: currentTime)
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

    private func replaceSource(
        with url: URL,
        preservingTime: Bool,
        resumesPlayback: Bool,
        subtitleCues: [SubtitleCue],
        temporarySubtitleURL: URL?,
        isTemporaryPreview: Bool
    ) {
        let previousTime = preservingTime ? currentTime : 0
        let oldTemporaryURL = temporaryPreviewURL
        let oldTemporarySubtitleURL = self.temporarySubtitleURL
        pause()
        sourceURL = url
        currentTime = previousTime
        subtitleText = ""
        self.subtitleCues = subtitleCues
        playbackErrorMessage = nil
        itemStatusObserver?.cancel()
        let item = AVPlayerItem(url: url)
        itemStatusObserver = item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let item else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.player.currentItem === item else { return }
                    self.updatePlaybackStatus(for: item)
                }
            }
        player.replaceCurrentItem(with: item)
        temporaryPreviewURL = isTemporaryPreview ? url : nil
        self.temporarySubtitleURL = isTemporaryPreview ? temporarySubtitleURL : nil
        isUsingTrackPreview = isTemporaryPreview

        if previousTime > 0 {
            seek(to: previousTime)
        } else {
            updateSubtitleText(at: 0)
        }
        if resumesPlayback {
            play()
        }

        if let oldTemporaryURL, oldTemporaryURL != url {
            try? FileManager.default.removeItem(at: oldTemporaryURL)
        }
        if let oldTemporarySubtitleURL, oldTemporarySubtitleURL != temporarySubtitleURL {
            try? FileManager.default.removeItem(at: oldTemporarySubtitleURL)
        }
    }

    private func updateSubtitleText(at time: TimeInterval) {
        let activeText = subtitleCues
            .filter { $0.startTime <= time && time < $0.endTime }
            .map(\.text)
            .joined(separator: "\n")
        if subtitleText != activeText {
            subtitleText = activeText
        }
    }

    private func updatePlaybackStatus(for item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            playbackErrorMessage = nil
        case .failed:
            isPlaying = false
            playbackErrorMessage = item.error?.localizedDescription
                ?? "macOS 无法解码当前视频轨道。"
        case .unknown:
            break
        @unknown default:
            break
        }
    }
}
