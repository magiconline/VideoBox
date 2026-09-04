import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TrackPreviewStatus: Equatable {
    case idle
    case building
    case ready
    case failed(String)

    var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

private enum TrackEditorNotice: Equatable {
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

struct MediaTrackEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let mediaProbe: MediaProbe?
    let primarySourceURL: URL
    @Binding var configuration: ExportConfiguration
    @Binding var previewSelection: TrackPreviewSelection
    let previewStatus: TrackPreviewStatus
    let requestPreview: (TrackPreviewSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notice: TrackEditorNotice?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("轨道与元数据")
                        .font(.title2.bold())
                    Text("导入、预览、提取和排列视频、音频与字幕轨道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if previewStatus.isBuilding {
                    VideoLoadingProgress(width: 220)
                } else if let message = previewStatus.failureMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(maxWidth: 300, alignment: .trailing)
                } else if let notice {
                    Label(notice.message, systemImage: notice.symbolName)
                        .font(.caption)
                        .foregroundStyle(notice.color)
                        .lineLimit(1)
                        .frame(maxWidth: 300, alignment: .trailing)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            TabView {
                trackPage(.video)
                    .tabItem { Label("视频轨道", systemImage: "film") }

                trackPage(.audio)
                    .tabItem { Label("音频轨道", systemImage: "waveform") }

                trackPage(.subtitle)
                    .tabItem { Label("字幕轨道", systemImage: "captions.bubble") }

                MetadataSettingsPage(
                    mediaProbe: mediaProbe,
                    entries: $configuration.metadataEntries,
                    preserveSourceMetadata: $configuration.containerOptions.preserveMetadata
                )
                .tabItem { Label("元数据", systemImage: "tag") }
            }
            .padding(14)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func trackPage(_ kind: MediaStreamKind) -> some View {
        TrackSettingsPage(
            kind: kind,
            primarySourceURL: primarySourceURL,
            configuration: $configuration,
            previewSelection: $previewSelection,
            requestPreview: requestPreview,
            exportTrack: exportTrack,
            reportNotice: { notice = $0 }
        )
    }

    private func exportTrack(_ track: TrackExportSettings) {
        let sourceURL = track.resolvedSourceURL(primarySourceURL: primarySourceURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            notice = .error("轨道源文件已不可用：\(sourceURL.lastPathComponent)")
            return
        }

        let fileExtension = track.suggestedExtractionExtension
        let panel = NSSavePanel()
        panel.title = "单独导出\(track.kind.shortDisplayName)轨道"
        panel.prompt = "导出轨道"
        panel.canCreateDirectories = true
        if let contentType = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [contentType]
        }
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = title.isEmpty
            ? "\(track.kind.shortDisplayName)-\(track.streamIndex + 1)"
            : title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(sourceName)-\(suffix).\(fileExtension)"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        environment.enqueueTrackExtraction(
            track,
            primarySourceURL: primarySourceURL,
            destinationURL: destinationURL,
            overwriteExisting: FileManager.default.fileExists(atPath: destinationURL.path)
        )
        notice = .success("已加入单轨导出队列：\(destinationURL.lastPathComponent)")
    }
}

