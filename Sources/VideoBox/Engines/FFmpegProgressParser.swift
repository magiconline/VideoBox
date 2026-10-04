import Foundation

/// Reads FFmpeg's `-progress` records. Percentages are based on encoded media
/// timestamps, never elapsed wall time; successful exit owns the completed state.
final class FFmpegProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: TimeInterval?
    private var buffer = ""
    private var outputTime: TimeInterval?
    private var lastProgress: Double = 0

    init(duration: TimeInterval?) {
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    func consume(_ chunk: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        var result: Double?
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "out_time_us", "out_time_ms":
                // FFmpeg's historic out_time_ms field is also in microseconds.
                if let value = Double(pair[1]), value.isFinite {
                    outputTime = max(0, value / 1_000_000)
                }
            case "progress":
                guard let duration, let outputTime else { continue }
                let progress = min(0.999, max(lastProgress, outputTime / duration))
                lastProgress = progress
                result = progress
            default:
                break
            }
        }
        return result
    }
}
