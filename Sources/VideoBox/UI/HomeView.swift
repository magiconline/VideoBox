import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var playerController = PlayerController()

    @State private var selectedAsset: MediaAsset?
    @State private var mediaProbe: MediaProbe?
    @StateObject private var session = ProjectSession()
    private var configuration: ExportConfiguration { get { session.configuration } nonmutating set { session.configuration = newValue } }
    private var editing: EditSettings { get { session.editing } nonmutating set { session.editing = newValue } }
    @State private var outputDirectoryURL: URL?
    @State private var outputFileName = ""
    @State private var isShowingImporter = false
    @State private var isShowingQueue = false
    @State private var isDropTarget = false
    @State private var isLoadingVideo = false
    @State private var feedback: EditorFeedback?
    @State private var mediaLoadTask: Task<Void, Never>?
    @State private var recoveryProject: VideoBoxProject?

    var body: some View {
        NavigationStack {
            Group {
                if let selectedAsset {
                    EditorView(
                        asset: selectedAsset,
                        mediaProbe: mediaProbe,
                        isLoadingVideo: isLoadingVideo,
                        playerController: playerController,
                        configuration: $session.configuration,
                        editing: $session.editing,
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
                    .overlay(alignment: .bottom) {
                        VStack {
                            if let feedback { Text(feedback.message).foregroundStyle(feedback.color) }
                            if let recoveryProject { Button("恢复上次编辑：\(recoveryProject.sourceURL.lastPathComponent)") { openProject(recoveryProject, fileURL: nil) } }
                        }.padding(24)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("VideoBox")
            .toolbar {
                ToolbarItemGroup {
                    Button("打开工程", action: chooseProject).keyboardShortcut("o", modifiers: [.command, .shift])
                    if selectedAsset != nil {
                        Button("保存工程", action: saveProject).keyboardShortcut("s", modifiers: .command)
                        Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!session.canUndo).help("撤销（⌘Z）")
                        Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!session.canRedo).help("重做（⇧⌘Z）")
                        Button("添加素材", action: appendMedia)
                        Text(session.isDirty ? "未保存 · 自动恢复已开启" : (session.projectURL?.lastPathComponent ?? "未命名工程"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            recoveryProject = session.recovery()
        }
        .focusedSceneValue(\.projectActions, ProjectActions(session: session, open: chooseProject, save: saveProject,
                                                           saveAs: { saveProject(asNew: true) }, appendMedia: appendMedia))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in session.autosave(); environment.prepareForTermination() }
        .onDisappear { session.autosave() }
        .overlay(alignment: .bottomLeading) { if let error = session.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding(8).background(.bar) } }
        .onOpenURL { url in
            if url.pathExtension == "vboxproject" { readProject(url) } else { openVideo(url) }
        }
        .onChange(of: outputDirectoryURL) { value in session.outputDirectoryURL = value; session.autosave() }
        .onChange(of: outputFileName) { value in session.outputFileName = value; session.autosave() }
        .onChange(of: playerController.outputTime) { value in session.playhead = value }
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
        session.autosave()
        session.sourceURL = nil
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
                session.begin(VideoBoxProject(sourceURL: url, editing: editing, configuration: configuration,
                    outputDirectoryURL: outputDirectoryURL, outputFileName: outputFileName))
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
        session.autosave()
        recoveryProject = session.recovery()
        mediaLoadTask?.cancel()
        mediaLoadTask = nil
        playerController.clear()
        selectedAsset = nil
        mediaProbe = nil
        isLoadingVideo = false
        feedback = nil
        outputDirectoryURL = nil
        session.sourceURL = nil
    }

    private func chooseProject() {
        let panel = NSOpenPanel(); panel.title = "打开 VideoBox 工程"; panel.allowedFileTypes = ["vboxproject"]
        if panel.runModal() == .OK, let url = panel.url { readProject(url) }
    }

    private func readProject(_ url: URL) {
        do { openProject(try VideoBoxProject.read(url), fileURL: url) }
        catch { feedback = .error("工程打开失败：\(error.localizedDescription)") }
    }

    private func openProject(_ project: VideoBoxProject, fileURL: URL?) {
        var project = project
        for missing in project.referencedURLs where !FileManager.default.isReadableFile(atPath: missing.path) {
            let panel = NSOpenPanel(); panel.title = "重新定位：\(missing.lastPathComponent)"; panel.prompt = "使用此文件"
            guard panel.runModal() == .OK, let replacement = panel.url else { return }
            if project.sourceURL == missing { project.sourceURL = replacement }
            for i in project.editing.clips.indices where project.editing.clips[i].sourceURL == missing { project.editing.clips[i].sourceURL = replacement }
            for i in project.editing.overlayClips.indices where project.editing.overlayClips[i].sourceURL == missing { project.editing.overlayClips[i].sourceURL = replacement }
            for i in project.configuration.trackSettings.indices where project.configuration.trackSettings[i].sourceURL == missing { project.configuration.trackSettings[i].sourceURL = replacement }
            if project.configuration.color.lutFile?.url == missing { project.configuration.color.lutFile = LUTFileReference(url: replacement) }
        }
        session.autosave(); mediaLoadTask?.cancel()
        session.begin(project, fileURL: fileURL)
        selectedAsset = MediaAsset(url: project.sourceURL); mediaProbe = nil; isLoadingVideo = true
        outputDirectoryURL = project.outputDirectoryURL ?? project.sourceURL.deletingLastPathComponent()
        outputFileName = project.outputFileName; feedback = nil
        playerController.load(url: project.sourceURL)
        mediaLoadTask = Task { @MainActor in
            do {
                let probe = try await environment.probeMedia(at: project.sourceURL)
                guard !Task.isCancelled, selectedAsset?.url == project.sourceURL else { return }
                mediaProbe = probe
                var refreshed = editing; refreshed.sourceDuration = probe.duration ?? refreshed.sourceDuration
                var probes: [URL: MediaProbe] = [project.sourceURL: probe]
                for url in Set(refreshed.referencedURLs) {
                    probes[url] = try await environment.probeMedia(at: url)
                    guard !Task.isCancelled, selectedAsset?.url == project.sourceURL else { return }
                }
                for index in refreshed.clips.indices {
                    if let url = refreshed.clips[index].sourceURL, let info = probes[url] { refreshed.clips[index].media = ClipMedia(info) }
                }
                for index in refreshed.overlayClips.indices {
                    if let info = probes[refreshed.overlayClips[index].sourceURL] { refreshed.overlayClips[index].media = ClipMedia(info) }
                }
                var restored = project; restored.editing = refreshed
                for index in restored.configuration.trackSettings.indices {
                    let track = restored.configuration.trackSettings[index], url = track.resolvedSourceURL(primarySourceURL: project.sourceURL)
                    if let info = probes[url], let stream = info.streams.first(where: { $0.index == track.streamIndex && $0.kind == track.kind }) {
                        restored.configuration.trackSettings[index].sourceStream = stream; restored.configuration.trackSettings[index].sourceDuration = info.duration
                    }
                }
                session.begin(restored, fileURL: fileURL)
                if !refreshed.requiresRenderedPreview, !(await MediaPlaybackCompatibility.isPlayableVideo(at: project.sourceURL)) {
                    var selection = TrackPreviewSelection(); selection.normalize(using: restored.configuration.trackSettings)
                    let preview = try await environment.createTrackPreview(primarySourceURL: project.sourceURL, tracks: selection.selectedTracks(from: restored.configuration.trackSettings), duration: probe.duration, subtitleOffset: restored.configuration.subtitles.timeOffsetSeconds)
                    guard !Task.isCancelled, selectedAsset?.url == project.sourceURL else {
                        try? FileManager.default.removeItem(at: preview.mediaURL)
                        if let subtitle = preview.subtitleURL { try? FileManager.default.removeItem(at: subtitle) }; return
                    }
                    try playerController.loadTrackPreview(mediaURL: preview.mediaURL, subtitleURL: preview.subtitleURL, preservingTime: true, resumesPlayback: false)
                }
                playerController.updateTimeline(editing: editing); playerController.seekOutput(to: project.playhead)
                isLoadingVideo = false
            } catch is CancellationError { return }
            catch { guard selectedAsset?.url == project.sourceURL else { return }; isLoadingVideo = false; feedback = .error("工程素材加载失败：\(error.localizedDescription)") }
        }
    }

    private func saveProject() { saveProject(asNew: false) }
    private func saveProject(asNew: Bool) {
        guard selectedAsset != nil else { return }
        var url = asNew ? nil : session.projectURL
        if url == nil {
            let panel = NSSavePanel(); panel.title = "保存 VideoBox 工程"; panel.allowedFileTypes = ["vboxproject"]
            panel.nameFieldStringValue = "\(selectedAsset!.url.deletingPathExtension().lastPathComponent).vboxproject"
            guard panel.runModal() == .OK else { return }; url = panel.url
        }
        do { try session.save(to: url!); feedback = .success("工程已保存") }
        catch { feedback = .error(error.localizedDescription) }
    }

    private func appendMedia() {
        guard selectedAsset != nil else { return }
        let panel = NSOpenPanel(); panel.title = "添加时间线素材"; panel.allowsMultipleSelection = true; panel.allowedContentTypes = allowedContentTypes
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let source = selectedAsset?.url
        mediaLoadTask?.cancel()
        mediaLoadTask = Task { @MainActor in
            for url in urls {
                do {
                    let probe = try await environment.probeMedia(at: url)
                    guard !Task.isCancelled, selectedAsset?.url == source else { return }
                    guard let duration = probe.duration, duration > 0, probe.primaryVideoStream != nil else { feedback = .error("此文件没有可用的视频画面"); continue }
                    var clip = EditSegment(sourceRange: TimelineRange(start: 0, duration: duration))
                    clip.sourceURL = url; clip.media = ClipMedia(probe)
                    editing.clips.append(clip); editing.selectedClipID = clip.id
                    configuration.mode = .transcode
                } catch { feedback = .error("素材读取失败：\(error.localizedDescription)") }
            }
        }
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

    private func enqueueExport(mode: ExportMode) {
        guard let selectedAsset, let outputDirectoryURL else { return }
        guard isFFmpegAvailable else {
            feedback = .error("未检测到 FFmpeg，当前无法导出。")
            return
        }
        var exportConfiguration = configuration
        exportConfiguration.mode = mode

        let plan = ExportPlan(configuration: exportConfiguration, editing: editing, sourceVideo: mediaProbe?.primaryVideoStream, primarySourceURL: selectedAsset.url)
        let blockers = plan.blockers + ExportPlan.fileBlockers(configuration: exportConfiguration, primarySourceURL: selectedAsset.url)
        if !blockers.isEmpty {
            feedback = .error("\(mode.displayName)不可用：\(blockers.joined(separator: "、"))")
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
            .appendingPathExtension(exportConfiguration.container.fileExtension)

        if FileManager.default.fileExists(atPath: destinationURL.path),
           !exportConfiguration.advanced.overwriteExisting {
            feedback = .error("同名文件已存在，请修改文件名或启用覆盖。")
            return
        }

        let request = ExportRequest(
            sourceURL: selectedAsset.url,
            destinationURL: destinationURL,
            sourceDuration: mediaProbe?.duration,
            sourceVideo: mediaProbe?.primaryVideoStream,
            configuration: exportConfiguration,
            editing: editing
        )
        let destinationBlockers = ExportPlan.destinationBlockers(request: request)
        if !destinationBlockers.isEmpty {
            feedback = .error(destinationBlockers.joined(separator: "、"))
            return
        }
        environment.enqueueExport(request)
        configuration.mode = mode
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
