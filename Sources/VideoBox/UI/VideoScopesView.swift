import AVFoundation
import SwiftUI

struct VideoScopesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: PlayerController
    @State private var scope: VideoScopeData?
    @State private var error: String?
    @State private var refreshID = UUID()
    @State private var frameTime = 0.0
    private var captureID: String { "\(Int(controller.outputTime))|\(controller.isPreparingTimeline)|\(refreshID)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画面分析 · 显示参考").font(.title2.bold())
            Text("采样当前解码预览帧，包含 LUT 比较状态；不含界面旋转和观看缩放。图表使用 sRGB 8-bit 参考值，不是原始 10/12-bit 信号或 HDR nit 测量。")
                .font(.caption).foregroundStyle(.secondary)
            if let scope {
                Text("RGB / 亮度直方图")
                Canvas { context, size in
                    let colors: [Color] = [.red, .green, .blue, .white]
                    for (channel, values) in scope.histograms.enumerated() {
                        let maximum = Double(max(1, values.max() ?? 1))
                        var path = Path()
                        for (i, value) in values.enumerated() {
                            let point = CGPoint(x: Double(i) / 255 * size.width, y: size.height * (1 - log1p(Double(value)) / log1p(maximum)))
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        context.stroke(path, with: .color(colors[channel].opacity(0.8)), lineWidth: 1)
                    }
                }.background(.black).frame(height: 160)
                HStack { Text("0"); Spacer(); Text("255") }.font(.caption.monospacedDigit())
                Text("亮度波形 · 横轴为画面横向位置")
                Canvas { context, size in
                    let maximum = Double(max(1, scope.waveform.flatMap { $0 }.max() ?? 1))
                    for (x, column) in scope.waveform.enumerated() {
                        for (level, count) in column.enumerated() where count > 0 {
                            let rect = CGRect(x: Double(x) / 256 * size.width, y: (1 - Double(level) / 255) * (size.height - 1), width: max(1, size.width / 256), height: 1.5)
                            context.fill(Path(rect), with: .color(.green.opacity(max(0.2, sqrt(Double(count) / maximum)))))
                        }
                    }
                }.background(.black).frame(height: 210)
                Text("采样剪后时间 \(Timecode.format(frameTime)) · \(scope.sampleCount) 个像素 · 播放时每秒更新").font(.caption).foregroundStyle(.secondary)
            } else { Spacer(); ProgressView("读取当前画面…"); Spacer() }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack { Button("刷新") { refreshID = UUID() }; Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 700, height: 610)
        .task(id: captureID) {
            guard !controller.isPreparingTimeline, let item = controller.player.currentItem else { return }
            let generator = AVAssetImageGenerator(asset: item.asset); generator.appliesPreferredTrackTransform = true
            generator.videoComposition = item.videoComposition; generator.maximumSize = CGSize(width: 512, height: 288)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            do {
                let time = min(controller.outputTime, max(0, controller.outputDuration - 0.05))
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600_000))
                let measured = await Task.detached { VideoScopeData.measure(image) }.value
                try Task.checkCancellation(); scope = measured; frameTime = time; error = nil
            } catch is CancellationError { generator.cancelAllCGImageGeneration() }
            catch let failure { error = "无法读取当前帧：\(failure.localizedDescription)" }
        }
    }
}
