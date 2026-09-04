import Foundation

actor ProcessRunner: CLIProcessRunning {
    func run(_ command: CLICommand) async throws -> CLIResult {
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
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
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
        } catch {
            throw CLIProcessError.launchFailed(
                executable: command.executableURL,
                underlying: error
            )
        }

        process.waitUntilExit()
        try Task.checkCancellation()

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)

        return CLIResult(
            terminationStatus: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}
