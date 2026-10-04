import Darwin
import Foundation

actor ProcessRunner: CLIProcessRunning {
    private let control: ProcessControl?
    init(control: ProcessControl? = nil) { self.control = control }
    func run(_ command: CLICommand) async throws -> CLIResult {
        try await run(command, onStandardOutput: nil)
    }

    func run(
        _ command: CLICommand,
        onStandardOutput: (@Sendable (String) -> Void)?
    ) async throws -> CLIResult {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VideoBox-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = captureDirectory.appendingPathComponent("stdout.log")
        let stderrURL = captureDirectory.appendingPathComponent("stderr.log")

        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        defer {
            try? fileManager.removeItem(at: captureDirectory)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let progressHandle = try FileHandle(forReadingFrom: stdoutURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? progressHandle.close()
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) {
                _, suppliedValue in suppliedValue
            }
        }

        do {
            try process.run()
            control?.attach(process)
        } catch {
            throw CLIProcessError.launchFailed(
                executable: command.executableURL,
                underlying: error
            )
        }
        defer { control?.detach() }

        do {
            while process.isRunning {
                if let onStandardOutput {
                    let data = try progressHandle.readToEnd() ?? Data()
                    if !data.isEmpty {
                        onStandardOutput(String(decoding: data, as: UTF8.self))
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                control?.setPaused(false)
                process.terminate()
                // The caller is already cancelled. Wait in an independent task so
                // cancellation cannot skip cleanup or leave FFmpeg writing output.
                await Task.detached {
                    let deadline = ContinuousClock.now + .seconds(1)
                    while process.isRunning && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    // Foundation's waitUntilExit can miss a termination notification
                    // after SIGCONT / SIGKILL on a detached thread. isRunning is
                    // updated by Process's termination handler and avoids that wait.
                    while process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
                }.value
            }
            throw error
        }

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        if let onStandardOutput {
            let remaining = try progressHandle.readToEnd() ?? Data()
            if !remaining.isEmpty {
                onStandardOutput(String(decoding: remaining, as: UTF8.self))
            }
        }

        let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)

        return CLIResult(
            terminationStatus: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}
