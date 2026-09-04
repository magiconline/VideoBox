import Foundation

protocol MediaProbing: Sendable {
    func probe(_ sourceURL: URL) async throws -> MediaProbe
}

protocol MediaExporting: Sendable {
    @discardableResult
    func export(_ request: ExportRequest) async throws -> URL
}

enum MediaEngineError: LocalizedError {
    case destinationAlreadyExists(URL)
    case commandFailed(tool: String, status: Int32, message: String)
    case invalidProbeOutput(Error)
    case previewNotPlayable

    var errorDescription: String? {
        switch self {
        case let .destinationAlreadyExists(url):
            "目标文件已存在：\(url.path)"
        case let .commandFailed(tool, status, message):
            "\(tool) 执行失败（状态码 \(status)）：\(message)"
        case let .invalidProbeOutput(error):
            "无法解析 ffprobe 输出：\(error.localizedDescription)"
        case .previewNotPlayable:
            "预览文件已生成，但 macOS 播放器无法解码其视频轨道。"
        }
    }
}
