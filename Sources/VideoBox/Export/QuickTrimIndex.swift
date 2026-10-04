import Foundation

struct QuickTrimIndex: Codable, Equatable, Sendable {
    let sourceURL: URL
    let streamIndex: Int
    let size: Int?
    let modifiedAt: Date?
    let keyframes: [Double]
    let duration: Double

    func isCurrent(for url: URL, streamIndex: Int) -> Bool {
        guard sourceURL.standardizedFileURL == url.standardizedFileURL, self.streamIndex == streamIndex,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        return values.fileSize == size && values.contentModificationDate == modifiedAt
    }
    func isAligned(_ range: TimelineRange) -> Bool {
        isBoundary(range.start) && (abs(range.end - duration) < 0.002 || isBoundary(range.end))
    }
    private func isBoundary(_ time: Double) -> Bool {
        abs(time) < 0.000_01 || keyframes.contains { abs($0 - time) < 0.000_1 }
    }
    func expandedRange(_ range: TimelineRange) -> TimelineRange? {
        let start = ([0.0] + keyframes).last(where: { $0 <= range.start + 0.000_1 }) ?? 0
        let end = keyframes.first(where: { $0 >= range.end - 0.000_1 }) ?? duration
        return end > start ? TimelineRange(start: start, duration: end - start) : nil
    }

    static func scan(url: URL, streamIndex: Int, duration: Double, ffprobe: URL, runner: any CLIProcessRunning = ProcessRunner()) async throws -> QuickTrimIndex {
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let result = try await runner.run(CLICommand(executableURL: ffprobe, arguments: [
            "-v", "error", "-skip_frame", "nokey", "-select_streams", String(streamIndex), "-show_frames", "-show_format",
            "-show_entries", "frame=best_effort_timestamp_time,key_frame:format=start_time", "-of", "json", url.path
        ]))
        guard result.succeeded else { throw ExportValidationError(blockers: ["关键帧分析失败：\(result.standardError)"]) }
        struct Payload: Decodable {
            struct Frame: Decodable { let best_effort_timestamp_time: String?; let key_frame: Int? }
            struct Format: Decodable { let start_time: String? }
            let frames: [Frame]; let format: Format?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(result.standardOutput.utf8))
        let origin = payload.format?.start_time.flatMap(Double.init) ?? 0
        let keyframes = payload.frames.filter { $0.key_frame == 1 }.compactMap { $0.best_effort_timestamp_time.flatMap(Double.init) }
            .map { $0 - origin }.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !keyframes.isEmpty else { throw ExportValidationError(blockers: ["没有读取到可用关键帧，请使用压缩导出精确裁切"]) }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw ExportValidationError(blockers: ["分析期间源文件发生变化，请重新载入"])
        }
        return QuickTrimIndex(sourceURL: url, streamIndex: streamIndex, size: after.fileSize,
                              modifiedAt: after.contentModificationDate, keyframes: keyframes, duration: duration)
    }
}
