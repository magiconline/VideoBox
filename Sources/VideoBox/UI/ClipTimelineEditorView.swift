import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct ClipTimelineEditorView: View {
    let sourceURL: URL
    let sourceDuration: TimeInterval?
    @ObservedObject var playerController: PlayerController
    @Binding var editing: EditSettings
    let requiresTranscode: () -> Void

    @State private var thumbnails: [CGImage] = []
    @State private var playheadTime = 0.0
    @State private var isScrubbing = false
    @State private var draggedClipID: UUID?
    @State private var seekText = ""
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var trimError: String?
    @State private var isShowingAdvanced = false
    @State private var edgeDrag: (UUID, Bool, TimelineRange)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar

            timelineStrip
                .frame(height: 108)

            selectedClipControls
        }
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .task(id: thumbnailGenerationID) {
            guard let sourceDuration, sourceDuration > 0 else {
                thumbnails = []
                return
            }
            let generated = await TimelineThumbnailGenerator.generate(
                sourceURL: sourceURL,
                duration: sourceDuration,
                count: 24
            )
            guard !Task.isCancelled else { return }
            thumbnails = generated
        }
        .background(PlayerInputFocusRegion(playerController: playerController))
        .sheet(isPresented: $isShowingAdvanced) {
            ClipAdvancedEditor(editing: $editing, localTime: max(0, playheadTime - (editing.selectedClipID.flatMap { editing.outputStart(of: $0) } ?? 0)), changed: clipTreatmentChanged)
        }
        .onAppear { playheadTime = playerController.outputTime; syncTrimFields(); playerController.setEditPoint = setEditPoint }
        .onDisappear { playerController.setEditPoint = nil; if isScrubbing { playerController.endScrubbing() } }
        .onChange(of: editing.selectedClipID) { _ in syncTrimFields() }
        .onChange(of: editing.clips) { _ in
            playheadTime = min(playheadTime, editing.outputDuration)
            syncTrimFields()
        }
        .onChange(of: playerController.outputTime) { outputTime in
            guard !isScrubbing else { return }
            playheadTime = outputTime
            if let clipID = playerController.activeClip?.id { editing.selectedClipID = clipID }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("剪辑时间线", systemImage: "timeline.selection")
                .font(.headline)

            Spacer(minLength: 8)
            TextField("00:00:00.000", text: $seekText)
                .font(.caption.monospacedDigit()).frame(width: 108)
                .onSubmit { if let time = Timecode.parse(seekText), time <= editing.outputDuration { scrub(to: time); trimError = nil } else { trimError = "请输入有效的剪后时间（秒或 时:分:秒.毫秒）" } }
                .help("输入剪后时间码并按回车定位")
            Button("定位") { if let time = Timecode.parse(seekText), time <= editing.outputDuration { scrub(to: time) } else { trimError = "时间码无效或超过成片时长" } }.controlSize(.small)

            TimelineToolButton(
                systemName: "scissors",
                title: "在播放头位置分割片段",
                isDisabled: !canSplit
            ) {
                splitAtPlayhead()
            }

            TimelineToolButton(
                systemName: "doc.on.doc",
                title: "复制选中的片段",
                isDisabled: editing.selectedClipID == nil
            ) {
                duplicateSelectedClip()
            }

            TimelineToolButton(
                systemName: "trash",
                title: "删除选中的片段",
                isDisabled: editing.clips.count <= 1
            ) {
                deleteSelectedClip()
            }

            TimelineToolButton(
                systemName: "arrow.left",
                title: "将片段向左移动",
                isDisabled: (editing.selectedClipIndex ?? 0) <= 0
            ) {
                moveSelectedClip(by: -1)
            }

            TimelineToolButton(
                systemName: "arrow.right",
                title: "将片段向右移动",
                isDisabled: (editing.selectedClipIndex ?? editing.clips.count) >= editing.clips.count - 1
            ) {
                moveSelectedClip(by: 1)
            }
        }
    }

    private var timelineStrip: some View {
        GeometryReader { proxy in
            let layout = TimelineLayout(
                durations: editing.clips.indices.map { editing.clips[$0].outputDuration - editing.transitionDuration(at: $0 + 1) },
                viewportWidth: proxy.size.width
            )

            ScrollView(.horizontal, showsIndicators: layout.contentWidth > proxy.size.width) {
                VStack(spacing: 8) {
                    TimelineRulerView(layout: layout)
                        .frame(width: layout.contentWidth, height: 18)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if !isScrubbing { playerController.beginScrubbing() }; isScrubbing = true
                            scrub(to: layout.time(atX: value.location.x))
                        }.onEnded { value in
                            scrub(to: layout.time(atX: value.location.x)); isScrubbing = false; playerController.endScrubbing()
                        })

                    ZStack(alignment: .topLeading) {
                        HStack(spacing: layout.spacing) {
                            ForEach(Array(editing.clips.enumerated()), id: \.element.id) { index, clip in
                                TimelineClipCell(
                                    clip: clip,
                                    number: index + 1,
                                    width: layout.segments[index].width,
                                    thumbnails: clip.sourceURL == nil ? thumbnails : [],
                                    sourceDuration: sourceDuration ?? 0,
                                    isSelected: editing.selectedClipID == clip.id,
                                    dragProvider: {
                                        draggedClipID = clip.id
                                        return NSItemProvider(object: clip.id.uuidString as NSString)
                                    }
                                )
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    guard edgeDrag == nil else { return }
                                    if !isScrubbing { playerController.beginScrubbing() }; isScrubbing = true
                                    scrub(to: editing.clipStartTimes[index] + max(0, min(1, value.location.x / max(1, layout.segments[index].width))) * layout.segments[index].duration)
                                }.onEnded { _ in if isScrubbing { isScrubbing = false; playerController.endScrubbing() } })
                                .overlay(alignment: .leading) { trimHandle(clip: clip, start: true, pixelsPerSecond: layout.segments[index].width / max(0.01, clip.outputDuration)) }
                                .overlay(alignment: .trailing) { trimHandle(clip: clip, start: false, pixelsPerSecond: layout.segments[index].width / max(0.01, clip.outputDuration)) }
                                .contextMenu {
                                    Button("选择片段") { editing.selectedClipID = clip.id }
                                    Button("片段设置…") { editing.selectedClipID = clip.id; isShowingAdvanced = true }
                                    Button("复制") { editing.selectedClipID = clip.id; duplicateSelectedClip() }
                                    Button("删除") { editing.selectedClipID = clip.id; deleteSelectedClip() }.disabled(editing.clips.count <= 1)
                                }
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: ClipDropDelegate(
                                        targetClipID: clip.id,
                                        editing: $editing,
                                        draggedClipID: $draggedClipID,
                                        didMove: timelineWasEdited
                                    )
                                )
                            }
                        }
                        .frame(width: layout.contentWidth, height: 76, alignment: .leading)

                        Rectangle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 1, height: 76)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .overlay(alignment: .top) {
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.white)
                                    .offset(y: -2)
                            }
                            .offset(x: min(layout.contentWidth - 1, layout.x(atTime: playheadTime)))
                            .allowsHitTesting(false)
                    }
                    .frame(width: layout.contentWidth, height: 76)
                    .contentShape(Rectangle())
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                }
                .frame(width: layout.contentWidth)
            }
        }
    }

    @ViewBuilder
    private var selectedClipControls: some View {
        if let index = editing.selectedClipIndex, editing.clips.indices.contains(index) {
            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("片段 \(index + 1)")
                        .font(.subheadline.bold())
                    Button("入点 I") { setEditPoint(true) }.help("将当前播放头设置为片段入点")
                    TextField("入点", text: $inputText).frame(width: 104).font(.caption.monospacedDigit())
                    Button("出点 O") { setEditPoint(false) }.help("将当前播放头设置为片段出点")
                    TextField("出点", text: $outputText).frame(width: 104).font(.caption.monospacedDigit())
                    Button("修剪") { applyTrim() }
                    Button("裁剪 / 调色 / 动画 / 转场…") { isShowingAdvanced = true }

                    Menu {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button("\(rate.formatted())×") {
                                editing.clips[index].playbackRate = rate
                                clipTreatmentChanged()
                            }
                        }
                    } label: {
                        Label("\(editing.clips[index].playbackRate.formatted())×", systemImage: "speedometer")
                    }
                    .help("设置当前片段的播放速度")

                    TimelineToolButton(systemName: "rotate.left", title: "当前片段逆时针旋转 90°") {
                        editing.clips[index].transform.quarterTurnsClockwise =
                            (editing.clips[index].transform.quarterTurnsClockwise + 3) % 4
                        clipTreatmentChanged()
                    }

                    TimelineToolButton(systemName: "rotate.right", title: "当前片段顺时针旋转 90°") {
                        editing.clips[index].transform.quarterTurnsClockwise =
                            (editing.clips[index].transform.quarterTurnsClockwise + 1) % 4
                        clipTreatmentChanged()
                    }

                    TimelineToolButton(
                        systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        title: "当前片段水平镜像",
                        isSelected: editing.clips[index].transform.isFlippedHorizontally
                    ) {
                        editing.clips[index].transform.isFlippedHorizontally.toggle()
                        clipTreatmentChanged()
                    }

                    TimelineToolButton(
                        systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                        title: "当前片段垂直镜像",
                        isSelected: editing.clips[index].transform.isFlippedVertically
                    ) {
                        editing.clips[index].transform.isFlippedVertically.toggle()
                        clipTreatmentChanged()
                    }

                    compactSlider(
                        title: "缩放当前片段画面（会应用到导出）",
                        systemName: "magnifyingglass",
                        value: Binding(
                            get: { editing.clips[index].scale * 100 },
                            set: {
                                editing.clips[index].scale = $0 / 100
                                clipTreatmentChanged()
                            }
                        ),
                        range: 50...200,
                        text: "\(Int((editing.clips[index].scale * 100).rounded()))%"
                    )

                    compactSlider(
                        title: "片段音量（会应用到导出；播放器监听音量不影响导出）",
                        systemName: "speaker.wave.2",
                        value: Binding(
                            get: { editing.clips[index].volume * 100 },
                            set: {
                                editing.clips[index].volume = $0 / 100
                                clipTreatmentChanged()
                            }
                        ),
                        range: 0...200,
                        text: "\(Int((editing.clips[index].volume * 100).rounded()))%"
                    )

                    Button("重置") {
                        editing.resetSelectedClipTreatment()
                        clipTreatmentChanged()
                    }
                    .controlSize(.small)
                    .disabled(editing.clips[index].hasDefaultTreatment)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 1)
            }
            if let trimError { Text(trimError).font(.caption).foregroundStyle(.orange) }
        } else {
            Text("拖动时间线开始预览，或选择一个片段进行编辑。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func compactSlider(
        title: String,
        systemName: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        text: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
                .help(title)
            Slider(value: value, in: range, step: 1)
                .frame(width: 48)
            Text(text)
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var thumbnailGenerationID: String {
        "\(sourceURL.path)|\(sourceDuration ?? -1)"
    }

    private func syncTrimFields() {
        guard let clip = editing.selectedClip else { return }
        inputText = Timecode.format(clip.sourceRange.start); outputText = Timecode.format(clip.sourceRange.end)
    }
    private func applyTrim() {
        guard let start = Timecode.parse(inputText), let end = Timecode.parse(outputText), editing.trimSelected(start: start, end: end) else {
            trimError = "入点必须早于出点，且都位于该素材范围内"; return
        }
        trimError = nil; timelineWasEdited(); syncTrimFields()
        if let id = editing.selectedClipID { scrub(to: editing.outputStart(of: id) ?? 0) }
    }
    private func setEditPoint(_ start: Bool) {
        guard let location = editing.location(atOutputTime: playerController.outputTime) else { return }
        editing.selectedClipID = location.clipID
        let clip = editing.clips[location.clipIndex]
        guard editing.trimSelected(start: start ? location.sourceTime : clip.sourceRange.start, end: start ? clip.sourceRange.end : location.sourceTime) else { trimError = "此位置无法形成有效片段"; return }
        trimError = nil; timelineWasEdited(); syncTrimFields()
        let beginning = editing.outputStart(of: location.clipID) ?? 0
        scrub(to: start ? beginning : beginning + editing.clips[location.clipIndex].outputDuration)
    }
    private func trimHandle(clip: EditSegment, start: Bool, pixelsPerSecond: Double) -> some View {
        Capsule().fill(editing.selectedClipID == clip.id ? Color.accentColor : Color.white.opacity(0.5))
            .frame(width: 7, height: 58).padding(.horizontal, 2)
            .help(start ? "拖动修剪入点" : "拖动修剪出点")
            .gesture(DragGesture(minimumDistance: 2).onChanged { _ in
                if edgeDrag == nil { edgeDrag = (clip.id, start, clip.sourceRange); editing.selectedClipID = clip.id; playerController.pause() }
            }.onEnded { value in
                guard let edgeDrag else { return }; defer { self.edgeDrag = nil }
                editing.selectedClipID = edgeDrag.0
                let delta = Double(value.translation.width) / max(0.01, pixelsPerSecond) * clip.playbackRate
                let range = edgeDrag.2, limit = clip.media?.duration ?? editing.sourceDuration
                let newStart = start ? min(range.end - 0.04, max(0, range.start + delta)) : range.start
                let newEnd = start ? range.end : min(limit, max(range.start + 0.04, range.end + delta))
                if editing.trimSelected(start: newStart, end: newEnd) { timelineWasEdited(); syncTrimFields() }
            })
    }

    private var canSplit: Bool {
        guard let location = editing.location(atOutputTime: playheadTime),
              editing.clips.indices.contains(location.clipIndex) else { return false }
        let clip = editing.clips[location.clipIndex]
        return location.localOutputTime > 0.04
            && clip.outputDuration - location.localOutputTime > 0.04
    }

    private func scrub(to outputTime: TimeInterval) {
        guard let location = editing.location(atOutputTime: outputTime) else { return }
        playheadTime = location.outputTime
        editing.selectedClipID = location.clipID
        playerController.seekOutput(to: location.outputTime)
    }

    private func splitAtPlayhead() {
        playerController.pause()
        if editing.split(atOutputTime: playheadTime) != nil {
            timelineWasEdited()
            scrub(to: playheadTime)
        }
    }

    private func duplicateSelectedClip() {
        guard let id = editing.duplicateSelectedClip() else { return }
        timelineWasEdited()
        scrub(to: editing.outputStart(of: id) ?? playheadTime)
    }

    private func deleteSelectedClip() {
        editing.deleteSelectedClip()
        timelineWasEdited()
        scrub(to: min(playheadTime, editing.outputDuration))
    }

    private func moveSelectedClip(by offset: Int) {
        editing.moveSelectedClip(by: offset)
        timelineWasEdited()
        if let id = editing.selectedClipID, let start = editing.outputStart(of: id) {
            scrub(to: start)
        }
    }

    private func timelineWasEdited() {
        requiresTranscode()
        playerController.updateTimeline(editing: editing)
    }

    private func clipTreatmentChanged() {
        requiresTranscode()
        playerController.updateTimeline(editing: editing)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.00" }
        let hundredths = Int((seconds * 100).rounded())
        let hours = hundredths / 360_000
        let minutes = (hundredths / 6_000) % 60
        let remainder = (hundredths / 100) % 60
        let fraction = hundredths % 100
        return hours > 0
            ? String(format: "%02d:%02d:%02d.%02d", hours, minutes, remainder, fraction)
            : String(format: "%02d:%02d.%02d", minutes, remainder, fraction)
    }
}

private struct TimelineClipCell: View {
    let clip: EditSegment
    let number: Int
    let width: CGFloat
    let thumbnails: [CGImage]
    let sourceDuration: TimeInterval
    let isSelected: Bool
    let dragProvider: () -> NSItemProvider

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                if thumbnailIndices.isEmpty {
                    Rectangle().fill(Color.accentColor.opacity(0.15))
                } else {
                    ForEach(Array(thumbnailIndices.enumerated()), id: \.offset) { _, index in
                        Image(decorative: thumbnails[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(thumbnailIndices.count), height: 76)
                            .clipped()
                    }
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .contentShape(Rectangle())
                    .onDrag(dragProvider)
                    .help("拖动以移动片段")
                Text("\(clip.sourceURL?.lastPathComponent ?? "片段 \(number)") · \(clip.outputDuration.formatted(.number.precision(.fractionLength(1)))) 秒")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(6)
        }
        .frame(width: width, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isSelected ? 3 : 1)
        }
    }

    private var thumbnailIndices: [Int] {
        guard !thumbnails.isEmpty, sourceDuration > 0 else { return [] }
        let count = max(1, min(5, Int(width / 72) + 1))
        return (0..<count).map { index in
            let fraction = (Double(index) + 0.5) / Double(count)
            let sourceTime = clip.sourceRange.start + clip.sourceRange.duration * fraction
            return min(
                thumbnails.count - 1,
                max(0, Int((sourceTime / sourceDuration * Double(thumbnails.count - 1)).rounded()))
            )
        }
    }
}

