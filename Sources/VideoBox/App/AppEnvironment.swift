import Combine
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var toolchainReport = ToolchainReport.unchecked

    let jobQueue: JobQueue

    private let toolchainInspector: ToolchainInspector
    private var hasInspectedToolchain = false
    private var queueWorker: Task<Void, Never>?

    init(
        jobQueue: JobQueue? = nil,
        toolchainInspector: ToolchainInspector = ToolchainInspector()
    ) {
        self.jobQueue = jobQueue ?? JobQueue()
        self.toolchainInspector = toolchainInspector
    }

    func refreshToolchain(force: Bool = false) async {
        guard force || !hasInspectedToolchain else { return }
        hasInspectedToolchain = true
        toolchainReport = await toolchainInspector.inspect()
    }

    func probeMedia(at url: URL) async throws -> MediaProbe {
        await refreshToolchain()
        guard let executableURL = toolchainReport.executableURL(for: .ffprobe) else {
            throw AppEnvironmentError.missingTool("ffprobe")
        }
        return try await FFprobeEngine(executableURL: executableURL).probe(url)
    }

    @discardableResult
    func enqueueExport(_ request: ExportRequest) -> UUID {
        let id = jobQueue.enqueue(MediaJobRequest(exportRequest: request))
        startQueueWorkerIfNeeded()
        return id
    }

    private func startQueueWorkerIfNeeded() {
        guard queueWorker == nil else { return }

        queueWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { queueWorker = nil }

            while let job = nextQueuedJob {
                guard let executableURL = toolchainReport.executableURL(for: .ffmpeg) else {
                    jobQueue.update(id: job.id, state: .failed(message: "未检测到 FFmpeg"))
                    continue
                }

                jobQueue.update(id: job.id, state: .running(progress: 0))

                do {
                    let outputURL = try await FFmpegExportEngine(
                        executableURL: executableURL
                    ).export(job.request.exportRequest)
                    guard !isCancelledOrRemoved(job.id) else { continue }
                    jobQueue.update(id: job.id, state: .completed(outputURL: outputURL))
                } catch {
                    guard !isCancelledOrRemoved(job.id) else { continue }
                    jobQueue.update(
                        id: job.id,
                        state: .failed(message: error.localizedDescription)
                    )
                }
            }
        }
    }

    private var nextQueuedJob: MediaJob? {
        jobQueue.jobs.first {
            if case .queued = $0.state { return true }
            return false
        }
    }

    private func isCancelledOrRemoved(_ id: UUID) -> Bool {
        guard let job = jobQueue.jobs.first(where: { $0.id == id }) else { return true }
        if case .cancelled = job.state { return true }
        return false
    }
}

enum AppEnvironmentError: LocalizedError {
    case missingTool(String)

    var errorDescription: String? {
        switch self {
        case let .missingTool(name):
            "未找到 \(name)，无法读取媒体信息。"
        }
    }
}
