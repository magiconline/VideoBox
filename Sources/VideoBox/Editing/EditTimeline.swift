import Foundation

struct EditSettings: Codable, Equatable, Sendable {
    var clips: [EditSegment] = []
    var selectedClipID: UUID?
    var sourceDuration = 0.0
    var canvasWidth: Int?
    var canvasHeight: Int?
    var layers: [OverlayClip]?
    var overlayClips: [OverlayClip] { get { layers ?? [] } set { layers = newValue } }
    var referencedURLs: [URL] { clips.compactMap(\.sourceURL) + overlayClips.map(\.sourceURL) }
    var requiresRenderedPreview: Bool {
        !overlayClips.isEmpty || clips.contains { $0.sourceURL != nil || $0.transform.crop != nil
            || $0.effects != nil || !($0.keyframes ?? []).isEmpty || ($0.transition?.duration ?? 0) > 0 }
    }
    var clipStartTimes: [Double] {
        var time = 0.0
        return clips.enumerated().map { index, clip in
            if index > 0 { time -= transitionDuration(at: index) }
            let start = time; time += clip.outputDuration; return start
        }
    }
    func transitionDuration(at index: Int) -> Double {
        guard index > 0, clips.indices.contains(index) else { return 0 }
        return min(max(0, clips[index].transition?.duration ?? 0), min(clips[index - 1].outputDuration, clips[index].outputDuration) / 2)
    }

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return nil }
        return clips.firstIndex { $0.id == selectedClipID }
    }

    var selectedClip: EditSegment? {
        guard let selectedClipIndex else { return nil }
        return clips[selectedClipIndex]
    }

    var outputDuration: TimeInterval {
        max(0, clips.reduce(0) { $0 + $1.outputDuration } - clips.indices.reduce(0) { $0 + transitionDuration(at: $1) })
    }

    var trimmedDuration: TimeInterval? {
        clips.isEmpty ? nil : outputDuration
    }

    var requiresFilterComposition: Bool {
        !overlayClips.isEmpty || clips.count > 1 || clips.contains { !$0.hasDefaultTreatment }
    }

    mutating func initialize(
        duration: TimeInterval,
        canvasWidth: Int?,
        canvasHeight: Int?
    ) {
        let safeDuration = max(0, duration)
        sourceDuration = safeDuration
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        let clip = EditSegment(
            sourceRange: TimelineRange(start: 0, duration: safeDuration)
        )
        clips = safeDuration > 0 ? [clip] : []
        layers = nil
        selectedClipID = clips.first?.id
    }

    func location(atOutputTime requestedTime: TimeInterval) -> TimelineLocation? {
        guard !clips.isEmpty else { return nil }
        let time = min(max(0, requestedTime), outputDuration)
        let starts = clipStartTimes

        for (index, clip) in clips.enumerated() {
            let cursor = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : outputDuration
            // The composition's CMTime may round a cut by a few microseconds.
            // Keep a playhead at that cut on the right-hand clip after splitting.
            if time < end - 0.000_01 || index == clips.indices.last {
                let localOutputTime = min(max(0, time - cursor), clip.outputDuration)
                return TimelineLocation(
                    clipIndex: index,
                    clipID: clip.id,
                    outputTime: time,
                    localOutputTime: localOutputTime,
                    sourceTime: clip.sourceRange.start + localOutputTime * clip.playbackRate
                )
            }
        }
        return nil
    }

    func outputStart(of clipID: UUID) -> TimeInterval? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return clipStartTimes[index]
    }

    func simpleTrimRange() -> TimelineRange? {
        guard overlayClips.isEmpty, clips.count == 1, let clip = clips.first, clip.hasDefaultTreatment else { return nil }
        let isFullSource = abs(clip.sourceRange.start) < 0.000_1
            && abs(clip.sourceRange.duration - sourceDuration) < 0.000_1
        return isFullSource ? nil : clip.sourceRange
    }

    @discardableResult
    mutating func split(atOutputTime outputTime: TimeInterval) -> UUID? {
        guard let location = location(atOutputTime: outputTime),
              clips.indices.contains(location.clipIndex) else { return nil }

        let original = clips[location.clipIndex]
        let sourceOffset = location.localOutputTime * original.playbackRate
        let minimumSourceDuration = max(0.04, original.playbackRate / 30)
        guard sourceOffset > minimumSourceDuration,
              original.sourceRange.duration - sourceOffset > minimumSourceDuration else {
            return nil
        }

        clips[location.clipIndex].sourceRange.duration = sourceOffset
        var right = original
        right.id = UUID(); right.transition = nil
        right.sourceRange = TimelineRange(start: original.sourceRange.start + sourceOffset, duration: original.sourceRange.duration - sourceOffset)
        let boundary = location.localOutputTime
        if let frames = original.keyframes, !frames.isEmpty {
            let pose = VisualKeyframe.interpolate(frames, at: boundary)
            clips[location.clipIndex].keyframes = frames.filter { $0.time < boundary } + [VisualKeyframe(time: boundary, pose: pose)]
            right.keyframes = [VisualKeyframe(time: 0, pose: pose)] + frames.filter { $0.time > boundary }.map { VisualKeyframe(time: $0.time - boundary, pose: $0.pose) }
        }
        clips.insert(right, at: location.clipIndex + 1)
        selectedClipID = right.id
        return right.id
    }

    mutating func deleteSelectedClip() {
        guard clips.count > 1, let index = selectedClipIndex else { return }
        clips.remove(at: index)
        selectedClipID = clips[min(index, clips.count - 1)].id
    }

    @discardableResult
    mutating func duplicateSelectedClip() -> UUID? {
        guard let index = selectedClipIndex else { return nil }
        var duplicate = clips[index]
        duplicate.id = UUID()
        clips.insert(duplicate, at: index + 1)
        selectedClipID = duplicate.id
        return duplicate.id
    }

    mutating func moveSelectedClip(by offset: Int) {
        guard let index = selectedClipIndex else { return }
        let destination = min(max(0, index + offset), clips.count - 1)
        guard destination != index else { return }
        let clip = clips.remove(at: index)
        clips.insert(clip, at: destination)
    }

    mutating func moveClip(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let sourceIndex = clips.firstIndex(where: { $0.id == draggedID }),
              let originalTargetIndex = clips.firstIndex(where: { $0.id == targetID }) else { return }
        let clip = clips.remove(at: sourceIndex)
        let destination = min(originalTargetIndex, clips.count)
        clips.insert(clip, at: destination)
        selectedClipID = draggedID
    }

    mutating func resetSelectedClipTreatment() {
        guard let index = selectedClipIndex else { return }
        clips[index].playbackRate = 1
        clips[index].transform = .identity
        clips[index].volume = 1
        clips[index].scale = 1
        clips[index].effects = nil; clips[index].keyframes = nil; clips[index].transition = nil
    }

    func timeline(for sourceURL: URL) -> EditTimeline {
        EditTimeline(sourceURL: sourceURL, segments: clips)
    }
}

