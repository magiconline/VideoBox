import AVFoundation
import Foundation

enum PreviewFrameNavigationError: LocalizedError {
    case invalidTimeline
    case noVideoTrack
    case unsupportedSampleCursor
    case impreciseTiming
    case noVideoSamples
    case invalidSampleTimestamp

    var errorDescription: String? {
        switch self {
        case .invalidTimeline: return "当前剪辑时间线无法逐帧定位。"
        case .noVideoTrack: return "当前预览文件没有可用于逐帧定位的视频轨道。"
        case .unsupportedSampleCursor: return "当前视频格式不支持精确逐帧定位，请先生成兼容预览。"
        case .impreciseTiming: return "无法读取当前视频的精确帧时间，逐帧定位不可用。"
        case .noVideoSamples: return "当前剪辑范围内没有可定位的视频帧。"
        case .invalidSampleTimestamp: return "视频帧时间戳无效，无法精确逐帧定位。"
        }
    }
}

protocol PreviewFrameSampleCursor: AnyObject {
    var presentationSeconds: Double { get }
    @discardableResult func advance(_ direction: Int) -> Bool
}

private final class AssetFrameSampleCursor: PreviewFrameSampleCursor {
    struct Mapping {
        let sourceStart: Double
        let sourceDuration: Double
        let targetStart: Double
        let targetDuration: Double
        var sourceEnd: Double { sourceStart + sourceDuration }

        init?(_ mapping: CMTimeMapping) {
            sourceStart = mapping.source.start.seconds
            sourceDuration = mapping.source.duration.seconds
            targetStart = mapping.target.start.seconds
            targetDuration = mapping.target.duration.seconds
            guard sourceStart.isFinite, sourceDuration.isFinite, sourceDuration > 0,
                  targetStart.isFinite, targetDuration.isFinite, targetDuration > 0 else { return nil }
        }
    }

    private let track: AVAssetTrack
    private let mappings: [Mapping]
    private var mappingIndex: Int
    private var cursor: AVSampleCursor
    private static let epsilon = 0.000_000_1

    private init(track: AVAssetTrack, mappings: [Mapping], index: Int, cursor: AVSampleCursor) {
        self.track = track
        self.mappings = mappings
        mappingIndex = index
        self.cursor = cursor
    }

    static func make(track: AVAssetTrack, mappings: [Mapping], assetTime: Double) -> AssetFrameSampleCursor? {
        guard !mappings.isEmpty else { return nil }
        let index = mappings.lastIndex { $0.targetStart <= assetTime + epsilon } ?? 0
        let mapping = mappings[index]
        let fraction = min(1, max(0, (assetTime - mapping.targetStart) / mapping.targetDuration))
        let mediaTime = mapping.sourceStart + fraction * mapping.sourceDuration
        guard let cursor = makeCursor(track: track, mapping: mapping, mediaTime: mediaTime) else { return nil }
        return AssetFrameSampleCursor(track: track, mappings: mappings, index: index, cursor: cursor)
    }

    var presentationSeconds: Double {
        let mapping = mappings[mappingIndex]
        return mapping.targetStart + max(0, cursor.presentationTimeStamp.seconds - mapping.sourceStart)
            * mapping.targetDuration / mapping.sourceDuration
    }

    func advance(_ direction: Int) -> Bool {
        let mapping = mappings[mappingIndex]
        if direction > 0 {
            if cursor.stepInPresentationOrder(byCount: 1) != 0,
               cursor.presentationTimeStamp.seconds < mapping.sourceEnd - Self.epsilon {
                return true
            }
        } else if cursor.presentationTimeStamp.seconds > mapping.sourceStart + Self.epsilon,
                  cursor.stepInPresentationOrder(byCount: -1) != 0 {
            return true
        }

        var index = mappingIndex + direction
        while mappings.indices.contains(index) {
            let nextMapping = mappings[index]
            if let next = Self.makeCursor(
                track: track, mapping: nextMapping,
                mediaTime: direction > 0 ? nextMapping.sourceStart : nextMapping.sourceEnd
            ) {
                mappingIndex = index
                cursor = next
                return true
            }
            index += direction
        }
        return false
    }

    private static func makeCursor(track: AVAssetTrack, mapping: Mapping, mediaTime: Double) -> AVSampleCursor? {
        let time = CMTime(seconds: mediaTime + epsilon, preferredTimescale: 1_000_000_000)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { return nil }
        while cursor.presentationTimeStamp.seconds >= mapping.sourceEnd - epsilon {
            guard cursor.stepInPresentationOrder(byCount: -1) != 0 else { return nil }
        }
        return cursor
    }
}

/// Finds presentation samples in the original media and maps them through the edit
/// timeline. AVPlayerItem.step is deliberately not used: compositions can step to
/// unrelated presentation times before a display layer has established its clock.
enum PreviewFrameNavigator {
    private static let epsilon = 0.000_000_1

