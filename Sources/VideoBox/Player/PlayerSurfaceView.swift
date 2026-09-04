import AppKit
import AVFoundation
import SwiftUI

struct PlayerVideoSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerVideoView {
        let view = PlayerVideoView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerVideoView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ nsView: PlayerVideoView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

struct EditedPlayerSurface: View {
    @ObservedObject var playerController: PlayerController
    let segment: EditSegment?
    let duration: TimeInterval?

    var body: some View {
        ZStack(alignment: .bottom) {
            transformedVideo

            if let message = playerController.playbackErrorMessage {
                VStack(spacing: 7) {
                    Label("视频播放失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.bottom, 46)
                .allowsHitTesting(false)
                .accessibilityLabel("播放失败：\(message)")
            }

            if !playerController.subtitleText.isEmpty {
                Text(playerController.subtitleText)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 36)
                    .padding(.bottom, 58)
                    .accessibilityLabel("预览字幕：\(playerController.subtitleText)")
            }

            PlayerTransportBar(
                playerController: playerController,
                duration: duration
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.black)
        .clipped()
    }

    private var transformedVideo: some View {
        GeometryReader { proxy in
            let turns = normalizedTurns
            let isQuarterTurn = turns == 1 || turns == 3
            let width = isQuarterTurn ? proxy.size.height : proxy.size.width
            let height = isQuarterTurn ? proxy.size.width : proxy.size.height
            let scale = segment?.scale ?? 1
            let xScale = (segment?.transform.isFlippedHorizontally == true ? -1.0 : 1.0) * scale
            let yScale = (segment?.transform.isFlippedVertically == true ? -1.0 : 1.0) * scale

            PlayerVideoSurfaceView(player: playerController.player)
                .frame(width: width, height: height)
                .rotationEffect(.degrees(Double(turns * 90)))
                .scaleEffect(x: xScale, y: yScale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityIdentifier("video-edit-preview")
    }

    private var normalizedTurns: Int {
        let turns = segment?.transform.quarterTurnsClockwise ?? 0
        return ((turns % 4) + 4) % 4
    }
}

final class PlayerVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    private func configureLayers() {
        wantsLayer = true
        let backgroundLayer = CALayer()
        backgroundLayer.backgroundColor = NSColor.black.cgColor
        layer = backgroundLayer
        playerLayer.videoGravity = .resizeAspect
        backgroundLayer.addSublayer(playerLayer)
    }
}

private struct PlayerTransportBar: View {
    @ObservedObject var playerController: PlayerController
    let duration: TimeInterval?

    @State private var requestedTime: TimeInterval?
    @State private var resumeAfterSeeking = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playerController.togglePlayback()
            } label: {
                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playerController.isPlaying ? "暂停" : "播放")

            Text(formatTime(displayedTime))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { newValue in
                        requestedTime = newValue
                        playerController.seek(to: newValue)
                    }
                ),
                in: 0...sliderUpperBound,
                onEditingChanged: seekingChanged
            )
            .disabled(playableDuration <= 0)

            Text(formatTime(playableDuration))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 48, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .accessibilityIdentifier("video-playback-controls")
    }

    private var playableDuration: TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    private var sliderUpperBound: TimeInterval {
        max(0.01, playableDuration)
    }

    private var displayedTime: TimeInterval {
        min(sliderUpperBound, max(0, requestedTime ?? playerController.currentTime))
    }

    private func seekingChanged(_ isSeeking: Bool) {
        if isSeeking {
            resumeAfterSeeking = playerController.isPlaying
            playerController.pause()
        } else {
            if let requestedTime {
                playerController.seek(to: requestedTime)
            }
            requestedTime = nil
            if resumeAfterSeeking {
                playerController.play()
            }
            resumeAfterSeeking = false
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}
