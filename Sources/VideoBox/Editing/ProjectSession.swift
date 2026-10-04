import AppKit
import Combine
import Foundation
import SwiftUI

struct VideoBoxProject: Codable, Equatable {
    var version = 1
    var sourceURL: URL
    var editing: EditSettings
    var configuration: ExportConfiguration
    var outputDirectoryURL: URL?
    var outputFileName: String
    var playhead = 0.0
    var savedAt = Date()

    var referencedURLs: [URL] {
        Array(Set([sourceURL] + configuration.trackSettings.compactMap(\.sourceURL)
                  + [configuration.color.lutFile?.url].compactMap { $0 } + editing.referencedURLs))
    }

    func validate() throws {
        guard version == 1 else { throw ProjectError.invalid("此工程版本暂不受支持") }
        guard editing.outputDuration.isFinite, editing.clips.allSatisfy({
            $0.sourceRange.start.isFinite && $0.sourceRange.duration.isFinite && $0.sourceRange.start >= 0
                && $0.sourceRange.duration > 0 && $0.playbackRate.isFinite && (0.1...8).contains($0.playbackRate)
        }) else { throw ProjectError.invalid("工程内存在无效的时间或速度") }
        if let issue = editing.validationIssues.first { throw ProjectError.invalid(issue) }
    }

    static func read(_ url: URL) throws -> VideoBoxProject {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16_000_000 else { throw ProjectError.invalid("工程文件过大") }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func write(_ url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum ProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

@MainActor
final class ProjectSession: ObservableObject {
    @Published var editing = EditSettings() { didSet { changed(previousEditing: oldValue) } }
    @Published var configuration = ExportConfiguration() { didSet { changed(previousConfiguration: oldValue) } }
    @Published private(set) var projectURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var persistenceError: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var sourceURL: URL?
    var outputDirectoryURL: URL?
    var outputFileName = ""
    var playhead = 0.0
    private var undoStates: [(EditSettings, ExportConfiguration)] = []
    private var redoStates: [(EditSettings, ExportConfiguration)] = []
    private var restoring = false
    private var lastChange = Date.distantPast
    private var lastKind = ""
    private var autosaveTask: Task<Void, Never>?
    let recoveryURL: URL

    init(recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL ?? Self.applicationDirectory.appendingPathComponent("LastSession.vboxproject")
    }
    deinit { autosaveTask?.cancel() }

    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoBox", isDirectory: true)
    }

    var project: VideoBoxProject? {
        sourceURL.map { VideoBoxProject(sourceURL: $0, editing: editing, configuration: configuration,
            outputDirectoryURL: outputDirectoryURL, outputFileName: outputFileName, playhead: playhead) }
    }

    func begin(_ project: VideoBoxProject, fileURL: URL? = nil) {
        restoring = true
        sourceURL = project.sourceURL; editing = project.editing; configuration = project.configuration
        outputDirectoryURL = project.outputDirectoryURL; outputFileName = project.outputFileName; playhead = project.playhead
        projectURL = fileURL; isDirty = false; undoStates = []; redoStates = []; refreshHistory()
        restoring = false
        autosave()
    }

    func undo() {
        guard let state = undoStates.popLast() else { return }
        redoStates.append((editing, configuration)); restore(state)
    }
    func redo() {
        guard let state = redoStates.popLast() else { return }
        undoStates.append((editing, configuration)); restore(state)
    }
    private func restore(_ state: (EditSettings, ExportConfiguration)) {
        restoring = true; editing = state.0; configuration = state.1; restoring = false
        lastChange = .distantPast; isDirty = true; refreshHistory(); autosave()
    }
    private func refreshHistory() { canUndo = !undoStates.isEmpty; canRedo = !redoStates.isEmpty }
    private func changed(previousEditing: EditSettings? = nil, previousConfiguration: ExportConfiguration? = nil) {
        guard !restoring, sourceURL != nil else { return }
        var beforeEdit = previousEditing ?? editing, afterEdit = editing
        beforeEdit.selectedClipID = nil; afterEdit.selectedClipID = nil
        var beforeConfig = previousConfiguration ?? configuration, afterConfig = configuration
        beforeConfig.copyTrimIndex = nil; afterConfig.copyTrimIndex = nil
        guard beforeEdit != afterEdit || beforeConfig != afterConfig else { return }
        let kind: String
        if beforeEdit.clips.map(\.id) != afterEdit.clips.map(\.id) { kind = "clip-action-\(UUID().uuidString)" }
        else { kind = previousEditing != nil ? "clip" : "settings" }
        var modeNeutral = beforeConfig; modeNeutral.mode = afterConfig.mode
        let automaticModeChange = previousConfiguration != nil && modeNeutral == afterConfig && beforeConfig.mode != afterConfig.mode
            && lastKind.hasPrefix("clip") && Date().timeIntervalSince(lastChange) < 0.1
        if !automaticModeChange && (kind != lastKind || Date().timeIntervalSince(lastChange) > 0.4) {
            undoStates.append((previousEditing ?? editing, previousConfiguration ?? configuration))
            if undoStates.count > 100 { undoStates.removeFirst() }
        }
        if !automaticModeChange { lastKind = kind }
        lastChange = Date(); redoStates = []; isDirty = true; refreshHistory()
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }; self?.autosave()
        }
    }
    func autosave() {
        autosaveTask?.cancel(); autosaveTask = nil
        guard let project else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = recoveryURL.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: recoveryURL.path), (try? VideoBoxProject.read(recoveryURL)) != nil {
                try Data(contentsOf: recoveryURL).write(to: previous, options: .atomic)
            }
            try project.write(recoveryURL); persistenceError = nil
        } catch { persistenceError = "自动保存失败：\(error.localizedDescription)" }
    }
    func save(to url: URL) throws {
        guard let project else { return }
        guard !project.referencedURLs.contains(where: { ExportPlan.refersToSameFile($0, url) }) else { throw ProjectError.invalid("工程文件不能覆盖素材") }
        try project.write(url); projectURL = url; isDirty = false; autosave()
    }
    func recovery() -> VideoBoxProject? {
        (try? VideoBoxProject.read(recoveryURL)) ?? (try? VideoBoxProject.read(recoveryURL.appendingPathExtension("previous")))
    }
}

struct ProjectActions {
    var session: ProjectSession
    var open: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var appendMedia: () -> Void
}
private struct ProjectActionsKey: FocusedValueKey { typealias Value = ProjectActions }
extension FocusedValues {
    var projectActions: ProjectActions? {
        get { self[ProjectActionsKey.self] }
        set { self[ProjectActionsKey.self] = newValue }
    }
}
