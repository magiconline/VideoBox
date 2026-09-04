import AVFoundation
import AppKit
import SwiftUI

struct MediaTrackEditorView: View {
    let mediaProbe: MediaProbe?
    @Binding var configuration: ExportConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("轨道与元数据")
                        .font(.title2.bold())
                    Text("选择导出的轨道，并修改标题、语言和默认轨道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            TabView {
                TrackSettingsPage(
                    kind: .video,
                    streams: streams(of: .video),
                    settings: $configuration.trackSettings
                )
                .tabItem { Label("视频轨道", systemImage: "film") }

                TrackSettingsPage(
                    kind: .audio,
                    streams: streams(of: .audio),
                    settings: $configuration.trackSettings
                )
                .tabItem { Label("音频轨道", systemImage: "waveform") }

                TrackSettingsPage(
                    kind: .subtitle,
                    streams: streams(of: .subtitle),
                    settings: $configuration.trackSettings
                )
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
        .frame(minWidth: 720, minHeight: 500)
    }

    private func streams(of kind: MediaStreamKind) -> [MediaStream] {
        mediaProbe?.streams.filter { $0.kind == kind } ?? []
    }
}

private struct TrackSettingsPage: View {
    let kind: MediaStreamKind
    let streams: [MediaStream]
    @Binding var settings: [TrackExportSettings]

    private var matchingIndices: [Int] {
        settings.indices.filter { settings[$0].kind == kind }
    }

    var body: some View {
        Group {
            if matchingIndices.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("没有检测到\(kind.displayName)")
                        .font(.headline)
                    Text("ffprobe 未在当前文件中发现这一类轨道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(matchingIndices, id: \.self) { index in
                            TrackSettingsRow(
                                stream: streams.first(where: {
                                    $0.index == settings[index].streamIndex
                                }),
                                setting: $settings[index],
                                setDefault: { enabled in
                                    setDefault(at: index, enabled: enabled)
                                }
                            )
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func setDefault(at selectedIndex: Int, enabled: Bool) {
        guard settings.indices.contains(selectedIndex) else { return }
        if enabled {
            for index in settings.indices where settings[index].kind == kind {
                settings[index].isDefault = index == selectedIndex
            }
        } else {
            settings[selectedIndex].isDefault = false
        }
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
    let stream: MediaStream?
    @Binding var setting: TrackExportSettings
    let setDefault: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(setting.isIncluded ? Color.accentColor : .secondary)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("轨道 #\(setting.streamIndex)")
                        .font(.headline)
                    Text(streamSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("导出", isOn: $setting.isIncluded)
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .opacity(setting.isIncluded ? 1 : 0.62)
    }

    private var streamSummary: String {
        guard let stream else { return "等待媒体信息" }
        var parts: [String] = []
        if let codec = stream.codecName { parts.append(codec.uppercased()) }
        if let width = stream.width, let height = stream.height {
            parts.append("\(width) × \(height)")
        }
        if let sampleRate = stream.sampleRate {
            parts.append("\(sampleRate / 1_000) kHz")
        }
        if let channels = stream.channels { parts.append("\(channels) 声道") }
        if let language = stream.language, !language.isEmpty { parts.append(language) }
        return parts.isEmpty ? "未提供轨道详情" : parts.joined(separator: " · ")
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
