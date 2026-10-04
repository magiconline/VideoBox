import AppKit
import Foundation
import SwiftUI

struct UnifiedExportInspectorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let asset: MediaAsset
    let mediaProbe: MediaProbe?
    let sourceDuration: TimeInterval?
    @Binding var configuration: ExportConfiguration
    @Binding var editing: EditSettings
    let outputDirectoryURL: URL?
    @Binding var outputFileName: String
    let isFFmpegAvailable: Bool
    let chooseOutputFolder: () -> Void
    let chooseLUT: () -> Void
    let removeLUT: () -> Void
    let lutLoadError: String?
    let enqueueExport: (ExportMode) -> Void
    var showRenderedPreview: () -> Void = {}

    @State private var isColorSectionExpanded = true
    @State private var isScanningKeyframes = false
    @State private var keyframeError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("导出设置")
                        .font(.title2.bold())
                        .padding(.bottom, 2)

                    colorSection
                    videoSection
                    audioSection
                    subtitleSection
                    packagingSection
                    advancedSection
                }
                .padding(14)
            }

            Divider()
            Text(outputSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
            exportActions
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: keyframeScanIdentity) {
            guard editing.simpleTrimRange() != nil else { return }
            isScanningKeyframes = true
            keyframeError = nil
            defer { isScanningKeyframes = false }
            do {
                let video = configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }
                let index = try await environment.scanKeyframes(url: video?.resolvedSourceURL(primarySourceURL: asset.url) ?? asset.url,
                    streamIndex: video?.streamIndex ?? 0, duration: editing.sourceDuration)
                try Task.checkCancellation()
                configuration.copyTrimIndex = index
            } catch is CancellationError { }
            catch { keyframeError = error.localizedDescription }
        }
        .onChange(of: configuration.video.codec) { codec in
            if !codec.supportedProfiles.contains(configuration.video.profile) {
                configuration.video.profile = .automatic
            }
        }
    }

    private var outputSummary: String {
        let plan = ExportPlan(configuration: configuration, editing: editing, sourceVideo: mediaProbe?.primaryVideoStream, primarySourceURL: asset.url, sourceDuration: sourceDuration)
        let request = ExportRequest(sourceURL: asset.url, destinationURL: asset.url, sourceVideo: mediaProbe?.primaryVideoStream, configuration: configuration, editing: editing)
        let dimensions = FFmpegCommandBuilder().compositionCanvasDimensions(for: request)
            ?? (width: mediaProbe?.primaryVideoStream?.width ?? 0, height: mediaProbe?.primaryVideoStream?.height ?? 0)
        let duration = editing.trimmedDuration ?? sourceDuration ?? 0
        let color = ColorConversionPlan(settings: configuration.color, source: mediaProbe?.primaryVideoStream).output
        let space = color.map { "\($0.primaries) / \($0.transfer) / \($0.range)" } ?? "色彩标签未知"
        let rate = editing.requiresRenderedPreview ? "\(editing.compositionFrameRate(configuration: configuration, source: mediaProbe?.primaryVideoStream).formatted()) fps 固定帧率" : configuration.video.frameRate.displayName
        let codec = "压缩：\(configuration.video.codec.displayName) · \(plan.pixelFormat.displayName)"
        let audio = configuration.audio.codec == .none ? "无音频" : "音频：\(configuration.audio.codec.displayName)\(editing.requiresRenderedPreview ? " · 合成 48 kHz 立体声" : "")"
        return "预计成片 · \(Timecode.format(duration)) · \(dimensions.width)×\(dimensions.height)\n\(configuration.container.displayName) · \(codec) · \(rate)\n\(space)\n\(audio) · 字幕：\(configuration.subtitles.mode.displayName)"
    }

    private var colorSection: some View {
        DisclosureGroup(isExpanded: $isColorSectionExpanded) {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("应用 LUT", isOn: $configuration.color.isLUTEnabled)
                    .disabled(configuration.color.lutFile == nil)

                if let lutFile = configuration.color.lutFile {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.transparent")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Text(lutFile.url.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("更换", action: chooseLUT)
                            .controlSize(.small)

                        Button(action: removeLUT) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("移除 LUT")
                    }
                    .padding(10)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                } else {
                    Button(action: chooseLUT) {
                        Label("加载 .cube LUT…", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }

                if let lutLoadError {
                    Label(lutLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("输入 Log 声明", selection: $configuration.color.inputProfile) {
                    ForEach(CameraColorProfile.allCases, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .help("自动仅使用明确的拍摄曲线元数据；型号、灰片外观和 LUT 文件名不视为素材的识别结果。")

                Text(CameraLogEvidence.read(mediaProbe?.primaryVideoStream).description)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Picker("输入色彩解释", selection: $configuration.color.inputColorSpace) {
                    ForEach(OutputColorSpace.allCases, id: \.self) { space in
                        Text(space == .source ? "读取源标签" : space.displayName).tag(space)
                    }
                }
                .help("仅在源标签缺失或错误时覆盖输入解释；不等于给 Log 片还原。")

                if configuration.color.activeLUTFile != nil {
                    if let expected = configuration.color.lutFile.flatMap({ CameraColorProfile.inferred(fromLUTName: $0.displayName) }) {
                        Text("LUT 文件名提示输入：\(expected.displayName)（需核对说明）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("已核对拍摄模式与 LUT 匹配", isOn: $configuration.color.confirmsLUTCompatibility)
                    Picker("LUT 自身输出", selection: $configuration.color.lutOutputColorSpace) {
                        ForEach(OutputColorSpace.allCases.filter { $0 != .source }, id: \.self) { space in
                            Text(space.displayName).tag(space)
                        }
                    }
                }

                Picker("转换到", selection: $configuration.color.outputColorSpace) {
                    ForEach(OutputColorSpace.allCases, id: \.self) { colorSpace in
                        Text(colorSpace.displayName).tag(colorSpace)
                    }
                }
                .help("执行色域、传递函数和范围转换。HDR 转 SDR 使用高光压缩；SDR 转 HDR 不会恢复原片中不存在的高光细节。")

                Picker("位深", selection: outputBitDepthBinding) {
                    Text("跟随源：\(mediaProbe?.primaryVideoStream?.bitDepth.map { "\($0)-bit" } ?? "未知")").tag(0)
                    ForEach(OutputBitDepth.allCases, id: \.self) { depth in
                        Text(depth.displayName).tag(depth.rawValue)
                    }
                }

                Picker("色度采样", selection: chromaBinding) {
                    ForEach(ChromaSubsampling.allCases, id: \.self) { chroma in
                        Text(chroma.displayName).tag(chroma)
                    }
                }
                .disabled(configuration.video.pixelFormat == .automatic && OutputBitDepth(rawValue: mediaProbe?.primaryVideoStream?.bitDepth ?? 8) == nil)

                HStack {
                    Text(configuration.video.pixelFormat == .automatic ? "跟随源视频" : "指定输出")
                    Spacer()
                    Button("跟随源", action: { configuration.video.pixelFormat = .automatic })
                        .buttonStyle(.link)
                        .disabled(configuration.video.pixelFormat == .automatic)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("输出范围", selection: $configuration.color.outputRange) {
                    ForEach(OutputColorRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }

                if mediaProbe?.primaryVideoStream?.isHDR == true {
                    doubleField("HDR 峰值", value: $configuration.color.hdrPeakNits, suffix: "nit")
                    Text("高光压缩的输入峰值，默认 1000 nit；请按素材确认，不代表实测亮度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mediaProbe?.primaryVideoStream?.hasDynamicHDR == true {
                    Toggle("允许移除动态 HDR 元数据", isOn: $configuration.color.discardsDynamicHDR)
                    Text("压缩导出不会重新生成 Dolby Vision/HDR10+ 动态元数据。保留它们请用完整源片快速导出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(action: showRenderedPreview) {
                    Label("核对导出效果（当前位置 5 秒）", systemImage: "play.rectangle")
                }
                .disabled(!compressedExportBlockers.isEmpty || !baseExportAvailable)
                .help(compressedExportBlockers.joined(separator: "\n"))
                Text("主播放器为实时参考；此预览使用实际导出流程核对色彩、字幕和音轨。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if requiresSoftwareEncoderHint {
                    Label(
                        "当前位深或色度采样不受所选 Apple 硬件编码器支持，压缩导出已禁用；可改用软件编码。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("LUT 与输出色彩")
                .font(.headline)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var videoSection: some View {
        UnifiedInspectorSection(title: "视频编码") {
            Picker("编码器", selection: $configuration.video.codec) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            Picker("码率控制", selection: $configuration.video.rateControl) {
                ForEach(VideoRateControl.allCases, id: \.self) { control in
                    Text(control.displayName).tag(control)
                }
            }

            switch configuration.video.rateControl {
            case .constantQuality:
                HStack {
                    Text("质量")
                    Slider(
                        value: Binding(
                            get: { Double(configuration.video.quality) },
                            set: { configuration.video.quality = Int($0.rounded()) }
                        ),
                        in: 1...100,
                        step: 1
                    )
                    Text("\(configuration.video.quality)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 28)
                }
            case .averageBitrate:
                integerField("平均码率", value: $configuration.video.averageBitrateKbps, suffix: "kbps")
                integerField("最大码率", value: $configuration.video.maximumBitrateKbps, suffix: "kbps")
                integerField("缓冲区", value: $configuration.video.bufferSizeKbps, suffix: "kbps")
            case .targetSize:
                integerField("目标大小", value: $configuration.video.targetSizeMB, suffix: "MiB")
                integerField("备用码率", value: $configuration.video.averageBitrateKbps, suffix: "kbps")
                Text("按全部启用音轨估算，并预留封装空间；单次编码的实际体积仍可能浮动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("编码档次", selection: $configuration.video.profile) {
                ForEach(configuration.video.codec.supportedProfiles, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }

            if configuration.video.codec.supportsSoftwarePreset {
                Picker("速度 / 压缩率", selection: $configuration.video.preset) {
                    ForEach(EncoderPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            }

            Picker("分辨率", selection: $configuration.video.resolution) {
                ForEach(ResolutionPreset.allCases, id: \.self) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            if configuration.video.resolution == .custom {
                HStack {
                    integerField("宽", value: $configuration.video.customWidth, suffix: "px")
                    integerField("高", value: $configuration.video.customHeight, suffix: "px")
                }
            }

            Picker("帧率", selection: $configuration.video.frameRate) {
                ForEach(FrameRatePreset.allCases, id: \.self) { frameRate in
                    Text(frameRate.displayName).tag(frameRate)
                }
            }
            if configuration.video.frameRate == .custom {
                doubleField("自定义帧率", value: $configuration.video.customFrameRate, suffix: "fps")
            }

            Toggle("允许放大低分辨率视频", isOn: $configuration.video.allowUpscaling)
        }
    }

    private var audioSection: some View {
        UnifiedInspectorSection(title: "音频") {
            Picker("音频编码", selection: $configuration.audio.codec) {
                ForEach(AudioCodec.allCases, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            if configuration.audio.codec != .none, configuration.audio.codec != .copy {
                Text("音频码率仅用于压缩导出；快速导出保留原始音频码率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if configuration.audio.codec.usesBitrate {
                    integerField("音频码率", value: $configuration.audio.bitrateKbps, suffix: "kbps")
                }
                Picker("采样率", selection: $configuration.audio.sampleRate) {
                    ForEach(AudioSampleRate.allCases, id: \.self) { sampleRate in
                        Text(sampleRate.displayName).tag(sampleRate)
                    }
                }
                Picker("声道", selection: $configuration.audio.channels) {
                    ForEach(AudioChannelLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                Toggle("响度标准化", isOn: $configuration.audio.normalizeLoudness)
                if configuration.audio.normalizeLoudness {
                    doubleField("目标响度", value: $configuration.audio.targetLoudnessLUFS, suffix: "LUFS")
                }
            }
        }
    }

    private var subtitleSection: some View {
        UnifiedInspectorSection(title: "字幕") {
            Picker("处理方式", selection: $configuration.subtitles.mode) {
                ForEach(SubtitleMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if configuration.subtitles.mode == .burn {
                Picker("烧录轨道", selection: $configuration.subtitles.burnStreamIndex) {
                    ForEach(Array(configuration.trackSettings.filter { $0.kind == .subtitle }.enumerated()), id: \.offset) { index, track in
                        Text("\(index + 1) · \(track.title.isEmpty ? (track.sourceURL?.lastPathComponent ?? "源字幕") : track.title)")
                            .tag(index).disabled(!track.isIncluded)
                    }
                }
                Text("烧录字幕会禁用快速导出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if configuration.subtitles.mode != .remove {
                doubleField("时间偏移", value: $configuration.subtitles.timeOffsetSeconds, suffix: "秒")
            }
            if editing.changesSourceTimingForExport && configuration.subtitles.mode != .remove {
                Text("文字字幕随剪辑和变速重映射；软字幕将转为容器兼容格式。ASS 动画内部节奏不会自动变速。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var packagingSection: some View {
        UnifiedInspectorSection(title: "轨道与封装") {
            Picker("容器格式", selection: $configuration.container) {
                ForEach(MediaContainer.allCases, id: \.self) { container in
                    Text(container.displayName).tag(container)
                }
            }

            HStack {
                TextField("文件名", text: $outputFileName)
                    .textFieldStyle(.roundedBorder)
                Text(".\(configuration.container.fileExtension)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(outputDirectoryURL?.path ?? "未选择输出文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("更改…", action: chooseOutputFolder)
                    .controlSize(.small)
            }

            if configuration.trackSettings.isEmpty {
                Picker("轨道选择", selection: $configuration.streamSelection) {
                    ForEach(StreamSelection.allCases, id: \.self) { selection in
                        Text(selection.displayName).tag(selection)
                    }
                }
            } else {
                HStack {
                    Text("媒体轨道")
                    Spacer()
                    Text("已启用 \(enabledTrackCount) / \(configuration.trackSettings.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("保留附件（封面、字体）", isOn: $configuration.includeAttachments)
            Toggle("保留数据轨道", isOn: $configuration.includeDataStreams)
            Toggle("保留元数据", isOn: $configuration.containerOptions.preserveMetadata)
            Toggle("保留章节", isOn: $configuration.containerOptions.preserveChapters)
            if editing.changesSourceTimingForExport {
                Label("保留章节时，将按剪辑结果重新计算章节时间", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("网页播放优化（Fast Start）", isOn: $configuration.containerOptions.fastStart)
                .disabled(!configuration.container.supportsFastStart)
        }
    }

    private var advancedSection: some View {
        UnifiedInspectorSection(title: "高级") {
            Toggle("使用 VideoToolbox 硬件解码", isOn: $configuration.advanced.hardwareDecoding)
            doubleField("关键帧间隔", value: $configuration.video.keyframeIntervalSeconds, suffix: "秒")
            integerField("B 帧数量", value: $configuration.video.bFrames, suffix: "")
            integerField("线程数", value: $configuration.advanced.threadCount, suffix: "0 = 自动")
            Toggle("覆盖同名文件", isOn: $configuration.advanced.overwriteExisting)
            Text("HDR 转 SDR 会重算画面并移除旧高光元数据；动态 HDR 只在完整源片快速导出中原样保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !configuration.advanced.additionalArguments.isEmpty {
                Button("清空旧版附加参数") { configuration.advanced.additionalArguments = "" }
            }

            DisclosureGroup("压缩导出命令预览") {
                ScrollView(.horizontal) {
                    Text(commandPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var exportActions: some View {
        VStack(spacing: 9) {
            if let range = editing.simpleTrimRange() {
                if isScanningKeyframes {
                    ProgressView("正在检查无损裁切边界…").controlSize(.small)
                } else if let index = configuration.copyTrimIndex, !index.isAligned(range), let aligned = index.expandedRange(range) {
                    Button("向外对齐关键帧：\(aligned.start.formatted(.number.precision(.fractionLength(3))))–\(aligned.end.formatted(.number.precision(.fractionLength(3)))) 秒") {
                        guard editing.clips.count == 1 else { return }
                        editing.clips[0].sourceRange = aligned
                    }
                    .font(.caption)
                    .help("会保留边界外的额外画面。保持当前裁切位置请使用压缩导出；音频边界仍受编码包长度限制。")
                }
                if let keyframeError { Text(keyframeError).font(.caption).foregroundStyle(.orange) }
            }
            if !isFFmpegAvailable {
                Label("未检测到 FFmpeg", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("点击后自动加入导出队列")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let blocker = compressedExportBlockers.first {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    enqueueExport(.streamCopy)
                } label: {
                    Text("快速导出")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!quickExportAvailable)
                .help(quickExportHelp)
                .overlay {
                    if !quickExportAvailable {
                        Color.clear
                            .contentShape(Rectangle())
                            .help(quickExportHelp)
                    }
                }

                Button {
                    enqueueExport(.transcode)
                } label: {
                    Text("压缩导出")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!compressedExportAvailable)
                .help(compressedExportHelp)
                .overlay {
                    if !compressedExportAvailable {
                        Color.clear.contentShape(Rectangle()).help(compressedExportHelp)
                    }
                }
            }
        }
        .padding(14)
        .background(.bar)
    }

    private var baseExportAvailable: Bool {
        isFFmpegAvailable
            && !outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editing.clips.isEmpty
    }

    private var quickExportAvailable: Bool {
        baseExportAvailable && quickExportBlockers.isEmpty
    }

    private var quickExportBlockers: [String] {
        exportBlockers(mode: .streamCopy)
    }

    private var compressedExportBlockers: [String] { exportBlockers(mode: .transcode) }
    private var compressedExportAvailable: Bool { baseExportAvailable && compressedExportBlockers.isEmpty }
    private var compressedExportHelp: String {
        guard baseExportAvailable else { return "压缩导出不可用：请确认视频已加载、文件名已填写且 FFmpeg 可用" }
        return compressedExportBlockers.isEmpty
            ? "按当前编码设置导出，完成后核对实际位深和色度采样"
            : (["压缩导出不可用"] + compressedExportBlockers).joined(separator: "\n")
    }

    private func exportBlockers(mode: ExportMode) -> [String] {
        var exportConfiguration = configuration
        exportConfiguration.mode = mode
        return ExportPlan(configuration: exportConfiguration, editing: editing, sourceVideo: mediaProbe?.primaryVideoStream, primarySourceURL: asset.url).blockers
            + ExportPlan.fileBlockers(configuration: exportConfiguration, primarySourceURL: asset.url)
            + ExportPlan.destinationBlockers(request: exportRequest(mode: mode))
    }

    private var quickExportHelp: String {
        guard baseExportAvailable else {
            if !isFFmpegAvailable { return "快速导出不可用：未检测到 FFmpeg" }
            if editing.clips.isEmpty { return "快速导出不可用：视频尚未加载完成" }
            return "快速导出不可用：请填写输出文件名"
        }
        guard !quickExportBlockers.isEmpty else {
            return "视频与音频码流不重新编码；视频裁切已检查关键帧，音频边界受音频包长度限制。逐帧精确裁切请用压缩导出"
                + (configuration.subtitles.mode == .convert ? "；字幕按所选方式转换" : "")
        }
        return (["快速导出不可用"] + quickExportBlockers).joined(separator: "\n")
    }

    private var keyframeScanIdentity: String {
        let video = configuration.trackSettings.first { $0.isIncluded && $0.kind == .video }
        return "\(video?.id ?? asset.url.path):\(editing.simpleTrimRange() == nil ? "full" : "trim")"
    }

    private var outputBitDepthBinding: Binding<Int> {
        Binding(
            get: { configuration.video.pixelFormat.bitDepth ?? 0 },
            set: { newValue in
                if let depth = OutputBitDepth(rawValue: newValue) { updatePixelFormat(bitDepth: depth, chroma: outputChroma) }
                else { configuration.video.pixelFormat = .automatic }
            }
        )
    }

    private var chromaBinding: Binding<ChromaSubsampling> {
        Binding(
            get: { outputChroma },
            set: { newValue in updatePixelFormat(bitDepth: outputBitDepth, chroma: newValue) }
        )
    }

    private var outputBitDepth: OutputBitDepth {
        let depth = configuration.video.pixelFormat.bitDepth
            ?? mediaProbe?.primaryVideoStream?.bitDepth
            ?? 8
        return OutputBitDepth(rawValue: depth) ?? .twelve
    }

    private var outputChroma: ChromaSubsampling {
        configuration.video.pixelFormat.chromaSubsampling
            ?? mediaProbe?.primaryVideoStream?.chromaSubsampling
            ?? .fourTwoZero
    }

    private func updatePixelFormat(bitDepth: OutputBitDepth, chroma: ChromaSubsampling) {
        configuration.video.pixelFormat = .make(bitDepth: bitDepth, chroma: chroma)
    }

    private var requiresSoftwareEncoderHint: Bool {
        configuration.video.codec.isHardwareAccelerated
            && (outputChroma != .fourTwoZero
                || (outputBitDepth == .ten && configuration.video.codec == .h264VideoToolbox))
    }

    private var enabledTrackCount: Int {
        configuration.trackSettings.lazy.filter(\.isIncluded).count
    }

    private var commandPreview: String {
        FFmpegCommandBuilder().commandPreview(for: exportRequest(mode: .transcode))
    }

    private func exportRequest(mode: ExportMode) -> ExportRequest {
        let outputDirectory = outputDirectoryURL ?? asset.url.deletingLastPathComponent()
        let cleanedName = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = cleanedName.isEmpty ? "VideoBox-output" : cleanedName
        let destinationURL = outputDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(configuration.container.fileExtension)
        var previewConfiguration = configuration
        previewConfiguration.mode = mode
        return ExportRequest(
            sourceURL: asset.url,
            destinationURL: destinationURL,
            sourceDuration: sourceDuration,
            sourceVideo: mediaProbe?.primaryVideoStream,
            configuration: previewConfiguration,
            editing: editing
        )
    }

    private func integerField(_ title: String, value: Binding<Int>, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 82)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doubleField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 82)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UnifiedInspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.top, 10)
        } label: {
            Text(title)
                .font(.headline)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}
