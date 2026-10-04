import Foundation

enum TimedMetadataRemapper {
    static func ranges(start: Double, end: Double, editing: EditSettings, offset: Double = 0, primarySourceURL: URL? = nil) -> [TimelineRange] {
        guard start.isFinite, end.isFinite, end > start, offset.isFinite else { return [] }
        if editing.clips.isEmpty {
            let lo = max(0, start + offset), hi = max(0, end + offset)
            return hi > lo ? [TimelineRange(start: lo, duration: hi - lo)] : []
        }
        var ranges: [TimelineRange] = []
        let starts = editing.clipStartTimes
        for (index, clip) in editing.clips.enumerated() {
            if let clipURL = clip.sourceURL, primarySourceURL == nil || clipURL.standardizedFileURL != primarySourceURL?.standardizedFileURL { continue }
            let lo = max(start + offset, clip.sourceRange.start)
            let hi = min(end + offset, clip.sourceRange.end)
            if hi > lo, clip.playbackRate > 0 {
                ranges.append(TimelineRange(start: starts[index] + (lo - clip.sourceRange.start) / clip.playbackRate,
                                            duration: (hi - lo) / clip.playbackRate))
            }
        }
        return ranges
    }

    /// FFmpeg normalizes text subtitle formats to ASS, keeping styles and the
    /// text payload. Only event start/end fields are changed here.
    static func ass(_ contents: String, editing: EditSettings, offset: Double, primarySourceURL: URL? = nil) -> String {
        var header: [String] = []
        var events: [(Double, String)] = []
        var inEvents = false
        var startIndex = 1, endIndex = 2, fieldCount = 10
        for line in contents.components(separatedBy: .newlines) {
            if line.hasPrefix("[") { inEvents = line.trimmingCharacters(in: .whitespaces) == "[Events]" }
            if inEvents, line.hasPrefix("Format:") {
                let fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                startIndex = fields.firstIndex(of: "start") ?? 1
                endIndex = fields.firstIndex(of: "end") ?? 2
                fieldCount = fields.count
            }
            guard inEvents && line.hasPrefix("Dialogue:") else { header.append(line); continue }
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == fieldCount, let start = timestamp(fields[startIndex]), let end = timestamp(fields[endIndex]) else { continue }
            for range in ranges(start: start, end: end, editing: editing, offset: offset, primarySourceURL: primarySourceURL) {
                var mapped = fields
                mapped[startIndex] = assTime(range.start)
                mapped[endIndex] = assTime(range.end)
                if mapped[startIndex] != mapped[endIndex] { events.append((range.start, "Dialogue: " + mapped.joined(separator: ","))) }
            }
        }
        return (header + events.sorted { $0.0 < $1.0 }.map(\.1)).joined(separator: "\n") + "\n"
    }

    static func chapters(_ chapters: [MediaChapter], editing: EditSettings, primarySourceURL: URL? = nil) -> [MediaChapter] {
        let mapped = chapters.flatMap { chapter in
            ranges(start: chapter.startTime, end: chapter.endTime, editing: editing, primarySourceURL: primarySourceURL).map {
                MediaChapter(id: 0, startTime: $0.start, endTime: $0.end, title: chapter.title)
            }
        }.sorted { $0.startTime < $1.startTime }
        return mapped.enumerated().map { index, chapter in
            MediaChapter(id: index, startTime: chapter.startTime, endTime: chapter.endTime, title: chapter.title)
        }
    }

    static func ffmetadata(_ chapters: [MediaChapter]) -> String {
        var lines = [";FFMETADATA1"]
        for chapter in chapters {
            lines += ["[CHAPTER]", "TIMEBASE=1/1000000", "START=\(Int((chapter.startTime * 1_000_000).rounded()))",
                      "END=\(Int((chapter.endTime * 1_000_000).rounded()))"]
            if let title = chapter.title {
                let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "=", with: "\\=").replacingOccurrences(of: ";", with: "\\;")
                    .replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "\n", with: " ")
                lines.append("title=\(escaped)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ value: String) -> Double? {
        let fields = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard fields.count == 3, let h = Double(fields[0]), let m = Double(fields[1]), let s = Double(fields[2]) else { return nil }
        return h * 3_600 + m * 60 + s
    }
    private static func assTime(_ seconds: Double) -> String {
        let cs = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6_000 % 60, cs / 100 % 60, cs % 100)
    }
}
