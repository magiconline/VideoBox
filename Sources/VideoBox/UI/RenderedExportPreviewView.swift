import AVKit
import SwiftUI

struct RenderedExportPreviewView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let input: RenderedPreviewRequest
    @State private var player = AVPlayer()
    @State private var directory: URL?
    @State private var outputURL: URL?
    @State private var progress = 0.0
    @State private var error: String?
    @State private var details = ""
    @State private var isRendering = true
    @State private var playable = false
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var audioGroup: AVMediaSelectionGroup?
    @State private var selectedAudio = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导出效果预览").font(.title2.bold())
                Spacer()
                Button(isRendering ? "取消" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("使用当前导出设置，预渲染成片时间 \(input.outputStart.formatted(.number.precision(.fractionLength(2)))) 秒起的最多 5 秒。不会加入队列或更改原片。")
                .font(.caption).foregroundStyle(.secondary)
            ZStack {
                Color.black
                if playable { VideoPlayer(player: player) }
                if isRendering {
                    VStack(spacing: 12) {
                        ProgressView(value: progress).frame(width: 300)
                        Text("正在生成实际导出样片… \(Int(progress * 100))%").foregroundStyle(.white)
                    }
                }
                if let error { Text(error).foregroundStyle(.white).padding(24) }
            }.frame(minHeight: 330).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if audioOptions.count > 1 {
                Picker("监听音轨", selection: $selectedAudio) {
                    ForEach(audioOptions.indices, id: \.self) { index in Text(audioOptions[index].displayName).tag(index) }
                }.onChange(of: selectedAudio) { index in
                    if let audioGroup, audioOptions.indices.contains(index) { player.currentItem?.select(audioOptions[index], in: audioGroup) }
                }
            }
            HStack {
                if playable {
                    Button {
                        if player.rate != 0 { player.pause() }
                        else {
                            if let item = player.currentItem, player.currentTime() >= item.duration {
                                player.seek(to: .zero)
                            }
                            player.play()
                        }
                    } label: { Label("播放 / 暂停", systemImage: "playpause.fill") }
                        .keyboardShortcut(.space, modifiers: [])
                }
                if let outputURL {
                    Button("在 Finder 中查看实际样片") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
                        .help("样片关闭后会删除；如需保留，请先在 Finder 中复制到自己的文件夹。")
                }
            }
        }
        .padding(20).frame(width: 800, height: 560)
        .task { await render() }
        .onDisappear {
            player.pause(); player.replaceCurrentItem(with: nil)
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    @MainActor private func render() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-render-check-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        defer { isRendering = false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var request = input.request
            request.destinationURL = directory.appendingPathComponent("实际导出样片").appendingPathExtension(request.configuration.container.fileExtension)
            let url = try await environment.renderExportPreview(request) { value in
                Task { @MainActor in progress = value }
            }
            try Task.checkCancellation()
            outputURL = url
            let probe = try await environment.probeMedia(at: url)
            let video = probe.primaryVideoStream
            details = "实际样片：\(video?.codecName?.uppercased() ?? "未知编码") · \(video?.bitDepth ?? 0)-bit · \(video?.colorPrimaries ?? "原色未标记") · \(video?.hdrDescription ?? "") · \(probe.streams.filter { $0.kind == .audio }.count) 条音轨"
            if await MediaPlaybackCompatibility.isPlayableVideo(at: url) {
                let asset = AVURLAsset(url: url)
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
                audioOptions = audioGroup?.options ?? []
                playable = true
            } else {
                error = "当前导出格式不受 macOS 原生播放器支持。实际样片已生成，可用外部播放器核对；不会用低位深代理冒充最终画面。"
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
