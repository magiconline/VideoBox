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
    var lutInputLabel = "原片"
    var lutOutputLabel = "LUT"

    @State private var comparisonPosition = 0.5
    @State private var comparisonDragStart: Double?
    @State private var isShowingShortcutHelp = false

    var body: some View {
        ZStack(alignment: .bottom) {
            videoAndInput

            if playerController.isPreparingTimeline {
                ProgressView("正在生成剪辑 / 特效预览…")
                    .padding(12).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if let message = playerController.navigationMessage {
                VStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            if playerController.isUsingRenderedComposition {
                VStack { HStack { comparisonBadge("合成预览 · 低分辨率 · 色彩 / LUT 已渲染"); Spacer() }; Spacer() }
                    .padding(12).allowsHitTesting(false)
            }

            if playerController.isLUTPreviewActive {
                VStack {
                    HStack {
                        comparisonBadge(lutInputLabel)
                        Spacer()
                        comparisonBadge(lutOutputLabel)
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }

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
                    .padding(.bottom, 68)
                    .accessibilityLabel("预览字幕：\(playerController.subtitleText)")
                    .allowsHitTesting(false)
            }

            PlayerTransportBar(
                playerController: playerController,
                isShowingShortcutHelp: $isShowingShortcutHelp
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.black)
        .clipped()
    }

    private var videoAndInput: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let dividerX = width * comparisonPosition

            ZStack(alignment: .leading) {
                transformedLayer(playerController.player, size: proxy.size)

                PlayerInputView(playerController: playerController, isEnabled: !isShowingShortcutHelp)

                if playerController.isLUTPreviewActive && playerController.viewingZoom == 1 {
                    comparisonDivider(width: width, height: height)
                        .position(x: dividerX, y: height / 2)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .onAppear { playerController.updateComparison(fraction: comparisonPosition, viewport: proxy.size) }
            .onChange(of: comparisonPosition) { position in playerController.updateComparison(fraction: position, viewport: proxy.size) }
            .onChange(of: proxy.size) { size in playerController.updateComparison(fraction: comparisonPosition, viewport: size) }
            .onChange(of: playerController.viewingZoom) { zoom in playerController.updateComparison(fraction: zoom == 1 ? comparisonPosition : 0, viewport: proxy.size) }
        }
        .accessibilityIdentifier("video-edit-preview")
    }

    private func transformedLayer(_ player: AVPlayer, size: CGSize) -> some View {
        let clip = playerController.isUsingRenderedComposition ? nil : playerController.activeClip ?? segment
        let turns = ((clip?.transform.quarterTurnsClockwise ?? 0) % 4 + 4) % 4
        let isQuarterTurn = turns == 1 || turns == 3
        let width = isQuarterTurn ? size.height : size.width
        let height = isQuarterTurn ? size.width : size.height
        let scale = clip?.scale ?? 1
        let xScale = (clip?.transform.isFlippedHorizontally == true ? -1.0 : 1.0) * scale
        let yScale = (clip?.transform.isFlippedVertically == true ? -1.0 : 1.0) * scale

        return PlayerVideoSurfaceView(player: player)
            .frame(width: width, height: height)
            .rotationEffect(.degrees(Double(turns * 90)))
            .scaleEffect(x: xScale, y: yScale)
            .scaleEffect(playerController.viewingZoom)
            .offset(playerController.viewingPan)
            .position(x: size.width / 2, y: size.height / 2)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }

    private func comparisonDivider(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: height)
            Image(systemName: "arrow.left.and.right.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black.opacity(0.72), Color.white)
        }
        .frame(width: 32, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if comparisonDragStart == nil {
                        comparisonDragStart = comparisonPosition
                        PlayerInputFocus.focusPlayer(for: playerController, preservingTextFocus: false)
                    }
                    comparisonPosition = min(0.95, max(0.05,
                        (comparisonDragStart ?? comparisonPosition) + value.translation.width / max(1, width)
                    ))
                }
                .onEnded { _ in comparisonDragStart = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("LUT 前后比较分隔线")
        .accessibilityValue("原片占 \(Int(comparisonPosition * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: comparisonPosition = min(0.95, comparisonPosition + 0.05)
            case .decrement: comparisonPosition = max(0.05, comparisonPosition - 0.05)
            @unknown default: break
            }
        }
        .help("拖动分隔线比较原片与 LUT；单击其他画面播放或暂停")
    }

    private func comparisonBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
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
    @Binding var isShowingShortcutHelp: Bool

    @State private var requestedTime: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playerController.togglePlayback()
            } label: {
                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerController.isPlaying ? "暂停" : "播放")
            .help(playerController.isPlaying ? "暂停（空格）" : "播放（空格）")

            Text(formatTime(displayedTime))
                .font(.system(.caption, design: .monospaced))
                .frame(width: timeLabelWidth, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { newValue in
                        requestedTime = newValue
                        playerController.seekOutput(to: newValue)
                    }
                ),
                in: 0...sliderUpperBound,
                onEditingChanged: seekingChanged
            )
            .disabled(playableDuration <= 0)
            .accessibilityLabel("输出时间线播放位置")
            .help("按剪辑后的时间线定位；方向键前后 5 秒，Shift 方向键前后 1 秒")

            Text(formatTime(playableDuration))
                .font(.system(.caption, design: .monospaced))
                .frame(width: timeLabelWidth, alignment: .leading)

            Divider().frame(height: 16).overlay(Color.white.opacity(0.3))
            Button { playerController.jumpToClip(-1) } label: { Image(systemName: "backward.end") }
                .buttonStyle(.plain).help("上一片段（[ / Page Up）")
            Button { playerController.jumpToClip(1) } label: { Image(systemName: "forward.end") }
                .buttonStyle(.plain).help("下一片段（] / Page Down）")
            Button { playerController.isLoopEnabled.toggle() } label: { Image(systemName: "repeat").foregroundStyle(playerController.isLoopEnabled ? Color.accentColor : .white) }
                .buttonStyle(.plain).help("循环（L）；右键设置区间，Shift I / Shift O 设置循环入出点")

            Button {
                playerController.toggleMonitoringMute()
            } label: {
                Image(systemName: playerController.isMonitoringMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerController.isMonitoringMuted ? "取消监听静音" : "监听静音")
            .help("监听静音（M），不改变导出音量")

            Slider(value: $playerController.monitoringVolume, in: 0...1)
                .frame(width: 48)
                .accessibilityLabel("监听音量")
                .help("仅调整播放监听音量，不改变导出；上下方向键调整 5%")

            Button {
                playerController.toggleFullscreen()
            } label: {
                Image(systemName: playerController.isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerController.isFullscreen ? "退出全屏" : "全屏预览")
            .help(playerController.isFullscreen ? "退出全屏（Esc / F）" : "全屏预览（F / 双击画面）")

            Button {
                isShowingShortcutHelp.toggle()
            } label: {
                Image(systemName: "keyboard").frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放器快捷键")
            .help("查看播放器鼠标和键盘操作")
            .popover(isPresented: $isShowingShortcutHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("播放器操作").font(.headline)
                    shortcut("播放 / 暂停", "空格 · 单击画面")
                    shortcut("前后 5 秒 / 1 秒", "← → / Shift + ← →")
                    shortcut("上一帧 / 下一帧", ", / .")
                    shortcut("全屏 / 退出", "F · 双击 / Esc")
                    shortcut("监听静音 / 音量", "M / ↑ ↓")
                    shortcut("上一 / 下一片段", "[ / ] · Page Up / Down")
                    shortcut("到开头 / 结尾", "Home / End")
                    shortcut("片段入点 / 出点", "I / O")
                    shortcut("循环入点 / 出点 / 开关", "Shift I / Shift O / L")
                    shortcut("观看缩放 / 复位", "+ / − / 0")
                    shortcut("观看平移 / 缩放", "Option 拖动 / 滚轮")
                    Divider()
                    Text("先点击画面或时间线聚焦。编辑文字时不触发播放器快捷键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("监听音量仅影响预览；片段音量和速度会应用到导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 410)
                .padding(16)
                .foregroundStyle(.primary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .background(PlayerInputFocusRegion(playerController: playerController))
        .accessibilityIdentifier("video-playback-controls")
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var playableDuration: TimeInterval {
        let duration = playerController.outputDuration
        return duration.isFinite && duration > 0 ? duration : 0
    }

    private var sliderUpperBound: TimeInterval {
        max(0.01, playableDuration)
    }

    private var displayedTime: TimeInterval {
        min(sliderUpperBound, max(0, requestedTime ?? playerController.outputTime))
    }

    private var timeLabelWidth: CGFloat { playableDuration >= 3_600 ? 90 : 69 }

    private func seekingChanged(_ isSeeking: Bool) {
        if isSeeking {
            playerController.beginScrubbing()
        } else {
            if let requestedTime {
                playerController.seekOutput(to: requestedTime)
            }
            requestedTime = nil
            playerController.endScrubbing()
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let milliseconds = Int((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let remainder = (milliseconds / 1_000) % 60
        let fraction = milliseconds % 1_000
        return hours > 0
            ? String(format: "%02d:%02d:%02d.%03d", hours, minutes, remainder, fraction)
            : String(format: "%02d:%02d.%03d", minutes, remainder, fraction)
    }
}