    static func destination(
        sourceURL: URL,
        editing: EditSettings,
        outputTime: Double,
        direction: Int
    ) async throws -> Double {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreviewFrameNavigationError.noVideoTrack
        }
        guard try await asset.load(.providesPreciseDurationAndTiming) else {
            throw PreviewFrameNavigationError.impreciseTiming
        }
        guard try await track.load(.canProvideSampleCursors) else {
            throw PreviewFrameNavigationError.unsupportedSampleCursor
        }
        let trackRange = try await track.load(.timeRange)
        // Sample cursors expose the media timeline, before an MP4/QuickTime edit
        // list. In particular, B-frame preroll often shifts media PTS away from
        // the asset's visible zero. Apply every nonempty track segment mapping
        // before mapping the user's clips into their output timeline.
        let mappings = try await track.load(.segments)
            .filter { !$0.isEmpty }
            .compactMap { AssetFrameSampleCursor.Mapping($0.timeMapping) }
            .sorted { $0.targetStart < $1.targetStart }
        guard !mappings.isEmpty else { throw PreviewFrameNavigationError.impreciseTiming }
        try Task.checkCancellation()
        return try destination(
            editing: editing,
            outputTime: outputTime,
            direction: direction,
            sampleRange: TimelineRange(start: trackRange.start.seconds, duration: trackRange.duration.seconds),
            makeCursor: { seconds in
                AssetFrameSampleCursor.make(track: track, mappings: mappings, assetTime: seconds)
            }
        )
    }

    static func destination(
        editing: EditSettings,
        outputTime: Double,
        direction: Int,
        sampleRange: TimelineRange,
        makeCursor: (Double) -> (any PreviewFrameSampleCursor)?
    ) throws -> Double {
        guard (direction == -1 || direction == 1), outputTime.isFinite,
              sampleRange.start.isFinite, sampleRange.duration.isFinite, sampleRange.duration > 0,
              !editing.clips.isEmpty,
              editing.clips.allSatisfy({
                  $0.sourceRange.start.isFinite && $0.sourceRange.duration.isFinite
                      && $0.sourceRange.duration > 0 && $0.playbackRate.isFinite && $0.playbackRate >= 0.1
              }), let location = editing.location(atOutputTime: outputTime) else {
            throw PreviewFrameNavigationError.invalidTimeline
        }
        try Task.checkCancellation()
        var outputStarts: [Double] = []
        var total = 0.0
        for clip in editing.clips {
            outputStarts.append(total)
            total += clip.outputDuration
        }

        func range(_ index: Int) -> TimelineRange? {
            let clip = editing.clips[index]
            let start = max(clip.sourceRange.start, sampleRange.start)
            let end = min(clip.sourceRange.end, sampleRange.end)
            return start < end ? TimelineRange(start: start, duration: end - start) : nil
        }

        func output(_ sourceTime: Double, in index: Int) -> Double {
            let clip = editing.clips[index]
            return outputStarts[index] + (sourceTime - clip.sourceRange.start) / clip.playbackRate
        }

        func timestamp(_ cursor: any PreviewFrameSampleCursor) throws -> Double {
            let time = cursor.presentationSeconds
            guard time.isFinite else { throw PreviewFrameNavigationError.invalidSampleTimestamp }
            return time
        }

        func boundary(_ index: Int, first: Bool) throws -> Double? {
            guard let range = range(index),
                  let cursor = makeCursor(first ? range.start : range.end) else { return nil }
            var time = try timestamp(cursor)
            if !first {
                while time >= range.end - epsilon {
                    try Task.checkCancellation()
                    guard cursor.advance(-1) else { return nil }
                    time = try timestamp(cursor)
                }
            }
            guard time < range.end - epsilon else { return nil }
            return output(max(range.start, time), in: index)
        }

        func adjacentBoundary(startingAt index: Int, direction: Int) throws -> Double? {
            var index = index
            while editing.clips.indices.contains(index) {
                try Task.checkCancellation()
                if let time = try boundary(index, first: direction > 0) { return time }
                index += direction
            }
            return nil
        }

        let index = location.clipIndex
        // At EOF there is no new frame. Return the final actual presentation sample,
        // rather than seeking the empty instant at the timeline's exclusive end.
        if location.outputTime >= total - epsilon {
            guard let last = try adjacentBoundary(startingAt: editing.clips.count - 1, direction: -1) else {
                throw PreviewFrameNavigationError.noVideoSamples
            }
            return last
        }

        guard let currentRange = range(index),
              let cursor = makeCursor(location.sourceTime) else {
            if let adjacent = try adjacentBoundary(startingAt: index + direction, direction: direction) {
                return adjacent
            }
            if let opposite = try adjacentBoundary(startingAt: index - direction, direction: -direction) {
                return opposite
            }
            throw PreviewFrameNavigationError.noVideoSamples
        }
        let sampleTime = try timestamp(cursor)
        let currentSourceTime = max(currentRange.start, sampleTime)
        let currentOutputTime = output(currentSourceTime, in: index)

        if direction > 0, currentSourceTime > location.sourceTime + epsilon,
           currentSourceTime < currentRange.end - epsilon {
            return currentOutputTime
        }

        if direction < 0, currentSourceTime <= currentRange.start + epsilon {
            return try adjacentBoundary(startingAt: index - 1, direction: -1) ?? currentOutputTime
        }

        while cursor.advance(direction) {
            try Task.checkCancellation()
            let next = try timestamp(cursor)
            // Several samples may share a presentation time; they are one visible
            // timeline position, so skip them without inventing a frame duration.
            guard Double(direction) * (next - sampleTime) > epsilon else { continue }
            if direction > 0 {
                if next < currentRange.end - epsilon {
                    return output(max(currentRange.start, next), in: index)
                }
                break
            } else {
                // A trim may start inside an existing frame. Its retained part is
                // the first visible frame at the clip start, even if its PTS is earlier.
                return output(max(currentRange.start, next), in: index)
            }
        }

        if let adjacent = try adjacentBoundary(startingAt: index + direction, direction: direction) {
            return adjacent
        }
        return try boundary(index, first: direction < 0) ?? currentOutputTime
    }
}
