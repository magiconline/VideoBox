import AVFoundation
import Foundation

struct PreviewTimeline {
    let asset: AVAsset
    let audioMix: AVAudioMix?
    let duration: TimeInterval
    var audioResource: PreviewAudioResource?
    var videoResource: PreviewVideoResource?
}

/// Preview media time is always edited/output time, including duplicated ranges and speed changes.
enum PreviewTimelineBuilder {
    static func make(asset: AVAsset, editing: EditSettings) async throws -> PreviewTimeline {
        guard !editing.clips.isEmpty else {
            let duration = try await asset.load(.duration).seconds
            return PreviewTimeline(asset: asset, audioMix: nil, duration: duration.isFinite ? duration : 0)
        }
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PreviewTimelineError.missingVideo
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let videoRange = try await sourceVideo.load(.timeRange)
        var sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        var audioResource: PreviewAudioResource?
        let usesRenderedAudio = sourceAudio != nil && editing.clips.contains { abs($0.playbackRate - 1) > 0.000_1 || $0.volume > 1 }
        if usesRenderedAudio {
            guard let urlAsset = asset as? AVURLAsset else { throw PreviewTimelineError.invalidRange }
            audioResource = try await PreviewAudioRenderer.render(source: urlAsset.url, editing: editing)
            sourceAudio = try await audioResource!.asset.loadTracks(withMediaType: .audio).first
        }
        let audio = sourceAudio.flatMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let audioRange = try await sourceAudio?.load(.timeRange)
        let audioParameters = audio.map(AVMutableAudioMixInputParameters.init(track:))
        var cursor = CMTime.zero
        for clip in editing.clips {
            try Task.checkCancellation()
            guard clip.sourceRange.start.isFinite, clip.sourceRange.duration.isFinite,
                  clip.sourceRange.start >= 0, clip.sourceRange.duration > 0,
                  clip.playbackRate.isFinite, clip.playbackRate > 0 else {
                throw PreviewTimelineError.invalidRange
            }
            let range = CMTimeRange(start: time(clip.sourceRange.start), duration: time(clip.sourceRange.duration))
            let outputDuration = time(clip.outputDuration)
            try insert(range, from: sourceVideo, available: videoRange, into: video, at: cursor, scaledTo: outputDuration)
            if !usesRenderedAudio, let sourceAudio, let audio, let audioRange {
                try insert(range, from: sourceAudio, available: audioRange, into: audio, at: cursor, scaledTo: outputDuration)
                audioParameters?.setVolume(Float(max(0, min(1, clip.volume))), at: cursor)
            }
            cursor = CMTimeAdd(cursor, outputDuration)
        }
        if usesRenderedAudio, let sourceAudio, let audio, let audioRange {
            try insert(CMTimeRange(start: .zero, duration: cursor), from: sourceAudio, available: audioRange,
                       into: audio, at: .zero, scaledTo: cursor)
            audioParameters?.setVolume(1, at: .zero)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters.map { [$0] } ?? []
        return PreviewTimeline(asset: composition, audioMix: audio == nil ? nil : mix, duration: cursor.seconds, audioResource: audioResource)
    }

    private static func insert(
        _ range: CMTimeRange, from source: AVAssetTrack, available: CMTimeRange,
        into destination: AVMutableCompositionTrack, at cursor: CMTime, scaledTo duration: CMTime
    ) throws {
        // Some files have shorter audio tracks or non-zero track starts. Keep these gaps instead of shifting audio.
        let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
        if intersection.isValid, !intersection.isEmpty {
            let prefix = CMTimeSubtract(intersection.start, range.start)
            if prefix > .zero {
                destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: prefix))
            }
            try destination.insertTimeRange(intersection, of: source, at: CMTimeAdd(cursor, prefix))
            let suffix = CMTimeSubtract(range.end, intersection.end)
            if suffix > .zero {
                destination.insertEmptyTimeRange(CMTimeRange(start: CMTimeAdd(cursor, CMTimeAdd(prefix, intersection.duration)), duration: suffix))
            }
        } else {
            destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
        }
        destination.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: duration)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }
}

private enum PreviewTimelineError: LocalizedError {
    case missingVideo
    case invalidRange
    var errorDescription: String? {
        switch self {
        case .missingVideo: "无法为此视频创建剪辑预览，请尝试切换预览轨道。"
        case .invalidRange: "剪辑片段的时间或速度无效。"
        }
    }
}
