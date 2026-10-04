import SwiftUI

struct ClipAdvancedEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var editing: EditSettings
    let localTime: Double
    let changed: () -> Void
    @State private var draft: EditSegment?
    @State private var crop = NormalizedCrop(x: 0, y: 0, width: 1, height: 1)
    @State private var cropEnabled = false
    @State private var effects = ClipEffects()
    @State private var transition = ClipTransition()
    @State private var transitionEnabled = false
    @State private var pose = VisualPose()
    @State private var keyTime = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("片段设置").font(.title2.bold())
            if let draft {
                Text(draft.sourceURL?.lastPathComponent ?? "主素材").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        GroupBox("自由裁剪 · 相对于原片，百分比") {
                            VStack {
                                Toggle("启用裁剪", isOn: $cropEnabled)
                                scalar("左边", value: $crop.x, range: 0...0.95, factor: 100)
                                scalar("上边", value: $crop.y, range: 0...0.95, factor: 100)
                                scalar("宽度", value: $crop.width, range: 0.05...1, factor: 100)
                                scalar("高度", value: $crop.height, range: 0.05...1, factor: 100)
                                Text("裁剪后按输出画布等比适配；超出原片的范围不能应用。") .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        GroupBox("基础调色 · 显示参考") {
                            VStack {
                                scalar("曝光增益", value: $effects.exposure, range: -3...3)
                                scalar("冷暖", value: $effects.temperature, range: -1...1)
                                scalar("绿 / 洋红", value: $effects.tint, range: -1...1)
                                Text("基础 RGB 增益与白平衡偏移，不是相机 RAW 白平衡；HDR 和 Log 应先配置正确的色彩转换。") .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        GroupBox("入场转场 · 与上一片段重叠") {
                            VStack {
                                Toggle("启用转场", isOn: $transitionEnabled).disabled(editing.selectedClipIndex == 0)
                                Picker("样式", selection: $transition.style) {
                                    Text("交叉淡化").tag("fade"); Text("向左擦除").tag("wipeleft"); Text("向右擦除").tag("wiperight")
                                }
                                scalar("秒", value: $transition.duration, range: 0.1...3)
                                Text("实际时长不超过相邻较短片段的一半；重叠会缩短总时长。") .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        GroupBox("关键帧 · 画面位置 / 缩放 / 不透明度") {
                            VStack(alignment: .leading) {
                                HStack { Text("片段内时间"); TextField("秒或时间码", text: $keyTime).frame(width: 125)
                                    Button("当前播放头") { keyTime = Timecode.format(min(draft.outputDuration, max(0, localTime))) }
                                }
                                scalar("水平中心", value: $pose.x, range: 0...1, factor: 100)
                                scalar("垂直中心", value: $pose.y, range: 0...1, factor: 100)
                                scalar("放大", value: $pose.scale, range: 1...4)
                                scalar("不透明度", value: $pose.opacity, range: 0...1, factor: 100)
                                Button("添加 / 更新关键帧") { addKeyframe() }
                                ForEach((draft.keyframes ?? []).sorted { $0.time < $1.time }) { frame in
                                    HStack {
                                        Button(Timecode.format(frame.time)) { keyTime = Timecode.format(frame.time); pose = frame.pose }
                                        Text("位置 \(Int(frame.pose.x * 100)),\(Int(frame.pose.y * 100))% · \(frame.pose.scale.formatted())× · \(Int(frame.pose.opacity * 100))%") .font(.caption)
                                        Spacer(); Button("删除") { self.draft?.keyframes?.removeAll { $0.id == frame.id } }
                                    }
                                }
                                Text("关键帧之间线性插值；首帧前、末帧后保持对应参数。没有关键帧时不改变原画面。") .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("应用") { apply() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 570, height: 740)
        .onAppear {
            draft = editing.selectedClip; crop = draft?.transform.crop ?? crop; cropEnabled = draft?.transform.crop != nil
            effects = draft?.effects ?? effects; transition = draft?.transition ?? transition; transitionEnabled = draft?.transition != nil
            keyTime = Timecode.format(localTime); pose = VisualKeyframe.interpolate(draft?.keyframes ?? [], at: localTime)
        }
    }
    private func scalar(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, factor: Double = 1) -> some View {
        HStack { Text(label).frame(width: 92, alignment: .leading); Slider(value: value, in: range); Text((value.wrappedValue * factor).formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 65) }
    }
    private func addKeyframe() {
        guard let time = Timecode.parse(keyTime), let duration = draft?.outputDuration, time <= duration else { error = "关键帧时间应位于当前片段内"; return }
        var frames = draft?.keyframes ?? []; frames.removeAll { abs($0.time - time) < 0.001 }
        frames.append(VisualKeyframe(time: time, pose: pose)); self.draft?.keyframes = frames; error = nil
    }
    private func apply() {
        guard var draft, let index = editing.clips.firstIndex(where: { $0.id == draft.id }) else { return }
        guard !cropEnabled || (crop.x + crop.width <= 1.00001 && crop.y + crop.height <= 1.00001) else { error = "裁剪范围超出原片，请减少宽度或高度"; return }
        draft.transform.crop = cropEnabled ? crop : nil; draft.effects = effects.isIdentity ? nil : effects
        draft.transition = transitionEnabled && index > 0 ? transition : nil
        editing.clips[index] = draft; changed(); dismiss()
    }
}
