import Combine
import Foundation

@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [MediaJob]

    init(jobs: [MediaJob] = []) {
        self.jobs = jobs
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
        jobs[index].state = .cancelled
    }

    func remove(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }
}
