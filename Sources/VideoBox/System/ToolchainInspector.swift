import Foundation

enum CLITool: String, CaseIterable, Identifiable, Sendable {
    case ffprobe
    case ffmpeg

    var id: Self { self }

    var displayName: String {
        switch self {
        case .ffprobe: "ffprobe"
        case .ffmpeg: "FFmpeg"
        }
    }
}

struct ToolAvailability: Identifiable, Sendable {
    let tool: CLITool
    let executableURL: URL?

    var id: CLITool { tool }
    var isAvailable: Bool { executableURL != nil }
}

struct ToolchainReport: Sendable {
    let entries: [ToolAvailability]
    let checkedAt: Date?

    static let unchecked = ToolchainReport(
        entries: CLITool.allCases.map { ToolAvailability(tool: $0, executableURL: nil) },
        checkedAt: nil
    )

    func executableURL(for tool: CLITool) -> URL? {
        entries.first(where: { $0.tool == tool })?.executableURL
    }
}

struct ExecutableLocator: Sendable {
    let searchDirectories: [URL]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL
    ) {
        var searchDirectories: [URL] = []

        if let bundleURL, bundleURL.pathExtension == "app" {
            searchDirectories.append(
                bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
            )
        }

        let pathDirectories = environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        self.init(
            searchDirectories: searchDirectories + pathDirectories + [
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/bin", isDirectory: true)
            ]
        )
    }

    init(searchDirectories: [URL]) {
        var seen = Set<String>()
        self.searchDirectories = searchDirectories.filter { seen.insert($0.path).inserted }
    }

    func locate(_ tool: CLITool) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

actor ToolchainInspector {
    private let locator: ExecutableLocator

    init(locator: ExecutableLocator = ExecutableLocator()) {
        self.locator = locator
    }

    func inspect() -> ToolchainReport {
        ToolchainReport(
            entries: CLITool.allCases.map { tool in
                ToolAvailability(tool: tool, executableURL: locator.locate(tool))
            },
            checkedAt: Date()
        )
    }
}
