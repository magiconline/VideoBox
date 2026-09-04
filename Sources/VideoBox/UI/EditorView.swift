import AVKit
import SwiftUI

struct EditorView: View {
    let asset: MediaAsset
    let mediaProbe: MediaProbe?
    let isProbing: Bool
    @ObservedObject var playerController: PlayerController
    @Binding var configuration: ExportConfiguration
    @Binding var editing: EditSettings
    let outputDirectoryURL: URL?
    @Binding var outputFileName: String
    let feedback: EditorFeedback?
    let isFFmpegAvailable: Bool
    let queueCount: Int
    let replaceVideo: () -> Void
    let closeVideo: () -> Void
    let chooseOutputFolder: () -> Void
    let enqueueExport: () -> Void
    let showQueue: () -> Void
    @State private var isShowingTrackEditor = false
    @State private var isShowingLargePreview = false
    @State private var isExportInspectorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            HSplitView {
                previewAndTimeline
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                if isExportInspectorVisible {
                    ExportInspectorView(
                        asset: asset,
                        sourceDuration: mediaProbe?.duration,
                        configuration: $configuration,
                        editing: $editing,
                        outputDirectoryURL: outputDirectoryURL,
                        outputFileName: $outputFileName,
                        isFFmpegAvailable: isFFmpegAvailable,
                        chooseOutputFolder: chooseOutputFolder,
                        enqueueExport: enqueueExport
                    )
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 430, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $isShowingTrackEditor) {
            MediaTrackEditorView(
                mediaProbe: mediaProbe,
                configuration: $configuration
            )
        }
        .sheet(isPresented: $isShowingLargePreview) {
            LargeVideoPreview(
                playerController: playerController,
                segment: editing.selectedClip,
                duration: mediaProbe?.duration
            )
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "film.stack.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let feedback {
                Label(feedback.message, systemImage: feedback.symbolName)
                    .font(.caption)
                    .foregroundStyle(feedback.color)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: replaceVideo) {
                Label("更换视频", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                isShowingTrackEditor = true
            } label: {
                Label("轨道与元数据", systemImage: "rectangle.stack")
            }

            Button(action: showQueue) {
                Label(
                    queueCount == 0 ? "队列" : "队列 \(queueCount)",
                    systemImage: "list.bullet.rectangle"
                )
            }

            Button(action: enqueueExport) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExport)

            Button {
                isExportInspectorVisible.toggle()
            } label: {
                Image(systemName: isExportInspectorVisible ? "chevron.right.square" : "slider.horizontal.3")
            }
            .help(isExportInspectorVisible ? "收起导出设置" : "展开导出设置")

            Button(action: closeVideo) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭当前视频")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var previewAndTimeline: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                EditedPlayerSurface(
                    playerController: playerController,
                    segment: editing.selectedClip,
                    duration: mediaProbe?.duration
                )

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isShowingLargePreview = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.bordered)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .help("在大窗口中预览")
                    }
                    Spacer()
                }
                .padding(10)

                if isProbing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取媒体信息…")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .layoutPriority(1)

            ClipTimelineEditorView(
                sourceURL: asset.url,
                sourceDuration: mediaProbe?.duration,
                playerController: playerController,
                editing: $editing,
                requiresTranscode: {
                    configuration.mode = .transcode
                }
            )
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var sourceSummary: String {
        guard let mediaProbe else {
            return isProbing ? "正在分析…" : asset.url.deletingLastPathComponent().path
        }

        var parts: [String] = []
        if let video = mediaProbe.primaryVideoStream {
            if let width = video.width, let height = video.height {
                parts.append("\(width) × \(height)")
            }
            if let codec = video.codecName {
                parts.append(codec.uppercased())
            }
            if let bitDepth = video.bitDepth {
                parts.append("\(bitDepth)-bit")
            }
            parts.append(video.hdrDescription)
        }
        if let bitRate = mediaProbe.averageBitRate {
            parts.append(formatBitRate(bitRate))
        }
        if let size = mediaProbe.sizeInBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append("\(mediaProbe.streams.count) 条轨道")
        return parts.joined(separator: "  ·  ")
    }

    private var canExport: Bool {
        isFFmpegAvailable
            && !outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editing.clips.isEmpty
    }

    private func formatBitRate(_ bitRate: Int64) -> String {
        if bitRate >= 1_000_000 {
            return "\((Double(bitRate) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\((Double(bitRate) / 1_000).formatted(.number.precision(.fractionLength(0)))) kbps"
    }
}

