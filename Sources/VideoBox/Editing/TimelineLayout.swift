import Foundation

/// One geometry for clip cells, the playhead, scrubbing, and ruler labels.
/// Short clips retain a usable hit area; that extra width belongs to scroll content.
struct TimelineLayout {
    struct Segment {
        let startX: Double
        let width: Double
        let startTime: TimeInterval
        let duration: TimeInterval

        var endX: Double { startX + width }
        var endTime: TimeInterval { startTime + duration }
    }

    let segments: [Segment]
    let contentWidth: Double
    let duration: TimeInterval
    let spacing: Double

    init(
        durations: [TimeInterval],
        viewportWidth: Double,
        minimumClipWidth: Double = 24,
        minimumAverageClipWidth: Double = 92,
        spacing: Double = 3
    ) {
        let safeDurations = durations.map { $0.isFinite ? max(0, $0) : 0 }
        let totalDuration = safeDurations.reduce(0, +)
        let safeViewport = viewportWidth.isFinite ? max(1, viewportWidth) : 1
        let baseWidth = max(safeViewport, Double(safeDurations.count) * minimumAverageClipWidth)
        let gapWidth = Double(max(0, safeDurations.count - 1)) * spacing
        let usableWidth = max(1, baseWidth - gapWidth)
        var cursorX = 0.0
        var cursorTime = 0.0
        var segments: [Segment] = []
        for duration in safeDurations {
            let fraction = totalDuration > 0 ? duration / totalDuration : 1 / Double(safeDurations.count)
            let width = max(minimumClipWidth, usableWidth * fraction)
            segments.append(Segment(startX: cursorX, width: width, startTime: cursorTime, duration: duration))
            cursorX += width + spacing
            cursorTime += duration
        }
        self.segments = segments
        self.contentWidth = max(baseWidth, segments.last?.endX ?? 0)
        self.duration = totalDuration
        self.spacing = spacing
    }

    func x(atTime requestedTime: TimeInterval) -> Double {
        guard requestedTime.isFinite else { return 0 }
        let time = min(duration, max(0, requestedTime))
        guard time < duration else { return segments.last?.endX ?? 0 }
        for segment in segments where time < segment.endTime {
            let fraction = segment.duration > 0 ? (time - segment.startTime) / segment.duration : 0
            return segment.startX + segment.width * max(0, fraction)
        }
        return 0
    }

    func time(atX requestedX: Double) -> TimeInterval {
        guard requestedX.isFinite else { return 0 }
        let x = min(contentWidth, max(0, requestedX))
        for segment in segments where x <= segment.endX {
            let fraction = segment.width > 0 ? max(0, x - segment.startX) / segment.width : 0
            return segment.startTime + segment.duration * fraction
        }
        return duration
    }
}
