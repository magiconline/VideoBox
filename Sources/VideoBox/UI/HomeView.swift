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
    @State private var isProbing = false
    @State private var feedback: EditorFeedback?

    var body: some View {
        NavigationStack {
            Group {
                if let selectedAsset {
                    EditorView(
                        asset: selectedAsset,
                        mediaProbe: mediaProbe,
                        isProbing: isProbing,
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
        let asset = MediaAsset(url: url)
        selectedAsset = asset
        playerController.load(url: url)
        mediaProbe = nil
        isProbing = true
        feedback = nil
        editing = EditSettings()
        configuration = ExportConfiguration()
        configuration.container = MediaContainer(rawValue: url.pathExtension.lowercased()) ?? .mp4
        outputDirectoryURL = url.deletingLastPathComponent()
        outputFileName = "\(url.deletingPathExtension().lastPathComponent)-VideoBox"

        Task { @MainActor in
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
                configuration.trackSettings = probe.streams
                    .filter {
                        [.video, .audio, .subtitle].contains($0.kind)
                            && !$0.isAttachedPicture
                    }
                    .map { stream in
                        TrackExportSettings(
                            streamIndex: stream.index,
                            kind: stream.kind,
                            title: stream.title ?? "",
                            language: stream.language ?? "",
                            isDefault: stream.isDefault
                        )
                    }
                configuration.metadataEntries = probe.metadata
                    .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                    .map { MetadataExportEntry(key: $0.key, value: $0.value) }
            } catch {
                guard selectedAsset?.url == url else { return }
                feedback = .warning(error.localizedDescription)
            }
            isProbing = false
        }
    }

    private func closeVideo() {
        playerController.pause()
        selectedAsset = nil
        mediaProbe = nil
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
