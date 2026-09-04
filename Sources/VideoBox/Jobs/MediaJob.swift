import Foundation

struct MediaJobRequest: Codable, Equatable, Sendable {
    let exportRequest: ExportRequest

    var sourceURL: URL { exportRequest.sourceURL }
    var destinationURL: URL { exportRequest.destinationURL }
    var exportMode: ExportMode { exportRequest.configuration.mode }
}

struct MediaJob: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let request: MediaJobRequest
    let createdAt: Date
    var state: MediaJobState

    init(
        id: UUID = UUID(),
        request: MediaJobRequest,
        createdAt: Date = Date(),
        state: MediaJobState = .queued
    ) {
        self.id = id
        self.request = request
        self.createdAt = createdAt
        self.state = state
    }
}

enum MediaJobState: Codable, Equatable, Sendable {
    case queued
    case running(progress: Double)
    case completed(outputURL: URL?)
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }

    var displayName: String {
        switch self {
        case .queued: "等待中"
        case let .running(progress): "处理中 \(Int(progress * 100))%"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

protocol MediaJobExecuting: Sendable {
    func execute(_ request: MediaJobRequest) async throws -> URL?
}
