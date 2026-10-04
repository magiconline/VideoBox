import AppKit
import SwiftUI

struct JobQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var queue: JobQueue

    var body: some View {
        Group {
            if queue.jobs.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "tray")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("队列为空")
                        .font(.title2.bold())
                    Text("导入视频并完成设置后，可将导出任务加入这里。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job) {
                            queue.cancel(id: job.id)
                        } remove: {
                            queue.remove(id: job.id)
                        } pause: {
                            queue.pause(id: job.id)
                        } resume: {
                            queue.resume(id: job.id)
                        } retry: {
                            queue.retry(id: job.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("任务队列")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading) {
                Text("重启后未完成的任务等待恢复；恢复时从头处理，已完成文件不受影响。")
                if let message = queue.persistenceError { Text(message).foregroundStyle(.red) }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .toolbar {
            ToolbarItem { Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            ToolbarItem {
                Button("清理已结束任务") {
                    queue.clearFinished()
                }
                .disabled(!queue.jobs.contains(where: { $0.state.isTerminal }))
            }
        }
    }
}

private struct JobRow: View {
    let job: MediaJob
    let cancel: () -> Void
    let remove: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.request.operationSymbolName)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.sourceURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(job.request.operationDisplayName) · \(job.request.destinationURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case let .running(progress) = job.state {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 240)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("正在处理…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if case let .paused(progress) = job.state, let progress { ProgressView(value: progress).frame(maxWidth: 240) }
                if case let .failed(message) = job.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(message)
                }
            }

            Spacer()

            Text(job.state.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(job.state.tint)

            if job.state.isTerminal {
                if case .failed = job.state { Button("重试", action: retry).buttonStyle(.borderless) }
                if case .cancelled = job.state { Button("重试", action: retry).buttonStyle(.borderless) }
                if case let .completed(outputURL) = job.state, let outputURL {
                    Button("打开") {
                        NSWorkspace.shared.open(outputURL)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!FileManager.default.fileExists(atPath: outputURL.path))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中显示")
                }
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移除任务")
            } else {
                if case .paused = job.state { Button("恢复", action: resume).buttonStyle(.borderless) }
                else if job.state != .cancelling { Button("暂停", action: pause).buttonStyle(.borderless) }
                Button(action: cancel) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("取消任务")
                .disabled(job.state == .cancelling)
            }
        }
        .padding(.vertical, 8)
    }
}

private extension MediaJobState {
    var tint: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled, .cancelling, .paused: .orange
        }
    }
}
