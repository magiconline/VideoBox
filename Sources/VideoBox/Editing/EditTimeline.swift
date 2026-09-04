import Foundation

struct EditSettings: Codable, Equatable, Sendable {
    var clips: [EditSegment] = []
    var selectedClipID: UUID?
    var sourceDuration = 0.0
    var canvasWidth: Int?
    var canvasHeight: Int?

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return nil }
        return clips.firstIndex { $0.id == selectedClipID }
    }

    var selectedClip: EditSegment? {
        guard let selectedClipIndex else { return nil }
        return clips[selectedClipIndex]
    }

    var outputDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.outputDuration }
    }

    var trimmedDuration: TimeInterval? {
        clips.isEmpty ? nil : outputDuration
    }

    var requiresFilterComposition: Bool {
        clips.count > 1 || clips.contains { !$0.hasDefaultTreatment }
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
        selectedClipID = clips.first?.id
    }

    func location(atOutputTime requestedTime: TimeInterval) -> TimelineLocation? {
        guard !clips.isEmpty else { return nil }
        let time = min(max(0, requestedTime), outputDuration)
        var cursor = 0.0

        for (index, clip) in clips.enumerated() {
            let end = cursor + clip.outputDuration
            if time < end || index == clips.indices.last {
                let localOutputTime = min(max(0, time - cursor), clip.outputDuration)
                return TimelineLocation(
                    clipIndex: index,
                    clipID: clip.id,
                    outputTime: time,
                    localOutputTime: localOutputTime,
                    sourceTime: clip.sourceRange.start + localOutputTime * clip.playbackRate
                )
            }
            cursor = end
        }
        return nil
    }

    func outputStart(of clipID: UUID) -> TimeInterval? {
        var cursor = 0.0
        for clip in clips {
            if clip.id == clipID { return cursor }
            cursor += clip.outputDuration
        }
        return nil
    }

    func simpleTrimRange() -> TimelineRange? {
        guard clips.count == 1, let clip = clips.first, clip.hasDefaultTreatment else { return nil }
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
        let right = EditSegment(
            sourceRange: TimelineRange(
                start: original.sourceRange.start + sourceOffset,
                duration: original.sourceRange.duration - sourceOffset
            ),
            playbackRate: original.playbackRate,
            transform: original.transform,
            volume: original.volume,
            scale: original.scale
        )
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
        let source = clips[index]
        let duplicate = EditSegment(
            sourceRange: source.sourceRange,
            playbackRate: source.playbackRate,
            transform: source.transform,
            volume: source.volume,
            scale: source.scale
        )
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
    let id: UUID
    var sourceRange: TimelineRange
    var playbackRate: Double
    var transform: VideoTransform
    var volume: Double
    var scale: Double

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
