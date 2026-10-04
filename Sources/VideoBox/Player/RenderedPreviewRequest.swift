import Foundation

struct RenderedPreviewRequest: Identifiable {
    let id = UUID()
    let request: ExportRequest
    let outputStart: Double

    static func make(_ original: ExportRequest, at time: Double, length: Double = 5) -> RenderedPreviewRequest {
        var request = original
        request.configuration.mode = .transcode
        request.configuration.advanced.overwriteExisting = false
        if request.configuration.video.rateControl == .targetSize {
            request.configuration.video.averageBitrateKbps = TargetSizeBudget(configuration: original.configuration,
                duration: original.editing.trimmedDuration ?? original.sourceDuration).videoKbps
            request.configuration.video.rateControl = .averageBitrate
        }
        let duration = original.editing.trimmedDuration ?? original.sourceDuration ?? 0
        let start = min(max(0, time), max(0, duration - 0.1))
        let end = min(duration, start + length)
        if original.editing.requiresRenderedPreview {
            request.previewOutputRange = TimelineRange(start: start, duration: end - start)
            request.configuration.containerOptions.preserveChapters = false
            return RenderedPreviewRequest(request: request, outputStart: start)
        }
        var cursor = 0.0
        request.editing.clips = original.editing.clips.compactMap { clip in
            defer { cursor += clip.outputDuration }
            let low = max(start, cursor), high = min(end, cursor + clip.outputDuration)
            guard high > low else { return nil }
            var result = clip
            result.sourceRange = TimelineRange(start: clip.sourceRange.start + (low - cursor) * clip.playbackRate,
                                               duration: (high - low) * clip.playbackRate)
            return result
        }
        request.editing.selectedClipID = request.editing.clips.first?.id
        return RenderedPreviewRequest(request: request, outputStart: start)
    }
}
