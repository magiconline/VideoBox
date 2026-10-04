import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let asset: MediaAsset
    let mediaProbe: MediaProbe?
    let isLoadingVideo: Bool
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
    let enqueueExport: (ExportMode) -> Void
    let showQueue: () -> Void
    @State private var isShowingTrackEditor = false
    @State private var isExportInspectorVisible = true
    @State private var trackPreviewSelection = TrackPreviewSelection()
    @State private var trackPreviewStatus = TrackPreviewStatus.idle
    @State private var previewGenerationID = UUID()
    @State private var previewTask: Task<Void, Never>?
    @State private var loadedLUT: CubeLUT?
    @State private var lutLoadError: String?
    @State private var renderedPreview: RenderedPreviewRequest?
    @State private var isShowingMediaInfo = false
    @State private var isShowingLayers = false
    @State private var isShowingScopes = false

    var body: some View {
        VStack(spacing: 0) {
            if !playerController.isFullscreen {
                editorHeader
                Divider()
            }

            HSplitView {
                previewAndTimeline
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                if isExportInspectorVisible && !playerController.isFullscreen {
                    UnifiedExportInspectorView(
                        asset: asset,
                        mediaProbe: mediaProbe,
                        sourceDuration: mediaProbe?.duration,
                        configuration: $configuration,
                        editing: $editing,
                        outputDirectoryURL: outputDirectoryURL,
                        outputFileName: $outputFileName,
                        isFFmpegAvailable: isFFmpegAvailable,
                        chooseOutputFolder: chooseOutputFolder,
                        chooseLUT: chooseLUT,
                        removeLUT: removeLUT,
                        lutLoadError: lutLoadError,
                        enqueueExport: enqueueExport,
                        showRenderedPreview: showRenderedPreview
                    )
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 430, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $isShowingTrackEditor) {
            MediaTrackEditorView(
                mediaProbe: mediaProbe,
                primarySourceURL: asset.url,
                configuration: $configuration,
                previewSelection: $trackPreviewSelection,
                previewStatus: trackPreviewStatus,
                requestPreview: refreshTrackPreview
            )
        }
        .sheet(item: $renderedPreview) { input in RenderedExportPreviewView(input: input) }
        .sheet(isPresented: $isShowingMediaInfo) { if let mediaProbe { MediaInformationView(probe: mediaProbe) } }
        .sheet(isPresented: $isShowingLayers) { OverlayEditorView(editing: $editing) }
        .sheet(isPresented: $isShowingScopes) { VideoScopesView(controller: playerController) }
        .onAppear { playerController.configureAdvancedPreview(source: asset.url, configuration: configuration); playerController.updateTimeline(editing: editing) }
        .onChange(of: configuration) { _ in playerController.configureAdvancedPreview(source: asset.url, configuration: configuration) }
        .onChange(of: editing) { _ in playerController.updateTimeline(editing: editing) }
        .task(id: configuration.color.lutFile?.url) {
            do {
                loadedLUT = try configuration.color.lutFile.map { try CubeLUT.load(from: $0.url) }
                lutLoadError = nil; playerController.applyLUTPreview(configuration.color.isLUTEnabled ? loadedLUT : nil)
            } catch { lutLoadError = error.localizedDescription; loadedLUT = nil; playerController.applyLUTPreview(nil) }
        }
        .onDisappear {
            previewTask?.cancel()
        }
        .onChange(of: configuration.subtitles.timeOffsetSeconds) { _ in
            guard playerController.isUsingTrackPreview,
                  trackPreviewSelection.subtitleTrackID != nil else { return }
            refreshTrackPreview(using: trackPreviewSelection)
        }
        .onChange(of: configuration.color.isLUTEnabled) { isEnabled in
            playerController.applyLUTPreview(isEnabled ? loadedLUT : nil)
        }
    }

    private func showTrackEditor() {
        trackPreviewSelection.normalize(using: configuration.trackSettings)
        isShowingTrackEditor = true
    }

    private func showRenderedPreview() {
        playerController.pause()
        let request = ExportRequest(sourceURL: asset.url,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-preview.mp4"),
            sourceDuration: mediaProbe?.duration, sourceVideo: mediaProbe?.primaryVideoStream,
            configuration: configuration, editing: editing)
        renderedPreview = .make(request, at: playerController.outputTime)
    }

    private func refreshTrackPreview(using requestedSelection: TrackPreviewSelection) {
        var selection = requestedSelection
        selection.normalize(using: configuration.trackSettings)
        trackPreviewSelection = selection
        let selectedTracks = selection.selectedTracks(from: configuration.trackSettings)

        previewTask?.cancel()
        let generationID = UUID()
        previewGenerationID = generationID
        let shouldResume = playerController.isPlaying
        trackPreviewStatus = .building

        previewTask = Task { @MainActor in
            do {
                let previewAsset = try await environment.createTrackPreview(
                    primarySourceURL: asset.url,
                    tracks: selectedTracks,
                    duration: mediaProbe?.duration,
                    subtitleOffset: configuration.subtitles.timeOffsetSeconds
                )
                guard !Task.isCancelled, previewGenerationID == generationID else {
                    try? FileManager.default.removeItem(at: previewAsset.mediaURL)
                    if let subtitleURL = previewAsset.subtitleURL {
                        try? FileManager.default.removeItem(at: subtitleURL)
                    }
                    return
                }
                do {
                    try playerController.loadTrackPreview(
                        mediaURL: previewAsset.mediaURL,
                        subtitleURL: previewAsset.subtitleURL,
                        preservingTime: true,
                        resumesPlayback: shouldResume
                    )
                } catch {
                    try? FileManager.default.removeItem(at: previewAsset.mediaURL)
                    if let subtitleURL = previewAsset.subtitleURL {
                        try? FileManager.default.removeItem(at: subtitleURL)
                    }
                    throw error
                }
                trackPreviewStatus = .ready
            } catch is CancellationError {
                return
            } catch {
                guard previewGenerationID == generationID else { return }
                trackPreviewStatus = .failed("无法加载所选轨道，请检查轨道文件是否完整。")
            }
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                Text(asset.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Button("更换视频", action: replaceVideo)
                    .controlSize(.small)

                if let feedback {
                    Label(feedback.message, systemImage: feedback.symbolName)
                        .font(.caption)
                        .foregroundStyle(feedback.color)
                        .lineLimit(1)
                }

                Spacer()
                Menu("工具") {
                    Button("完整媒体信息…") { isShowingMediaInfo = true }.disabled(mediaProbe == nil)
                    Button("叠加轨道…") { isShowingLayers = true }.disabled(isLoadingVideo)
                    Button("直方图 / 波形图…") { isShowingScopes = true }.disabled(isLoadingVideo || playerController.isPreparingTimeline)
                }.fixedSize()

                Button {
                    showTrackEditor()
                } label: {
                    Label("轨道与元数据", systemImage: "rectangle.stack")
                }
                .disabled(isLoadingVideo)

                Button(action: showQueue) {
                    Label(
                        queueCount == 0 ? "队列" : "队列 \(queueCount)",
                        systemImage: "list.bullet.rectangle"
                    )
                }

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

            Text(sourceTechnicalSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(sourceTechnicalSummary)
                .padding(.leading, 34)

            Text(sourceColorSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(sourceColorSummary)
                .padding(.leading, 34)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var previewAndTimeline: some View {
        VStack(spacing: 0) {
            if !playerController.isFullscreen {
                HStack {
                    Text(playerController.isUsingTrackPreview ? "兼容代理 · 仅供实时参考；导出读取原片" : "实时参考预览 · 最终色彩与声音请用“核对导出效果”")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 12).padding(.top, 6)
            }
            ZStack {
                Color.black

                if isPreviewLoading {
                    VideoLoadingProgress()
                        .foregroundStyle(.white)
                        .tint(.white)
                        .transition(.opacity)
                } else {
                    EditedPlayerSurface(
                        playerController: playerController,
                        segment: playerController.activeClip,
                        duration: playerController.outputDuration,
                        lutInputLabel: previewInputLabel,
                        lutOutputLabel: configuration.color.outputColorSpace.shortDisplayName
                    )

                }
            }
            .animation(.easeInOut(duration: 0.18), value: isPreviewLoading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(playerController.isFullscreen ? 0 : 10)
            .layoutPriority(1)

            if !playerController.isFullscreen {
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
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var sourceTechnicalSummary: String {
        guard let mediaProbe else {
            return "正在读取视频格式与色彩信息…"
        }

        var parts: [String] = []
        if let video = mediaProbe.primaryVideoStream {
            if let width = video.width, let height = video.height {
                parts.append("\(width) × \(height)")
            }
            if let codec = video.codecName {
                let profile = video.codecProfile.map { " \($0)" } ?? ""
                parts.append("\(codec.uppercased())\(profile)")
            }
            if let frameRate = video.frameRate {
                parts.append("\(formatFrameRate(frameRate)) fps")
            }
            if let bitRate = mediaProbe.averageBitRate {
                parts.append(formatBitRate(bitRate))
            }
            if let bitDepth = video.bitDepth {
                parts.append("\(bitDepth)-bit")
            }
            if let chroma = video.chromaSubsampling {
                parts.append(chroma.displayName)
            }
        }
        if let size = mediaProbe.sizeInBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append("\(mediaProbe.streams.count) 条轨道")
        return parts.joined(separator: "  ·  ")
    }

    private var sourceColorSummary: String {
        guard let video = mediaProbe?.primaryVideoStream else {
            return "色彩信息将在视频解析完成后显示"
        }
        let logProfile = configuration.color.inputProfile == .automatic
            ? (CameraLogEvidence.read(video).profile?.displayName ?? "未确认")
            : configuration.color.inputProfile.displayName
        let primaries = friendlyColorValue(video.colorPrimaries)
        let transfer = friendlyColorValue(video.colorTransfer)
        let matrix = friendlyColorValue(video.colorSpace)
        let range = friendlyRange(video.colorRange)
        let chromaLocation = friendlyColorValue(video.chromaLocation)
        return [
            "输入声明：\(logProfile)",
            "原色：\(primaries)",
            "传递：\(transfer)",
            "矩阵：\(matrix)",
            "范围：\(range)",
            "色度位置：\(chromaLocation)",
            "HDR：\(video.hdrDescription)"
        ].joined(separator: "  ·  ")
    }

    private var canExport: Bool {
        isFFmpegAvailable
            && !outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editing.clips.isEmpty
    }

    private var isPreviewLoading: Bool {
        isLoadingVideo || trackPreviewStatus.isBuilding
    }

    private func formatBitRate(_ bitRate: Int64) -> String {
        if bitRate >= 1_000_000 {
            return "\((Double(bitRate) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\((Double(bitRate) / 1_000).formatted(.number.precision(.fractionLength(0)))) kbps"
    }

    private var previewInputLabel: String {
        configuration.color.inputProfile == .automatic
            ? "原片"
            : configuration.color.inputProfile.displayName
    }

    private func formatFrameRate(_ frameRate: Double) -> String {
        frameRate.formatted(.number.precision(.fractionLength(frameRate.rounded() == frameRate ? 0 : 2)))
    }

    private func friendlyColorValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未标记" }
        switch value.lowercased() {
        case "bt709": return "BT.709"
        case "bt2020": return "BT.2020"
        case "bt2020nc": return "BT.2020 NCL"
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        case "iec61966-2-1": return "sRGB"
        case "smpte432": return "Display P3"
        case "left": return "Left"
        case "center": return "Center"
        default: return value.uppercased()
        }
    }

    private func friendlyRange(_ value: String?) -> String {
        switch value?.lowercased() {
        case "tv", "limited", "mpeg": "Limited"
        case "pc", "full", "jpeg": "Full"
        default: "未标记"
        }
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.title = "选择 .cube LUT（1D / 3D / Shaper）"
        panel.prompt = "加载 LUT"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let cubeType = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [cubeType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lut = try CubeLUT.load(from: url)
            loadedLUT = lut
            lutLoadError = nil
            configuration.color.lutFile = LUTFileReference(url: url)
            configuration.color.isLUTEnabled = true
            // A LUT filename describes the LUT, never the actual footage.
            configuration.color.confirmsLUTCompatibility = false
            if configuration.color.outputColorSpace == .source {
                configuration.color.outputColorSpace = .rec709SDR
            }
            if configuration.color.outputRange == .source {
                configuration.color.outputRange = .limited
            }
            playerController.applyLUTPreview(lut)
        } catch {
            lutLoadError = error.localizedDescription
        }
    }

    private func removeLUT() {
        loadedLUT = nil
        lutLoadError = nil
        configuration.color.isLUTEnabled = false
        configuration.color.lutFile = nil
        configuration.color.outputColorSpace = .source
        configuration.color.outputRange = .source
        playerController.applyLUTPreview(nil)
    }
}

struct VideoLoadingProgress: View {
    var width: CGFloat = 240
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 9) {
            Text("正在加载视频…")
                .font(.caption.weight(.medium))

            GeometryReader { proxy in
                let segmentWidth = max(52, proxy.size.width * 0.34)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.34))

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: segmentWidth)
                        .offset(x: isAnimating ? proxy.size.width - segmentWidth : 0)
                }
                .clipShape(Capsule())
            }
            .frame(width: width, height: 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在加载视频")
        .accessibilityValue("加载中")
        .accessibilityIdentifier("video-loading-progress")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
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
