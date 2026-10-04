import Foundation

struct CameraLogEvidence: Equatable {
    let profile: CameraColorProfile?
    let description: String

    static func read(_ stream: MediaStream?) -> CameraLogEvidence {
        let tags = stream?.metadata ?? [:]
        let candidates = tags.sorted(by: { $0.key < $1.key }).compactMap { key, value -> (CameraColorProfile, String)? in
            let key = key.lowercased()
            guard ["gamma", "color_mode", "colour_mode", "picture_profile", "capture_gamma", "log_profile", "transfer_function"].contains(where: { key == $0 || key.hasSuffix("." + $0) }),
                  let profile = CameraColorProfile.inferred(fromLUTName: value) else { return nil }
            return (profile, "\(key)=\(value)")
        }
        let modes = Set(candidates.map(\.0))
        if modes.count == 1, let match = candidates.first {
            return CameraLogEvidence(profile: match.0, description: "元数据：\(match.0.displayName)（高置信度；\(match.1)）")
        }
        if modes.count > 1 { return CameraLogEvidence(profile: nil, description: "Log 元数据互相冲突，请手动确认拍摄模式") }
        let camera = tags.filter { $0.key.lowercased().hasSuffix("model") || $0.key.lowercased().hasSuffix("make") }
            .sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
        return CameraLogEvidence(profile: nil, description: (camera.isEmpty ? "" : "\(camera) · ") + "未发现可靠的 Log 标记；相机型号和灰片外观不能确认拍摄曲线")
    }
}
