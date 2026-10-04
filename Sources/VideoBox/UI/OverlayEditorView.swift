import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OverlayEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Binding var editing: EditSettings
    @State private var layers: [OverlayClip] = []
    @State private var selectedID: UUID?
    @State private var isLoading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("叠加轨道 · 画中画与背景音频").font(.title2.bold())
            Text("主时间线决定成片长度；叠加轨道按列表顺序由下向上覆盖，超出成片的部分截断。混音使用 48 kHz 立体声。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Button("添加视频 / 音频…", action: add).disabled(isLoading); if isLoading { ProgressView().controlSize(.small) }; Spacer() }
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(layers) { layer in
                        Label(layer.sourceURL.lastPathComponent, systemImage: layer.isAudioOnly ? "waveform" : "rectangle.on.rectangle").tag(layer.id)
                    }
                }.frame(width: 220)
                ScrollView {
                    selectedControls
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("应用") { apply() }.keyboardShortcut(.defaultAction).disabled(isLoading) }
        }.padding(20).frame(width: 800, height: 540)
        .onAppear { layers = editing.overlayClips; selectedID = layers.first?.id }
        .onDisappear { task?.cancel() }
    }
    private func apply() {
        var candidate = editing; candidate.overlayClips = layers
        if let issue = candidate.validationIssues.first { error = issue; return }
        editing = candidate; dismiss()
    }
    @ViewBuilder private var selectedControls: some View {
        if let index = layers.firstIndex(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 12) {
                            timeField("时间线起点", index: index, key: \.startTime)
                            timeField("素材入点", index: index, key: \.sourceRange.start)
                            timeField("素材长度", index: index, key: \.sourceRange.duration)
                            if !layers[index].isAudioOnly {
                                scalar("水平中心 %", index: index, key: \.pose.x, range: 0...1, factor: 100)
                                scalar("垂直中心 %", index: index, key: \.pose.y, range: 0...1, factor: 100)
                                scalar("画布宽度 %", index: index, key: \.pose.scale, range: 0.05...1, factor: 100)
                                scalar("不透明度 %", index: index, key: \.pose.opacity, range: 0...1, factor: 100)
                            }
                            scalar("音频增益 %", index: index, key: \.audioGain, range: 0...2, factor: 100)
                            HStack {
                                Button("降低层级") { if index > 0 { layers.swapAt(index, index - 1) } }.disabled(index == 0)
                                Button("提高层级") { if index < layers.count - 1 { layers.swapAt(index, index + 1) } }.disabled(index == layers.count - 1)
                                Button("移除") { layers.remove(at: index); selectedID = layers.first?.id }
                            }
                        }.padding(12)
        } else { Text("添加并选择素材后设置起点、位置和音量。").foregroundStyle(.secondary).padding() }
    }
    private func timeField(_ title: String, index: Int, key: WritableKeyPath<OverlayClip, Double>) -> some View {
        HStack { Text(title).frame(width: 120, alignment: .leading)
            TextField(title, value: Binding(get: { layers[index][keyPath: key] }, set: { layers[index][keyPath: key] = $0 }), format: .number.precision(.fractionLength(3)))
            Text("秒").foregroundStyle(.secondary)
        }
    }
    private func scalar(_ title: String, index: Int, key: WritableKeyPath<OverlayClip, Double>, range: ClosedRange<Double>, factor: Double) -> some View {
        HStack { Text(title).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { layers[index][keyPath: key] }, set: { layers[index][keyPath: key] = $0 }), in: range)
            Text((layers[index][keyPath: key] * factor).formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 45)
        }
    }
    private func add() {
        let panel = NSOpenPanel(); panel.title = "添加叠加素材"; panel.allowedContentTypes = [.movie, .video, .audio]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls; isLoading = true; error = nil
        task = Task { @MainActor in
            defer { isLoading = false }
            for url in urls {
                do {
                    let probe = try await environment.probeMedia(at: url); try Task.checkCancellation()
                    guard let duration = probe.duration, duration > 0, probe.primaryVideoStream != nil || probe.streams.contains(where: { $0.kind == .audio }) else { throw ProjectError.invalid("素材没有可用画面或音频") }
                    var layer = OverlayClip(sourceURL: url, media: ClipMedia(probe), sourceRange: TimelineRange(start: 0, duration: duration))
                    if layer.isAudioOnly { layer.audioGain = 1 }
                    layers.append(layer); selectedID = layer.id
                } catch is CancellationError { return } catch let failure { self.error = failure.localizedDescription }
            }
        }
    }
}