private struct TrackSettingsPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    let kind: MediaStreamKind
    let primarySourceURL: URL
    @Binding var configuration: ExportConfiguration
    @Binding var previewSelection: TrackPreviewSelection
    let requestPreview: (TrackPreviewSelection) -> Void
    let exportTrack: (TrackExportSettings) -> Void
    let reportNotice: (TrackEditorNotice) -> Void

    @State private var isImporting = false
    @State private var importCandidates: [TrackImportCandidate] = []
    @State private var isSelectingImports = false
    @State private var draggedTrackID: String?

    private var matchingTracks: [TrackExportSettings] {
        configuration.trackSettings.filter { $0.kind == kind }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.headline)
                    Text("顺序将作为成片中的\(kind.shortDisplayName)轨道编号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isImporting {
                    ProgressView("正在读取轨道…")
                        .controlSize(.small)
                }
                Button(action: chooseImportFiles) {
                    Label("导入轨道", systemImage: "plus")
                }
                .disabled(isImporting)
            }

            if matchingTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("没有检测到\(kind.displayName)")
                        .font(.headline)
                    Text("当前文件中没有此类轨道，你可以从其他文件导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("导入\(kind.shortDisplayName)轨道", action: chooseImportFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(matchingTracks.enumerated()), id: \.element.id) { position, track in
                            if let index = configuration.trackSettings.firstIndex(where: { $0.id == track.id }) {
                                TrackSettingsRow(
                                    position: position,
                                    totalCount: matchingTracks.count,
                                    primarySourceURL: primarySourceURL,
                                    setting: $configuration.trackSettings[index],
                                    isPreviewSelected: previewSelection.selectedTracks(
                                        from: configuration.trackSettings
                                    ).contains(where: { $0.id == track.id }),
                                    draggedTrackID: $draggedTrackID,
                                    setDefault: { enabled in
                                        setDefault(trackID: track.id, enabled: enabled)
                                    },
                                    includedChanged: refreshPreview,
                                    preview: { preview(track) },
                                    moveBy: { moveTrack(track.id, by: $0) },
                                    moveTo: moveTrack,
                                    export: { exportTrack(track) },
                                    remove: track.isImported(relativeTo: primarySourceURL)
                                        ? { removeTrack(track.id) }
                                        : nil
                                )
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .sheet(isPresented: $isSelectingImports) {
            TrackImportSelectionView(
                kind: kind,
                candidates: $importCandidates,
                cancel: {
                    importCandidates = []
                    isSelectingImports = false
                },
                confirm: importSelectedCandidates
            )
        }
    }

    private func setDefault(trackID: String, enabled: Bool) {
        guard let selectedIndex = configuration.trackSettings.firstIndex(where: { $0.id == trackID }) else {
            return
        }
        if enabled {
            for index in configuration.trackSettings.indices
                where configuration.trackSettings[index].kind == kind {
                configuration.trackSettings[index].isDefault = index == selectedIndex
            }
            preview(configuration.trackSettings[selectedIndex])
        } else {
            configuration.trackSettings[selectedIndex].isDefault = false
            refreshPreview()
        }
    }

    private func preview(_ track: TrackExportSettings) {
        var selection = previewSelection
        selection.select(track)
        previewSelection = selection
        requestPreview(selection)
    }

    private func refreshPreview() {
        var selection = previewSelection
        selection.normalize(using: configuration.trackSettings)
        previewSelection = selection
        requestPreview(selection)
    }

    private func moveTrack(_ trackID: String, by offset: Int) {
        configuration.moveTrack(id: trackID, by: offset)
        refreshPreview()
    }

    private func moveTrack(_ trackID: String, to targetID: String) {
        configuration.moveTrack(id: trackID, to: targetID)
        refreshPreview()
    }

    private func removeTrack(_ trackID: String) {
        configuration.trackSettings.removeAll { $0.id == trackID }
        refreshPreview()
        reportNotice(.success("已从当前项目移除外部轨道。"))
    }

    private func chooseImportFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择包含\(kind.shortDisplayName)轨道的文件"
        panel.prompt = "读取轨道"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = allowedImportTypes
        guard panel.runModal() == .OK else { return }
        probeImportFiles(panel.urls)
    }

    private var allowedImportTypes: [UTType] {
        var types: [UTType]
        switch kind {
        case .video:
            types = [.movie, .audiovisualContent]
        case .audio:
            types = [.audio, .movie, .audiovisualContent]
        case .subtitle:
            types = [.text, .plainText, .movie, .audiovisualContent]
        default:
            types = [.item]
        }
        let extensions = [
            "mkv", "webm", "ts", "m2ts", "m4a", "aac", "flac", "ogg", "opus",
            "srt", "ass", "ssa", "vtt", "sup"
        ]
        for fileExtension in extensions {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private func probeImportFiles(_ urls: [URL]) {
        isImporting = true
        Task { @MainActor in
            var candidates: [TrackImportCandidate] = []
            var failures: [String] = []
            let existingIDs = Set(configuration.trackSettings.map(\.id))

            for url in urls {
                do {
                    let probe = try await environment.probeMedia(at: url)
                    let tracks = probe.streams
                        .filter { $0.kind == kind && !$0.isAttachedPicture }
                        .map {
                            TrackExportSettings(
                                sourceURL: url,
                                stream: $0,
                                sourceDuration: probe.duration
                            )
                        }
                        .filter { !existingIDs.contains($0.id) }
                    candidates += tracks.map { TrackImportCandidate(track: $0) }
                    if tracks.isEmpty {
                        failures.append("\(url.lastPathComponent)：没有新的\(kind.shortDisplayName)轨道")
                    }
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            isImporting = false
            if candidates.isEmpty {
                reportNotice(.error(failures.first ?? "没有发现可导入的轨道。"))
            } else if candidates.count == 1 {
                importCandidates = candidates
                importSelectedCandidates()
                if !failures.isEmpty {
                    reportNotice(.warning(failures.joined(separator: "；")))
                }
            } else {
                importCandidates = candidates
                isSelectingImports = true
                if !failures.isEmpty {
                    reportNotice(.warning(failures.joined(separator: "；")))
                }
            }
        }
    }

    private func importSelectedCandidates() {
        let selected = importCandidates.filter(\.isSelected).map(\.track)
        guard !selected.isEmpty else {
            reportNotice(.warning("请至少选择一条轨道。"))
            return
        }

        var hasDefault = configuration.trackSettings.contains {
            $0.kind == kind && $0.isIncluded && $0.isDefault
        }
        var added: [TrackExportSettings] = []
        for var track in selected {
            if track.isDefault, hasDefault {
                track.isDefault = false
            } else if track.isDefault {
                hasDefault = true
            }
            configuration.trackSettings.append(track)
            added.append(track)
        }
        importCandidates = []
        isSelectingImports = false

        if let previewTrack = added.last {
            preview(previewTrack)
        }
        reportNotice(.success("已导入 \(added.count) 条\(kind.shortDisplayName)轨道，并刷新播放预览。"))
    }

    private var emptySymbol: String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .subtitle: "captions.bubble"
        default: "rectangle.stack"
        }
    }
}

private struct TrackSettingsRow: View {
    let position: Int
    let totalCount: Int
    let primarySourceURL: URL
    @Binding var setting: TrackExportSettings
    let isPreviewSelected: Bool
    @Binding var draggedTrackID: String?
    let setDefault: (Bool) -> Void
    let includedChanged: () -> Void
    let preview: () -> Void
    let moveBy: (Int) -> Void
    let moveTo: (String, String) -> Void
    let export: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedTrackID = setting.id
                        return NSItemProvider(object: setting.id as NSString)
                    }

                Text("\(position + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(setting.isIncluded ? Color.accentColor : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(setting.title.isEmpty
                            ? "\(setting.kind.shortDisplayName)轨道 \(position + 1)"
                            : setting.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(setting.isImported(relativeTo: primarySourceURL) ? "外部" : "当前文件")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(streamSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(setting.resolvedSourceURL(primarySourceURL: primarySourceURL).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(sourceAvailable ? .secondary : Color.red)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: preview) {
                    Label(
                        isPreviewSelected ? "正在预览" : "预览此轨",
                        systemImage: isPreviewSelected ? "play.circle.fill" : "play.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: export) {
                    Label("单独导出", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button("上移", systemImage: "arrow.up", action: { moveBy(-1) })
                        .disabled(position == 0)
                    Button("下移", systemImage: "arrow.down", action: { moveBy(1) })
                        .disabled(position == totalCount - 1)
                    if let remove {
                        Divider()
                        Button(
                            "从当前项目移除",
                            systemImage: "trash",
                            role: .destructive,
                            action: remove
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)

                Toggle(
                    "成片",
                    isOn: Binding(
                        get: { setting.isIncluded },
                        set: {
                            setting.isIncluded = $0
                            includedChanged()
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()

            HStack(spacing: 14) {
                LabeledContent("标题") {
                    TextField("可选", text: $setting.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 150)
                }

                LabeledContent("语言") {
                    TextField("例如 zh / eng", text: $setting.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }

                Toggle(
                    "默认轨道",
                    isOn: Binding(
                        get: { setting.isDefault },
                        set: setDefault
                    )
                )
            }
            .disabled(!setting.isIncluded)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isPreviewSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        }
        .opacity(setting.isIncluded ? 1 : 0.68)
        .onDrop(of: [UTType.text.identifier], isTargeted: nil) { _ in
            guard let draggedTrackID, draggedTrackID != setting.id else { return false }
            moveTo(draggedTrackID, setting.id)
            self.draggedTrackID = nil
            return true
        }
    }

    private var streamSummary: String {
        var parts: [String] = []
        if let codec = setting.codecName { parts.append(codec.uppercased()) }
        if let width = setting.width, let height = setting.height {
            parts.append("\(width) × \(height)")
        }
        if let sampleRate = setting.sampleRate {
            parts.append("\(sampleRate / 1_000) kHz")
        }
        if let channels = setting.channels { parts.append("\(channels) 声道") }
        if !setting.language.isEmpty { parts.append(setting.language) }
        if let duration = setting.sourceDuration, duration > 0 {
            parts.append(formatTime(duration))
        }
        return parts.isEmpty ? "未提供轨道详情" : parts.joined(separator: " · ")
    }

    private var sourceAvailable: Bool {
        FileManager.default.fileExists(
            atPath: setting.resolvedSourceURL(primarySourceURL: primarySourceURL).path
        )
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private var symbolName: String {
        switch setting.kind {
        case .video: "film"
        case .audio: "waveform"
        case .subtitle: "captions.bubble"
        default: "rectangle.stack"
        }
    }
}

private struct TrackImportCandidate: Identifiable {
    var track: TrackExportSettings
    var isSelected = true

    var id: String { track.id }
}

private struct TrackImportSelectionView: View {
    let kind: MediaStreamKind
    @Binding var candidates: [TrackImportCandidate]
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择要导入的\(kind.shortDisplayName)轨道")
                        .font(.title3.bold())
                    Text("所选轨道会追加到当前列表，并可立即用于播放预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            List {
                ForEach($candidates) { $candidate in
                    Toggle(isOn: $candidate.isSelected) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.track.title.isEmpty
                                ? "\(kind.shortDisplayName)轨道 #\(candidate.track.streamIndex)"
                                : candidate.track.title)
                                .font(.headline)
                            Text(candidate.track.sourceURL?.lastPathComponent ?? "未知来源")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(candidateSummary(candidate.track))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 5)
                }
            }

            Divider()

            HStack {
                Button("取消", action: cancel)
                Spacer()
                Button("导入所选轨道", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!candidates.contains(where: \.isSelected))
            }
            .padding(18)
        }
        .frame(width: 620, height: 440)
    }

    private func candidateSummary(_ track: TrackExportSettings) -> String {
        var parts: [String] = []
        if let codecName = track.codecName { parts.append(codecName.uppercased()) }
        if let width = track.width, let height = track.height { parts.append("\(width) × \(height)") }
        if let channels = track.channels { parts.append("\(channels) 声道") }
        if !track.language.isEmpty { parts.append(track.language) }
        return parts.joined(separator: " · ")
    }
}

private struct MetadataSettingsPage: View {
    let mediaProbe: MediaProbe?
    @Binding var entries: [MetadataExportEntry]
    @Binding var preserveSourceMetadata: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("保留源文件元数据", isOn: $preserveSourceMetadata)
                Spacer()
                Button {
                    entries.append(MetadataExportEntry(key: "", value: ""))
                } label: {
                    Label("添加字段", systemImage: "plus")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MetadataOverviewView(mediaProbe: mediaProbe)

                    Divider()

                    HStack {
                        Label("可编辑字段", systemImage: "pencil")
                            .font(.headline)
                        Spacer()
                        Text("同名字段会覆盖源文件的值")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tag")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                            Text("当前没有可编辑的元数据")
                            Button("添加第一个字段") {
                                entries.append(MetadataExportEntry(key: "title", value: ""))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach($entries) { $entry in
                                HStack(spacing: 10) {
                                    TextField("字段，例如 title", text: $entry.key)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 190)
                                    TextField("值", text: $entry.value)
                                        .textFieldStyle(.roundedBorder)
                                    Button {
                                        entries.removeAll { $0.id == entry.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除此字段")
                                }
                                .padding(10)
                                .background(
                                    Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .padding(4)
    }
}

private struct MetadataOverviewView: View {
    let mediaProbe: MediaProbe?
    @State private var artworkImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("媒体信息", systemImage: "info.circle")
                .font(.headline)

            if let mediaProbe {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
                    spacing: 8
                ) {
                    infoTile("封装", value: mediaProbe.formatName?.uppercased() ?? "未知", symbol: "shippingbox")
                    infoTile("时长", value: formatTime(mediaProbe.duration ?? 0), symbol: "clock")
                    infoTile("封面", value: "\(mediaProbe.coverStreams.count) 个", symbol: "photo")
                    infoTile("章节", value: "\(mediaProbe.chapters.count) 个", symbol: "list.number")
                    infoTile(
                        "附件",
                        value: "\(mediaProbe.streams.filter { $0.kind == .attachment }.count) 个",
                        symbol: "paperclip"
                    )
                    infoTile("元数据字段", value: "\(mediaProbe.metadata.count) 个", symbol: "tag")
                }

                coverSection(mediaProbe.coverStreams)
                chapterSection(mediaProbe.chapters)
                attachmentSection(mediaProbe.streams.filter { $0.kind == .attachment })
            } else {
                ProgressView("正在读取封面、章节与媒体信息…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: mediaProbe?.sourceURL) {
            artworkImage = await loadArtwork()
        }
    }

    private func infoTile(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func coverSection(_ covers: [MediaStream]) -> some View {
        DisclosureGroup {
            if covers.isEmpty {
                Label("文件中没有检测到内嵌封面", systemImage: "photo.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 7) {
                    ForEach(covers) { cover in
                        HStack(spacing: 10) {
                            if let artworkImage {
                                Image(nsImage: artworkImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            } else {
                                Image(systemName: "photo.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                    .frame(width: 56, height: 56)
                                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cover.title?.isEmpty == false ? cover.title! : "内嵌封面 #\(cover.index)")
                                    .font(.subheadline.weight(.medium))
                                Text(coverDescription(cover))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 7)
            }
        } label: {
            Label("封面", systemImage: "photo.on.rectangle")
                .font(.subheadline.bold())
        }
    }

    @ViewBuilder
    private func chapterSection(_ chapters: [MediaChapter]) -> some View {
        DisclosureGroup {
            if chapters.isEmpty {
                Text("文件中没有检测到章节。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(chapter.title?.isEmpty == false ? chapter.title! : "章节 \(index + 1)")
                                .lineLimit(1)
                            Spacer()
                            Text("\(formatTime(chapter.startTime)) – \(formatTime(chapter.endTime))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Label("章节", systemImage: "list.number")
                .font(.subheadline.bold())
        }
    }

    @ViewBuilder
    private func attachmentSection(_ attachments: [MediaStream]) -> some View {
        if !attachments.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(attachments) { attachment in
                        Text(
                            "#\(attachment.index)  "
                                + (attachment.title ?? attachment.codecName?.uppercased() ?? "附件")
                        )
                        .font(.caption)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("附件", systemImage: "paperclip")
                    .font(.subheadline.bold())
            }
        }
    }

    private func coverDescription(_ cover: MediaStream) -> String {
        var values: [String] = []
        if let codec = cover.codecName { values.append(codec.uppercased()) }
        if let width = cover.width, let height = cover.height { values.append("\(width) × \(height)") }
        return values.isEmpty ? "图片流" : values.joined(separator: " · ")
    }

    private func loadArtwork() async -> NSImage? {
        guard let sourceURL = mediaProbe?.sourceURL else { return nil }
        let asset = AVURLAsset(url: sourceURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }

        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue),
               let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

private extension MediaStreamKind {
    var displayName: String {
        switch self {
        case .video: "视频轨道"
        case .audio: "音频轨道"
        case .subtitle: "字幕轨道"
        case .attachment: "附件轨道"
        case .data: "数据轨道"
        case .unknown: "未知轨道"
        }
    }
}