private struct LargeVideoPreview: View {
    @ObservedObject var playerController: PlayerController
    let segment: EditSegment?
    let duration: TimeInterval?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("视频预览", systemImage: "play.rectangle")
                    .font(.headline)

                Spacer()

                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ZStack {
                Color.black

                EditedPlayerSurface(
                    playerController: playerController,
                    segment: segment,
                    duration: duration
                )
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct ExportInspectorView: View {
    let asset: MediaAsset
    let sourceDuration: TimeInterval?
    @Binding var configuration: ExportConfiguration
    @Binding var editing: EditSettings
    let outputDirectoryURL: URL?
    @Binding var outputFileName: String
    let isFFmpegAvailable: Bool
    let chooseOutputFolder: () -> Void
    let enqueueExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出设置")
                        .font(.title2.bold())

                    Picker("导出方式", selection: $configuration.mode) {
                        ForEach(ExportMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Label(configuration.mode.detail, systemImage: modeSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    outputSection
                    streamSection

                    if configuration.mode == .transcode {
                        videoSection
                        audioSection
                    }

                    subtitleSection
                    containerSection
                    advancedSection
                    commandSection
                }
                .padding(16)
            }

            Divider()

            VStack(spacing: 8) {
                if !isFFmpegAvailable {
                    Label("未检测到 FFmpeg", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button(action: enqueueExport) {
                    Label("加入导出队列", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isFFmpegAvailable || outputFileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: configuration.video.codec) { codec in
            if !codec.supportedProfiles.contains(configuration.video.profile) {
                configuration.video.profile = .automatic
            }
        }
        .onChange(of: configuration.subtitles.mode) { mode in
            if mode == .burn {
                configuration.mode = .transcode
            }
        }
    }

    private var outputSection: some View {
        InspectorSection(title: "输出", symbol: "square.and.arrow.up") {
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
        }
    }

    private var streamSection: some View {
        InspectorSection(title: "轨道与封装", symbol: "rectangle.stack") {
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

                Text("可在顶部“轨道与元数据”中逐条编辑视频、音频和字幕轨道。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("保留附件（封面、字体）", isOn: $configuration.includeAttachments)
                .disabled(configuration.trackSettings.isEmpty && configuration.streamSelection == .primary)
            Toggle("保留数据轨道", isOn: $configuration.includeDataStreams)
                .disabled(configuration.trackSettings.isEmpty && configuration.streamSelection == .primary)

            if configuration.mode == .streamCopy {
                Label(
                    "视频和音频保持原始编码；截取会就近对齐关键帧。",
                    systemImage: "bolt.fill"
                )
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }

    private var enabledTrackCount: Int {
        configuration.trackSettings.lazy.filter(\.isIncluded).count
    }

    private var videoSection: some View {
        InspectorSection(title: "视频", symbol: "film") {
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
                        .frame(width: 26)
                }
            case .averageBitrate:
                integerField("平均码率", value: $configuration.video.averageBitrateKbps, suffix: "kbps")
                integerField("最大码率", value: $configuration.video.maximumBitrateKbps, suffix: "kbps")
                integerField("缓冲区", value: $configuration.video.bufferSizeKbps, suffix: "kbps")
            case .targetSize:
                integerField("目标大小", value: $configuration.video.targetSizeMB, suffix: "MB")
                integerField("备用码率", value: $configuration.video.averageBitrateKbps, suffix: "kbps")
                Text(sourceDuration == nil ? "无法读取时长时使用备用码率。" : "将根据片长和音频码率估算视频码率。")
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
                Picker("内容优化", selection: $configuration.video.tune) {
                    ForEach(EncoderTune.allCases, id: \.self) { tune in
                        Text(tune.displayName).tag(tune)
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
            Toggle("允许放大低分辨率视频", isOn: $configuration.video.allowUpscaling)

            Picker("帧率", selection: $configuration.video.frameRate) {
                ForEach(FrameRatePreset.allCases, id: \.self) { frameRate in
                    Text(frameRate.displayName).tag(frameRate)
                }
            }
            if configuration.video.frameRate == .custom {
                doubleField("自定义帧率", value: $configuration.video.customFrameRate, suffix: "fps")
            }

            Picker("像素格式", selection: $configuration.video.pixelFormat) {
                ForEach(PixelFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            doubleField("关键帧间隔", value: $configuration.video.keyframeIntervalSeconds, suffix: "秒")
            integerField("B 帧数量", value: $configuration.video.bFrames, suffix: "")
            Toggle("保留 HDR 色彩元数据", isOn: $configuration.video.preserveHDRMetadata)
        }
    }

    private var audioSection: some View {
        InspectorSection(title: "音频", symbol: "waveform") {
            Picker("音频编码", selection: $configuration.audio.codec) {
                ForEach(AudioCodec.allCases, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            if configuration.audio.codec != .none, configuration.audio.codec != .copy {
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
        InspectorSection(title: "字幕", symbol: "captions.bubble") {
            Picker("处理方式", selection: $configuration.subtitles.mode) {
                ForEach(SubtitleMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if configuration.subtitles.mode == .burn {
                integerField("烧录轨道序号", value: $configuration.subtitles.burnStreamIndex, suffix: "")
                Text("烧录字幕需要重新编码视频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if configuration.subtitles.mode != .remove {
                doubleField("时间偏移", value: $configuration.subtitles.timeOffsetSeconds, suffix: "秒")

                if editing.requiresFilterComposition {
                    Label(
                        "片段分割、复制或重排后，内嵌字幕无法原样拼接；请选择烧录字幕或移除字幕。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var containerSection: some View {
        InspectorSection(title: "元数据与容器", symbol: "shippingbox") {
            Toggle("保留元数据", isOn: $configuration.containerOptions.preserveMetadata)
            Toggle("保留章节", isOn: $configuration.containerOptions.preserveChapters)
            Toggle("网页播放优化（Fast Start）", isOn: $configuration.containerOptions.fastStart)
                .disabled(!configuration.container.supportsFastStart)
            Toggle("时间戳从零开始", isOn: $configuration.containerOptions.normalizeTimestamps)
            Toggle("修正负时间戳", isOn: $configuration.containerOptions.preventNegativeTimestamps)
        }
    }

    private var advancedSection: some View {
        InspectorSection(title: "高级", symbol: "slider.horizontal.3") {
            if configuration.mode == .transcode {
                Toggle("使用 VideoToolbox 硬件解码", isOn: $configuration.advanced.hardwareDecoding)
            }
            integerField("线程数", value: $configuration.advanced.threadCount, suffix: "0 = 自动")
            Toggle("覆盖同名文件", isOn: $configuration.advanced.overwriteExisting)
            TextField("附加 FFmpeg 参数", text: $configuration.advanced.additionalArguments)
                .textFieldStyle(.roundedBorder)
            Text("附加参数会直接传给 FFmpeg，不经过 shell。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commandSection: some View {
        DisclosureGroup {
            ScrollView(.horizontal) {
                Text(commandPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
            }
        } label: {
            Label("FFmpeg 命令预览", systemImage: "terminal")
                .font(.headline)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var commandPreview: String {
        let outputDirectory = outputDirectoryURL ?? asset.url.deletingLastPathComponent()
        let name = outputFileName.isEmpty ? "VideoBox-output" : outputFileName
        let destinationURL = outputDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(configuration.container.fileExtension)
        let request = ExportRequest(
            sourceURL: asset.url,
            destinationURL: destinationURL,
            sourceDuration: sourceDuration,
            configuration: configuration,
            editing: editing
        )
        return FFmpegCommandBuilder().commandPreview(for: request)
    }

    private var modeSymbol: String {
        configuration.mode == .streamCopy ? "bolt.fill" : "rectangle.compress.vertical"
    }

    private func integerField(
        _ title: String,
        value: Binding<Int>,
        suffix: String
    ) -> some View {
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

    private func doubleField(
        _ title: String,
        value: Binding<Double>,
        suffix: String
    ) -> some View {
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

private struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.top, 10)
        } label: {
            Label(title, systemImage: symbol)
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

private extension MediaProbe {
    var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