private struct TimelineRulerView: View {
    let layout: TimelineLayout

    var body: some View {
        let tickCount = max(5, Int(layout.contentWidth / 140))
        ZStack(alignment: .topLeading) {
            ForEach(0...tickCount, id: \.self) { index in
                let x = layout.contentWidth * Double(index) / Double(tickCount)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.42))
                        .frame(width: 1, height: 4)
                        .offset(x: min(layout.contentWidth - 1, x))
                    Text(formatTime(layout.time(atX: x)))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: index == 0 ? .leading : index == tickCount ? .trailing : .center)
                        .offset(x: min(max(0, x - 28), max(0, layout.contentWidth - 56)), y: 6)
                }
            }
        }
        .frame(width: layout.contentWidth, height: 18, alignment: .topLeading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct TimelineToolButton: View {
    let systemName: String
    let title: String
    var isSelected = false
    var isDisabled = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 16, height: 16)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isSelected ? Color.accentColor : Color.secondary)
        .disabled(isDisabled)
        .overlay(alignment: .top) {
            if isHovering, !isDisabled {
                Text(title)
                    .font(.caption)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    .offset(y: -35)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovering ? 20 : 0)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

private struct ClipDropDelegate: DropDelegate {
    let targetClipID: UUID
    @Binding var editing: EditSettings
    @Binding var draggedClipID: UUID?
    let didMove: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedClipID, draggedClipID != targetClipID else { return }
        editing.moveClip(draggedClipID, to: targetClipID)
        didMove()
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedClipID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
