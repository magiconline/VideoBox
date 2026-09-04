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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar

            TimelineRulerView(duration: editing.outputDuration)
                .frame(height: 18)

            timelineStrip
                .frame(height: 82)

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
            thumbnails = await TimelineThumbnailGenerator.generate(
                sourceURL: sourceURL,
                duration: sourceDuration,
                count: 24
            )
        }
        .onAppear {
            synchronizeSelectionPreview()
        }
        .onChange(of: editing.selectedClipID) { _ in
            synchronizeSelectionPreview()
        }
        .onChange(of: editing.clips) { _ in
            playheadTime = min(playheadTime, editing.outputDuration)
            synchronizeSelectionPreview()
        }
        .onChange(of: playerController.currentTime) { sourceTime in
            synchronizePlayhead(with: sourceTime)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("剪辑时间线", systemImage: "timeline.selection")
                .font(.headline)

            Spacer(minLength: 8)

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
            let contentWidth = max(proxy.size.width, CGFloat(max(1, editing.clips.count)) * 92)

            ScrollView(.horizontal, showsIndicators: editing.clips.count > 8) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: segmentSpacing) {
                        ForEach(Array(editing.clips.enumerated()), id: \.element.id) { index, clip in
                            let width = segmentWidth(
                                for: clip,
                                contentWidth: contentWidth
                            )
                            TimelineClipCell(
                                clip: clip,
                                number: index + 1,
                                width: width,
                                thumbnails: thumbnails,
                                sourceDuration: sourceDuration ?? 0,
                                isSelected: editing.selectedClipID == clip.id,
                                dragProvider: {
                                    draggedClipID = clip.id
                                    return NSItemProvider(object: clip.id.uuidString as NSString)
                                }
                            )
                            .contentShape(Rectangle())
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
                    .frame(width: contentWidth, height: 76, alignment: .leading)

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
                        .offset(x: playheadX(contentWidth: contentWidth))
                        .allowsHitTesting(false)
                }
                .frame(width: contentWidth, height: 76)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            isScrubbing = true
                            scrub(toX: value.location.x, contentWidth: contentWidth)
                        }
                        .onEnded { value in
                            scrub(toX: value.location.x, contentWidth: contentWidth)
                            isScrubbing = false
                        }
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
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
                        title: "音量",
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

    private var segmentSpacing: CGFloat { 3 }

    private func segmentWidth(for clip: EditSegment, contentWidth: CGFloat) -> CGFloat {
        let totalSpacing = segmentSpacing * CGFloat(max(0, editing.clips.count - 1))
        let usableWidth = max(1, contentWidth - totalSpacing)
        guard editing.outputDuration > 0 else { return usableWidth }
        return max(24, usableWidth * CGFloat(clip.outputDuration / editing.outputDuration))
    }

    private func playheadX(contentWidth: CGFloat) -> CGFloat {
        guard let location = editing.location(atOutputTime: playheadTime) else { return 0 }
        var x = 0.0
        for index in editing.clips.indices {
            let clip = editing.clips[index]
            let width = segmentWidth(for: clip, contentWidth: contentWidth)
            if index == location.clipIndex {
                let fraction = clip.outputDuration > 0
                    ? location.localOutputTime / clip.outputDuration
                    : 0
                return min(contentWidth - 1, x + width * CGFloat(fraction))
            }
            x += width + segmentSpacing
        }
        return min(contentWidth - 1, x)
    }

    private func outputTime(forX requestedX: CGFloat, contentWidth: CGFloat) -> TimeInterval {
        let x = min(max(0, requestedX), contentWidth)
        var cursorX = 0.0
        var cursorTime = 0.0

        for clip in editing.clips {
            let width = segmentWidth(for: clip, contentWidth: contentWidth)
            if x <= cursorX + width {
                let fraction = width > 0 ? (x - cursorX) / width : 0
                return min(
                    editing.outputDuration,
                    cursorTime + clip.outputDuration * Double(max(0, fraction))
                )
            }
            cursorX += width + segmentSpacing
            cursorTime += clip.outputDuration
        }
        return editing.outputDuration
    }

    private var canSplit: Bool {
        guard let location = editing.location(atOutputTime: playheadTime),
              editing.clips.indices.contains(location.clipIndex) else { return false }
        let clip = editing.clips[location.clipIndex]
        return location.localOutputTime > 0.04
            && clip.outputDuration - location.localOutputTime > 0.04
    }

    private func scrub(toX x: CGFloat, contentWidth: CGFloat) {
        scrub(to: outputTime(forX: x, contentWidth: contentWidth))
    }

    private func scrub(to outputTime: TimeInterval) {
        guard let location = editing.location(atOutputTime: outputTime) else { return }
        playerController.pause()
        playheadTime = location.outputTime
        editing.selectedClipID = location.clipID
        synchronizeSelectionPreview()
        playerController.seek(to: location.sourceTime)
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
    }

    private func clipTreatmentChanged() {
        requiresTranscode()
        synchronizeSelectionPreview()
    }

    private func synchronizeSelectionPreview() {
        guard let clip = editing.selectedClip else {
            playerController.applyPreviewSettings(rate: 1, volume: 1)
            return
        }
        playerController.applyPreviewSettings(
            rate: clip.playbackRate,
            volume: clip.volume
        )
    }

    private func synchronizePlayhead(with sourceTime: TimeInterval) {
        guard !isScrubbing,
              let selectedIndex = editing.selectedClipIndex,
              editing.clips.indices.contains(selectedIndex) else { return }
        let clip = editing.clips[selectedIndex]
        let tolerance = 1.0 / 30.0

        if sourceTime >= clip.sourceRange.start - tolerance,
           sourceTime <= clip.sourceRange.end + tolerance {
            let localSourceTime = min(
                clip.sourceRange.duration,
                max(0, sourceTime - clip.sourceRange.start)
            )
            playheadTime = (editing.outputStart(of: clip.id) ?? 0)
                + localSourceTime / max(0.1, clip.playbackRate)

            if playerController.isPlaying,
               sourceTime >= clip.sourceRange.end - tolerance {
                advancePlayback(after: selectedIndex)
            }
        }
    }

    private func advancePlayback(after index: Int) {
        let nextIndex = index + 1
        guard editing.clips.indices.contains(nextIndex) else {
            playerController.pause()
            return
        }
        let next = editing.clips[nextIndex]
        editing.selectedClipID = next.id
        playheadTime = editing.outputStart(of: next.id) ?? playheadTime
        synchronizeSelectionPreview()
        playerController.seek(to: next.sourceRange.start)
        playerController.play()
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
                Text("片段 \(number) · \(clip.outputDuration.formatted(.number.precision(.fractionLength(1)))) 秒")
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
    let duration: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            ForEach(0...5, id: \.self) { index in
                let fraction = Double(index) / 5
                let x = proxy.size.width * fraction
                VStack(spacing: 1) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.42))
                        .frame(width: 1, height: 4)
                    Text(formatTime(duration * fraction))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .position(x: min(max(20, x), proxy.size.width - 20), y: 8)
            }
        }
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