struct TimelineLocation: Equatable, Sendable {
    let clipIndex: Int
    let clipID: UUID
    let outputTime: TimeInterval
    let localOutputTime: TimeInterval
    let sourceTime: TimeInterval
}

struct EditTimeline: Codable, Equatable, Sendable {
    var sourceURL: URL
    var segments: [EditSegment]

    init(sourceURL: URL, segments: [EditSegment] = []) {
        self.sourceURL = sourceURL
        self.segments = segments
    }
}

struct EditSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sourceRange: TimelineRange
    var playbackRate: Double
    var transform: VideoTransform
    var volume: Double
    var scale: Double
    var sourceURL: URL?
    var media: ClipMedia?
    var effects: ClipEffects?
    var keyframes: [VisualKeyframe]?
    var transition: ClipTransition?

    init(
        id: UUID = UUID(),
        sourceRange: TimelineRange,
        playbackRate: Double = 1,
        transform: VideoTransform = .identity,
        volume: Double = 1,
        scale: Double = 1
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.playbackRate = playbackRate
        self.transform = transform
        self.volume = volume
        self.scale = scale
    }

    var outputDuration: TimeInterval {
        sourceRange.duration / max(0.1, playbackRate)
    }

    var hasDefaultTreatment: Bool {
        abs(playbackRate - 1) < 0.000_1
            && transform == .identity
            && abs(volume - 1) < 0.000_1
            && abs(scale - 1) < 0.000_1
            && sourceURL == nil && effects == nil && (keyframes ?? []).isEmpty && transition == nil
    }
}

struct TimelineRange: Codable, Equatable, Sendable {
    var start: TimeInterval
    var duration: TimeInterval

    var end: TimeInterval { start + duration }
}

struct VideoTransform: Codable, Equatable, Sendable {
    var quarterTurnsClockwise: Int
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool
    var crop: NormalizedCrop?

    static let identity = VideoTransform(
        quarterTurnsClockwise: 0,
        isFlippedHorizontally: false,
        isFlippedVertically: false,
        crop: nil
    )
}

struct NormalizedCrop: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
