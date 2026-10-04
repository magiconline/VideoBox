import AppKit
import SwiftUI

struct MediaInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let probe: MediaProbe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("完整媒体信息").font(.title2.bold())
            Text(probe.sourceURL.lastPathComponent).textSelection(.enabled)
            Text("包含容器、轨道、色彩标签、章节及原始 HDR side data。帧级 HDR 信息仅采样文件开头 32 个包，不代表全片动态元数据均已扫描。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Button("复制全部") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }; Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 740, height: 660)
    }
    private var report: String {
        if let raw = probe.rawReport { return raw }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(probe)).flatMap { String(data: $0, encoding: .utf8) } ?? "媒体信息不可用"
    }
}
