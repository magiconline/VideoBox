import Foundation

struct CLICommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

struct CLIResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { terminationStatus == 0 }
}

protocol CLIProcessRunning: Sendable {
    func run(_ command: CLICommand) async throws -> CLIResult
}

enum CLIProcessError: LocalizedError {
    case launchFailed(executable: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, underlying):
            "无法启动 \(executable.lastPathComponent)：\(underlying.localizedDescription)"
        }
    }
}
