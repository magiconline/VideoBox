import Foundation

struct ClipMedia: Codable, Equatable, Sendable {
    var duration: Double
    var video: MediaStream?
    var audio: [MediaStream]
    init(_ probe: MediaProbe) {
        duration = probe.duration ?? 0; video = probe.primaryVideoStream; audio = probe.streams.filter { $0.kind == .audio }
    }
}
struct ClipEffects: Codable, Equatable, Sendable {
    var exposure = 0.0
    var temperature = 0.0
    var tint = 0.0
    var isIdentity: Bool { exposure == 0 && temperature == 0 && tint == 0 }
    var filters: [String] {
        guard !isIdentity else { return [] }
        let gain = pow(2, exposure)
        let red = gain * pow(2, temperature * 0.25 + tint * 0.125)
        let green = gain * pow(2, -tint * 0.125)
        let blue = gain * pow(2, -temperature * 0.25 + tint * 0.125)
        return ["format=gbrpf32le", "colorchannelmixer=rr=\(red):gg=\(green):bb=\(blue)"]
    }
}
struct VisualPose: Codable, Equatable, Sendable {
    var x = 0.5
    var y = 0.5
    var scale = 1.0
    var opacity = 1.0
}
struct VisualKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var pose: VisualPose
    static func interpolate(_ values: [Self], at time: Double) -> VisualPose {
        let frames = values.sorted { $0.time < $1.time }
        guard let first = frames.first, let last = frames.last else { return VisualPose() }
        if time <= first.time { return first.pose }; if time >= last.time { return last.pose }
        let index = frames.firstIndex { $0.time > time }!
        let a = frames[index - 1], b = frames[index], fraction = (time - a.time) / max(0.000001, b.time - a.time)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * fraction }
        return VisualPose(x: mix(a.pose.x, b.pose.x), y: mix(a.pose.y, b.pose.y), scale: mix(a.pose.scale, b.pose.scale), opacity: mix(a.pose.opacity, b.pose.opacity))
    }
    static func expression(_ values: [Self], key: KeyPath<VisualPose, Double>, variable: String = "t") -> String {
        let frames = values.sorted { $0.time < $1.time }
        guard let first = frames.first else { return "1" }
        var expression = String(frames.last!.pose[keyPath: key])
        if frames.count > 1 {
            for i in stride(from: frames.count - 2, through: 0, by: -1) {
                let a = frames[i], b = frames[i + 1]
                let linear = "\(a.pose[keyPath: key])+(\(b.pose[keyPath: key] - a.pose[keyPath: key]))*(\(variable)-\(a.time))/\(max(0.000001, b.time - a.time))"
                expression = "if(lt(\(variable),\(b.time)),\(linear),\(expression))"
            }
        }
        return "if(lt(\(variable),\(first.time)),\(first.pose[keyPath: key]),\(expression))"
    }
}
struct ClipTransition: Codable, Equatable, Sendable {
    var duration = 0.5
    var style = "fade"
}
struct OverlayClip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var sourceURL: URL
    var media: ClipMedia
    var sourceRange: TimelineRange
    var startTime = 0.0
    var pose = VisualPose(x: 0.75, y: 0.25, scale: 0.3)
    var audioGain = 0.0
    var keyframes: [VisualKeyframe] = []
    var isAudioOnly: Bool { media.video == nil }
}
extension EditSettings {
    var validationIssues: [String] {
        var issues: [String] = []
        func rangeValid(_ range: TimelineRange, limit: Double) -> Bool {
            range.start.isFinite && range.duration.isFinite && range.start >= 0 && range.duration > 0 && range.end <= limit + 0.05
        }
        func poseValid(_ pose: VisualPose, scales: ClosedRange<Double>) -> Bool {
            [pose.x, pose.y, pose.scale, pose.opacity].allSatisfy(\.isFinite)
                && (0...1).contains(pose.x) && (0...1).contains(pose.y) && scales.contains(pose.scale) && (0...1).contains(pose.opacity)
        }
        func framesValid(_ frames: [VisualKeyframe], duration: Double, scales: ClosedRange<Double>) -> Bool {
            let times = frames.map(\.time)
            return frames.count <= 100 && Set(times).count == times.count && frames.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.time <= duration + 0.0001 && poseValid($0.pose, scales: scales) }
        }
        for clip in clips {
            if !rangeValid(clip.sourceRange, limit: clip.media?.duration ?? sourceDuration) || !clip.playbackRate.isFinite || !(0.1...8).contains(clip.playbackRate)
                || !clip.volume.isFinite || !(0...2).contains(clip.volume) || !clip.scale.isFinite || !(0.5...2).contains(clip.scale) { issues.append("片段时间、速度、缩放或音量无效") }
            if let crop = clip.transform.crop, ![crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite) || crop.x < 0 || crop.y < 0 || crop.width < 0.01 || crop.height < 0.01 || crop.x + crop.width > 1.00001 || crop.y + crop.height > 1.00001 { issues.append("片段裁剪范围无效") }
            if let effect = clip.effects, ![effect.exposure, effect.temperature, effect.tint].allSatisfy(\.isFinite) || !(-3...3).contains(effect.exposure) || !(-1...1).contains(effect.temperature) || !(-1...1).contains(effect.tint) { issues.append("调色参数无效") }
            if let transition = clip.transition, !transition.duration.isFinite || !(0...3).contains(transition.duration) || !["fade", "wipeleft", "wiperight"].contains(transition.style) { issues.append("转场参数无效") }
            if !framesValid(clip.keyframes ?? [], duration: clip.outputDuration, scales: 1...4) { issues.append("关键帧时间或位置无效") }
            if clip.sourceURL != nil && clip.media?.video == nil { issues.append("时间线素材缺少视频信息，请重新导入") }
        }
        for layer in overlayClips {
            if !rangeValid(layer.sourceRange, limit: layer.media.duration) || !layer.startTime.isFinite || layer.startTime < 0 || layer.startTime >= outputDuration
                || !layer.audioGain.isFinite || !(0...2).contains(layer.audioGain) || !poseValid(layer.pose, scales: 0.05...1)
                || !framesValid(layer.keyframes, duration: layer.sourceRange.duration, scales: 0.05...1) { issues.append("叠加轨道的时间、位置或音量无效") }
            if layer.media.video == nil && layer.media.audio.isEmpty { issues.append("叠加轨道缺少可用媒体信息") }
            if layer.keyframes.contains(where: { $0.pose.scale != layer.pose.scale }) { issues.append("叠加轨道目前仅支持位置和透明度动画，不支持宽度动画") }
        }
        if requiresRenderedPreview && (canvasWidth ?? 0 <= 0 || canvasHeight ?? 0 <= 0) { issues.append("多素材 / 特效需要有效的画布尺寸") }
        return Array(Set(issues)).sorted()
    }
    func compositionFrameRate(configuration: ExportConfiguration, source: MediaStream?) -> Double {
        if let fps = configuration.video.frameRate.value { return fps }
        if configuration.video.frameRate == .custom { return min(240, max(1, configuration.video.customFrameRate)) }
        let parts = (source?.averageFrameRate ?? "").split(separator: "/").compactMap { Double($0) }
        let fps = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : parts.first ?? 30
        return fps.isFinite && fps > 0 ? min(240, fps) : 30
    }
    mutating func trimSelected(start: Double, end: Double) -> Bool {
        guard let index = selectedClipIndex, start.isFinite, end.isFinite, start >= 0, end > start,
              end <= (clips[index].media?.duration ?? sourceDuration) + 0.00001 else { return false }
        let old = clips[index]
        let shift = (start - old.sourceRange.start) / old.playbackRate
        if let frames = old.keyframes, !frames.isEmpty {
            clips[index].keyframes = [VisualKeyframe(time: 0, pose: VisualKeyframe.interpolate(frames, at: shift))]
                + frames.filter { $0.time > shift && $0.time < shift + (end - start) / old.playbackRate }
                    .map { VisualKeyframe(time: $0.time - shift, pose: $0.pose) }
        }
        clips[index].sourceRange = TimelineRange(start: start, duration: end - start)
        return true
    }
}
