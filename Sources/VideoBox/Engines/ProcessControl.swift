import Darwin
import Foundation

/// Stop/continue the actual encoder process. A cancelled paused process must be
/// continued before TERM so it can close its files and the queue can advance.
final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var paused = false
    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if paused, process.isRunning { Darwin.kill(process.processIdentifier, SIGSTOP) }
    }
    func detach() { lock.lock(); defer { lock.unlock() }; process = nil }
    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }; paused = value
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, value ? SIGSTOP : SIGCONT) }
    }
    func terminate() {
        lock.lock(); defer { lock.unlock() }; paused = false
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGCONT)
            process.terminate()
        }
    }
}
