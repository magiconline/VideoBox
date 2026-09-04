import Combine
import Darwin
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var toolchainReport = ToolchainReport.unchecked

    let jobQueue: JobQueue

    private let toolchainInspector: ToolchainInspector
    private let previewSessionDirectoryURL: URL
    private var hasInspectedToolchain = false
    private var queueWorker: Task<Void, Never>?

    init(
        jobQueue: JobQueue? = nil,
        toolchainInspector: ToolchainInspector = ToolchainInspector()
    ) {
        self.jobQueue = jobQueue ?? JobQueue()
        self.toolchainInspector = toolchainInspector
        let previewRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoBox-TrackPreviews", isDirectory: true)
        self.previewSessionDirectoryURL = previewRootURL
            .appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        Self.removeAbandonedPreviewItems(
            in: previewRootURL,
            activeProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
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

    @discardableResult
    func enqueueTrackExtraction(
        _ track: TrackExportSettings,
        primarySourceURL: URL,
        destinationURL: URL,
        overwriteExisting: Bool = false
    ) -> UUID {
        var configuration = ExportConfiguration()
        configuration.mode = .streamCopy
        configuration.advanced.overwriteExisting = overwriteExisting
        let request = ExportRequest(
            sourceURL: primarySourceURL,
            destinationURL: destinationURL,
            sourceDuration: track.sourceDuration,
            configuration: configuration,
            editing: EditSettings(),
            operation: .trackExtraction(track)
        )
        return enqueueExport(request)
    }

    func createTrackPreview(
        primarySourceURL: URL,
        tracks: [TrackExportSettings],
        duration: TimeInterval?,
        subtitleOffset: TimeInterval
    ) async throws -> TrackPreviewAsset {
        await refreshToolchain()
        guard let executableURL = toolchainReport.executableURL(for: .ffmpeg) else {
            throw AppEnvironmentError.missingTool("FFmpeg")
        }
        guard tracks.contains(where: { $0.kind == .video }) else {
            throw AppEnvironmentError.missingPreviewVideo
        }
        let imageSubtitleCodecs: Set<String> = [
            "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "dvb_teletext",
            "xsub", "arib_caption"
        ]
        if let subtitle = tracks.first(where: { $0.kind == .subtitle }),
           let codec = subtitle.codecName?.lowercased(),
           imageSubtitleCodecs.contains(codec) {
            throw AppEnvironmentError.unsupportedPreviewSubtitle(codec)
        }
        for track in tracks {
            let sourceURL = track.resolvedSourceURL(primarySourceURL: primarySourceURL)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw AppEnvironmentError.missingTrackSource(sourceURL)
            }
        }

        let directoryURL = previewSessionDirectoryURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destinationURL = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let request = TrackPreviewRequest(
            primarySourceURL: primarySourceURL,
            destinationURL: destinationURL,
            tracks: tracks,
            duration: duration,
            subtitleOffset: subtitleOffset
        )

        do {
            return try await FFmpegTrackPreviewEngine(
                executableURL: executableURL
            ).createPreview(request)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(
                at: destinationURL.deletingPathExtension().appendingPathExtension("srt")
            )
            throw error
        }
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

    private static func removeAbandonedPreviewItems(
        in rootURL: URL,
        activeProcessIdentifier: Int32
    ) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                // Pre-session versions stored preview files directly in this directory.
                try? FileManager.default.removeItem(at: item)
                continue
            }

            let processComponent = item.lastPathComponent.split(separator: "-", maxSplits: 1).first
            guard let processComponent,
                  let processIdentifier = Int32(processComponent),
                  processIdentifier > 0 else {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            if processIdentifier == activeProcessIdentifier {
                continue
            }

            Darwin.errno = 0
            let processIsRunning = Darwin.kill(processIdentifier, 0) == 0 || Darwin.errno == EPERM
            if !processIsRunning {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

enum AppEnvironmentError: LocalizedError {
    case missingTool(String)
    case missingPreviewVideo
    case missingTrackSource(URL)
    case unsupportedPreviewSubtitle(String)

    var errorDescription: String? {
        switch self {
        case let .missingTool(name):
            "未找到 \(name)，无法读取媒体信息。"
        case .missingPreviewVideo:
            "至少需要一条视频轨道才能生成播放预览。"
        case let .missingTrackSource(url):
            "轨道源文件已不可用：\(url.lastPathComponent)"
        case let .unsupportedPreviewSubtitle(codec):
            "暂时无法在播放器中显示 \(codec.uppercased()) 图形字幕；仍可单独导出或随成片封装。"
        }
    }
}
