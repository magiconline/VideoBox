import SwiftUI

struct JobQueueView: View {
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
                        }
                    }
                }
            }
        }
        .navigationTitle("任务队列")
        .toolbar {
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.sourceURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(job.request.exportMode.displayName) · \(job.request.destinationURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(job.state.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(job.state.tint)

            if job.state.isTerminal {
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移除任务")
            } else {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("取消任务")
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
        case .cancelled: .orange
        }
    }
}
