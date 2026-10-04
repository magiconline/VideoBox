import Combine
import Foundation

@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [MediaJob] { didSet { persist() } }
    var onCancel: ((UUID) -> Void)?
    var onPause: ((UUID, Bool) -> Void)?
    var onStart: (() -> Void)?
    @Published private(set) var persistenceError: String?
    private let persistenceURL: URL?
    private var lastPersist = Date.distantPast

    init(jobs: [MediaJob] = [], persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
           let saved = try? JSONDecoder().decode([MediaJob].self, from: data) {
            self.jobs = saved.map { job in
                var value = job
                if !value.state.isTerminal { value.state = value.state == .cancelling ? .cancelled : .paused(progress: nil) }
                return value
            }
        } else { self.jobs = jobs }
    }
    private func persist() {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: persistenceURL, options: .atomic)
            persistenceError = nil; lastPersist = Date()
        } catch { persistenceError = "队列保存失败：\(error.localizedDescription)" }
    }
    func pause(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case let .running(progress): jobs[index].state = .paused(progress: progress ?? 0); onPause?(id, true)
        case .queued: jobs[index].state = .paused(progress: nil)
        default: break
        }
    }
    func resume(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), case let .paused(progress) = jobs[index].state else { return }
        if let progress { jobs[index].state = .running(progress: progress); onPause?(id, false) }
        else { jobs[index].state = .queued; onStart?() }
    }
    func retry(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isTerminal else { return }
        if case .completed = jobs[index].state { return }
        jobs[index].state = .queued; onStart?()
    }

    @discardableResult
    func enqueue(_ request: MediaJobRequest) -> UUID {
        let job = MediaJob(request: request)
        jobs.append(job)
        return job.id
    }

    func update(id: UUID, state: MediaJobState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    func cancel(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard !jobs[index].state.isTerminal else { return }
        if let onCancel, jobs[index].state.isActive {
            jobs[index].state = .cancelling
            onCancel(id)
        } else if case .cancelling = jobs[index].state {
            return
        } else {
            jobs[index].state = .cancelled
        }
    }

    func remove(id: UUID) {
        if let job = jobs.first(where: { $0.id == id }), !job.state.isTerminal {
            onCancel?(id)
        }
        jobs.removeAll { $0.id == id }
    }

    func updateProgress(id: UUID, progress: Double) {
        guard progress.isFinite,
              let index = jobs.firstIndex(where: { $0.id == id }),
              case let .running(previousProgress) = jobs[index].state else { return }
        let value = min(0.999, max(previousProgress ?? 0, progress))
        guard Date().timeIntervalSince(lastPersist) > 0.25 || abs(value - (previousProgress ?? 0)) > 0.01 else { return }
        jobs[index].state = .running(progress: value)
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }
}

extension MediaJobState {
    var isActive: Bool {
        switch self { case .running, .paused(progress: .some): true; default: false }
    }
}
