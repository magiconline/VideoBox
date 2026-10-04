import Foundation

enum Timecode {
    static func parse(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty }),
              let seconds = Double(fields.last!), seconds.isFinite, seconds >= 0 else { return nil }
        if fields.count == 1 { return seconds }
        guard seconds < 60, let minutes = Int(fields[fields.count - 2]), minutes >= 0 else { return nil }
        if fields.count == 2 { return Double(minutes * 60) + seconds }
        guard minutes < 60, let hours = Int(fields[0]), hours >= 0, hours < 100_000 else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 360_000_000 else { return "00:00:00.000" }
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
