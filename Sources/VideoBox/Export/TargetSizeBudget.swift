import Foundation

/// Budget all selected audio tracks, and reserve space for muxing and subtitles.
struct TargetSizeBudget {
    let audioKbps: Int
    let videoKbps: Int
    let blockers: [String]

    init(configuration: ExportConfiguration, duration: Double?) {
        let tracks = configuration.trackSettings.filter { $0.isIncluded && $0.kind == .audio }
        var reasons: [String] = []
        var audio = 0
        if configuration.audio.codec != .none {
            if configuration.trackSettings.isEmpty {
                if configuration.audio.codec.usesBitrate { audio = configuration.audio.bitrateKbps }
                else { reasons.append("目标体积需要先读取全部音轨信息") }
            }
            for track in tracks {
                switch configuration.audio.codec {
                case .none: break
                case .copy:
                    if let rate = track.sourceStream?.bitRate, rate > 0 { audio += Int((rate + 999) / 1_000) }
                    else { reasons.append("复制音轨的码率未知；目标体积模式请改选 AAC 等固定码率音频") }
                case .pcm, .flac:
                    let samples = configuration.audio.sampleRate == .source ? (track.sampleRate ?? 48_000) : configuration.audio.sampleRate.rawValue
                    let channels = configuration.audio.channels == .source ? (track.channels ?? 2) : configuration.audio.channels.rawValue
                    // FLAC is variable-size: conservatively reserve uncompressed 24-bit PCM.
                    audio += samples * channels * (configuration.audio.codec == .pcm ? 16 : 24) / 1_000
                default: audio += max(32, configuration.audio.bitrateKbps)
                }
            }
        }
        audioKbps = audio
        if let duration, duration.isFinite, duration > 0 {
            let availableBits = Double(max(1, configuration.video.targetSizeMB)) * 1_048_576 * 8 * 0.97 - 65_536 * 8
            videoKbps = max(0, Int(availableBits / duration / 1_000) - audio)
            if videoKbps < 100 { reasons.append("目标体积不足以容纳音轨和视频，请增加体积、降低音频码率或移除音轨") }
        } else {
            videoKbps = configuration.video.averageBitrateKbps
            reasons.append("目标体积需要有效片长，请等待视频读取完成")
        }
        if configuration.trackSettings.filter({ $0.isIncluded && $0.kind == .video }).count > 1 {
            reasons.append("目标体积模式请只保留一条视频轨道")
        }
        if configuration.includeAttachments && configuration.trackSettings.contains(where: { $0.isIncluded && $0.kind == .attachment }) {
            reasons.append("目标体积模式请关闭附件保留（附件体积不可忽略）")
        }
        if configuration.includeDataStreams && configuration.trackSettings.contains(where: { $0.isIncluded && $0.kind == .data }) {
            reasons.append("目标体积模式请关闭数据轨道保留（数据体积未计入音视频预算）")
        }
        blockers = Array(Set(reasons)).sorted()
    }
}
