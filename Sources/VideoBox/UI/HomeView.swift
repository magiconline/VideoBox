import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var playerController = PlayerController()

    @State private var selectedAsset: MediaAsset?
    @State private var mediaProbe: MediaProbe?
    @State private var configuration = ExportConfiguration()
    @State private var editing = EditSettings()
    @State private var outputDirectoryURL: URL?
    @State private var outputFileName = ""
    @State private var isShowingImporter = false
    @State private var isShowingQueue = false
    @State private var isDropTarget = false
    @State private var isLoadingVideo = false
    @State private var feedback: EditorFeedback?
    @State private var mediaLoadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let selectedAsset {
                    EditorView(
                        asset: selectedAsset,
                        mediaProbe: mediaProbe,
                        isLoadingVideo: isLoadingVideo,
                        playerController: playerController,
                        configuration: $configuration,
                        editing: $editing,
                        outputDirectoryURL: outputDirectoryURL,
                        outputFileName: $outputFileName,
                        feedback: feedback,
                        isFFmpegAvailable: isFFmpegAvailable,
                        queueCount: environment.jobQueue.jobs.count,
                        replaceVideo: { isShowingImporter = true },
                        closeVideo: closeVideo,
                        chooseOutputFolder: chooseOutputFolder,
                        enqueueExport: enqueueExport,
                        showQueue: { isShowingQueue = true }
                    )
                } else {
                    UploadLandingView(
                        isDropTarget: isDropTarget,
                        chooseVideo: { isShowingImporter = true }
                    )
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        isTargeted: $isDropTarget,
                        perform: acceptDrop
                    )
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("VideoBox")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isShowingQueue = true
                    } label: {
                        Label(
                            environment.jobQueue.jobs.isEmpty
                                ? "导出队列"
                                : "导出队列（\(environment.jobQueue.jobs.count)）",
                            systemImage: "list.bullet.rectangle"
                        )
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .sheet(isPresented: $isShowingQueue) {
            NavigationStack {
                JobQueueView(queue: environment.jobQueue)
            }
            .frame(minWidth: 620, minHeight: 420)
        }
        .task {
            await environment.refreshToolchain()
        }
        .onDisappear {
            mediaLoadTask?.cancel()
            playerController.pause()
        }
    }

    private var isFFmpegAvailable: Bool {
        environment.toolchainReport.executableURL(for: .ffmpeg) != nil
    }

    private var allowedContentTypes: [UTType] {
        var types: [UTType] = [.movie, .audiovisualContent]
        for fileExtension in ["mkv", "webm", "ts", "m2ts"] {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            openVideo(url)
        case let .failure(error):
            feedback = .error("无法打开文件：\(error.localizedDescription)")
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                openVideo(url)
            }
        }
        return true
    }

    private func openVideo(_ url: URL) {
        mediaLoadTask?.cancel()
        let asset = MediaAsset(url: url)
        selectedAsset = asset
        playerController.load(url: url)
        mediaProbe = nil
        isLoadingVideo = true
        feedback = nil
        editing = EditSettings()
        configuration = ExportConfiguration()
        configuration.container = MediaContainer(rawValue: url.pathExtension.lowercased()) ?? .mp4
        outputDirectoryURL = url.deletingLastPathComponent()
        outputFileName = "\(url.deletingPathExtension().lastPathComponent)-VideoBox"

        mediaLoadTask = Task { @MainActor in
            do {
                let probe = try await environment.probeMedia(at: url)
                guard selectedAsset?.url == url else { return }
                mediaProbe = probe
                if let duration = probe.duration, duration > 0 {
                    editing.initialize(
                        duration: duration,
                        canvasWidth: probe.primaryVideoStream?.width,
                        canvasHeight: probe.primaryVideoStream?.height
                    )
                }
                let trackSettings = probe.streams
                    .filter {
                        [.video, .audio, .subtitle].contains($0.kind)
                            && !$0.isAttachedPicture
                    }
                    .map { stream in
                        TrackExportSettings(
                            sourceURL: url,
                            stream: stream,
                            sourceDuration: probe.duration
                        )
                    }
                configuration.trackSettings = trackSettings
                configuration.metadataEntries = probe.metadata
                    .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                    .map { MetadataExportEntry(key: $0.key, value: $0.value) }
                if !(await MediaPlaybackCompatibility.isPlayableVideo(at: url)) {
                    var selection = TrackPreviewSelection()
                    selection.normalize(using: trackSettings)
                    let previewAsset = try await environment.createTrackPreview(
                        primarySourceURL: url,
                        tracks: selection.selectedTracks(from: trackSettings),
                        duration: probe.duration,
                        subtitleOffset: 0
                    )
                    guard !Task.isCancelled,
                          selectedAsset?.url == url,
                          playerController.sourceURL == url else {
                        try? FileManager.default.removeItem(at: previewAsset.mediaURL)
                        if let subtitleURL = previewAsset.subtitleURL {
                            try? FileManager.default.removeItem(at: subtitleURL)
                        }
                        return
                    }
                    try playerController.loadTrackPreview(
                        mediaURL: previewAsset.mediaURL,
                        subtitleURL: previewAsset.subtitleURL,
                        preservingTime: true,
                        resumesPlayback: playerController.isPlaying
                    )
                }
            } catch {
                if error is CancellationError { return }
                guard selectedAsset?.url == url else { return }
                feedback = .error("视频加载失败，请检查文件是否完整或尝试其他文件。")
            }
            guard !Task.isCancelled, selectedAsset?.url == url else { return }
            isLoadingVideo = false
        }
    }

    private func closeVideo() {
        mediaLoadTask?.cancel()
        mediaLoadTask = nil
        playerController.clear()
        selectedAsset = nil
        mediaProbe = nil
        isLoadingVideo = false
        feedback = nil
        outputDirectoryURL = nil
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择导出文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectoryURL

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectoryURL = url
        }
    }

    private func enqueueExport() {
        guard let selectedAsset, let outputDirectoryURL else { return }
        guard isFFmpegAvailable else {
            feedback = .error("未检测到 FFmpeg，当前无法导出。")
            return
        }
        if let validationMessage = validateTrackExport(
            primarySourceURL: selectedAsset.url,
            configuration: configuration,
            editing: editing
        ) {
            feedback = .error(validationMessage)
            return
        }

        let sanitizedName = outputFileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitizedName.isEmpty else {
            feedback = .error("请输入导出文件名。")
            return
        }

        let destinationURL = outputDirectoryURL
            .appendingPathComponent(sanitizedName)
            .appendingPathExtension(configuration.container.fileExtension)

        if FileManager.default.fileExists(atPath: destinationURL.path),
           !configuration.advanced.overwriteExisting {
            feedback = .error("同名文件已存在，请修改文件名或启用覆盖。")
            return
        }

        let request = ExportRequest(
            sourceURL: selectedAsset.url,
            destinationURL: destinationURL,
            sourceDuration: mediaProbe?.duration,
            configuration: configuration,
            editing: editing
        )
        environment.enqueueExport(request)
        feedback = .success("已开始导出：\(destinationURL.lastPathComponent)")
    }

    private func validateTrackExport(
        primarySourceURL: URL,
        configuration: ExportConfiguration,
        editing: EditSettings
    ) -> String? {
        guard !configuration.trackSettings.isEmpty else { return nil }
        let includedTracks = configuration.trackSettings.filter(\.isIncluded)
        guard includedTracks.contains(where: { $0.kind == .video }) else {
            return "成片导出至少需要启用一条视频轨道。"
        }

        let usedTracks = includedTracks.filter {
            !($0.kind == .subtitle
                && (configuration.subtitles.mode == .remove || configuration.subtitles.mode == .burn))
        }
        if let missingTrack = usedTracks.first(where: {
            !FileManager.default.fileExists(
                atPath: $0.resolvedSourceURL(primarySourceURL: primarySourceURL).path
            )
        }) {
            let sourceURL = missingTrack.resolvedSourceURL(primarySourceURL: primarySourceURL)
            return "轨道源文件已不可用：\(sourceURL.lastPathComponent)"
        }

        if editing.requiresFilterComposition {
            let videoCount = includedTracks.filter { $0.kind == .video }.count
            if videoCount > 1 {
                return "片段剪切、重排或变速时只能保留一条视频轨道；请关闭其他视频轨道后再导出。"
            }
            if includedTracks.contains(where: { $0.kind == .subtitle }),
               configuration.subtitles.mode == .copy || configuration.subtitles.mode == .convert {
                return "片段剪切、重排或变速后无法直接保留软字幕；请选择烧录字幕或移除字幕。"
            }
        }

        guard configuration.mode == .streamCopy else { return nil }
        let codecsByKind: (MediaStreamKind) -> [String] = { kind in
            includedTracks
                .filter { $0.kind == kind }
                .compactMap { $0.codecName?.lowercased() }
        }

        if configuration.container == .mp4 || configuration.container == .mov {
            let unsupportedSubtitles = codecsByKind(.subtitle).filter { $0 != "mov_text" }
            if !unsupportedSubtitles.isEmpty, configuration.subtitles.mode == .copy {
                return "当前字幕编码不适合 \(configuration.container.displayName)，请将字幕处理方式改为“转换为容器兼容格式”。"
            }
        }
        if configuration.container == .webm {
            let supportedVideo = Set(["vp8", "vp9", "av1"])
            let supportedAudio = Set(["opus", "vorbis"])
            if codecsByKind(.video).contains(where: { !supportedVideo.contains($0) })
                || codecsByKind(.audio).contains(where: { !supportedAudio.contains($0) }) {
                return "WebM 无法直接容纳当前启用的编码；请选择压缩导出、更换容器或关闭不兼容轨道。"
            }
            if includedTracks.contains(where: { $0.kind == .subtitle }),
               configuration.subtitles.mode == .copy {
                return "WebM 字幕需要转换为 WebVTT，请将字幕处理方式设为转换。"
            }
        }
        return nil
    }
}

enum EditorFeedback: Equatable {
    case success(String)
    case warning(String)
    case error(String)

    var message: String {
        switch self {
        case let .success(message), let .warning(message), let .error(message): message
        }
    }

    var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct UploadLandingView: View {
    let isDropTarget: Bool
    let chooseVideo: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 28)

            VStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("VideoBox")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("导入视频，然后在一个工作台里完成剪辑、格式转换与压缩。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button(action: chooseVideo) {
                VStack(spacing: 16) {
                    Image(systemName: isDropTarget ? "arrow.down.circle.fill" : "square.and.arrow.down")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)

                    VStack(spacing: 6) {
                        Text(isDropTarget ? "松开以导入视频" : "拖入视频，或点击选择")
                            .font(.title2.bold())
                        Text("支持 MP4、MOV、MKV、WebM、TS 等 FFmpeg 可读取格式")
                            .font(.subheadline)
                            .foregroundStyle(isDropTarget ? .white.opacity(0.8) : .secondary)
                    }
                }
                .frame(maxWidth: 680, minHeight: 230)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(isDropTarget ? Color.accentColor : Color.accentColor.opacity(0.07))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(
                            isDropTarget ? Color.white.opacity(0.7) : Color.accentColor.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 7])
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
