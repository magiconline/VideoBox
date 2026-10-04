import AVFoundation
import Foundation

final class PreviewAudioResource: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    init(url: URL) { self.url = url; self.asset = AVURLAsset(url: url) }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

enum PreviewAudioRenderer {
    static func render(source: URL, editing: EditSettings) async throws -> PreviewAudioResource {
        let report = await ToolchainInspector().inspect()
        guard let ffmpeg = report.executableURL(for: .ffmpeg) else {
            throw ExportValidationError(blockers: ["变速或增益预听需要随包 FFmpeg，不能用不一致的音频替代"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoBox-TrackPreviews", isDirectory: true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resource = PreviewAudioResource(url: directory.appendingPathComponent("audio.caf"))
        let count = editing.clips.count
        let sources = count == 1 ? ["[0:a:0]"] : editing.clips.indices.map { "[asource\($0)]" }
        var graph: [String] = count == 1 ? [] : ["[0:a:0]asplit=\(count)\(sources.joined())"]
        for (index, clip) in editing.clips.enumerated() {
            graph.append("\(sources[index])\(AudioClipProcessing.filters(clip).joined(separator: ","))[aclip\(index)]")
        }
        graph.append(editing.clips.indices.map { "[aclip\($0)]" }.joined() + "concat=n=\(count):v=0:a=1[aout]")
        let result = try await ProcessRunner().run(CLICommand(executableURL: ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-n", "-i", source.path, "-filter_complex", graph.joined(separator: ";"),
            "-map", "[aout]", "-vn", "-c:a", "pcm_f32le", "-f", "caf", resource.url.path
        ]))
        guard result.succeeded else { throw ExportValidationError(blockers: ["音频预听处理失败：\(result.standardError)"]) }
        try Task.checkCancellation()
        return resource
    }
}
