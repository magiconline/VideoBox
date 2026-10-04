import Foundation

struct VideoColorSpec: Equatable, Sendable {
    var primaries: String
    var transfer: String
    var matrix: String
    var range: String
    var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(transfer) }

    init(space: OutputColorSpace, range: String = "limited") {
        primaries = space.ffmpegPrimaries ?? "bt709"
        transfer = space.ffmpegTransfer ?? "bt709"
        matrix = space.ffmpegMatrix ?? "bt709"
        self.range = range
    }
    init?(stream: MediaStream?) {
        guard let stream, let primaries = stream.colorPrimaries, let transfer = stream.colorTransfer,
              let matrix = stream.colorSpace,
              Self.primaries.contains(primaries), Self.transfers.contains(transfer), Self.matrices.contains(matrix),
              let range = Self.range(stream.colorRange) else { return nil }
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix; self.range = range
    }
    static func range(_ name: String?) -> String? {
        switch name?.lowercased() {
        case "tv", "limited", "mpeg": "limited"
        case "pc", "full", "jpeg": "full"
        default: nil
        }
    }
    static let primaries: Set<String> = ["bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "bt2020", "smpte431", "smpte432", "film"]
    static let transfers: Set<String> = ["bt709", "gamma22", "gamma28", "smpte170m", "smpte240m", "linear", "iec61966-2-1", "bt2020-10", "bt2020-12", "smpte2084", "arib-std-b67"]
    static let matrices: Set<String> = ["gbr", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "bt2020nc", "bt2020c"]
}

/// A real pixel conversion, not just output tags. Both export and rendered
/// preview call this plan. Camera-specific Log curves require a matching LUT.
struct ColorConversionPlan: Sendable {
    let settings: ColorExportSettings
    let source: MediaStream?
    let input: VideoColorSpec?
    let output: VideoColorSpec?
    let blockers: [String]
    var needsConversion: Bool { settings.activeLUTFile != nil || settings.outputColorSpace != .source || settings.outputRange != .source }

    init(settings: ColorExportSettings, source: MediaStream?) {
        self.settings = settings; self.source = source
        let detected = CameraLogEvidence.read(source).profile
        let declared = settings.inputProfile == .automatic ? detected : settings.inputProfile
        let input: VideoColorSpec? = settings.inputColorSpace != .source
            ? VideoColorSpec(space: settings.inputColorSpace, range: VideoColorSpec.range(source?.colorRange) ?? "limited")
            : (declared == .rec709 ? VideoColorSpec(space: .rec709SDR) : VideoColorSpec(stream: source))
        self.input = input
        let afterLUT = settings.activeLUTFile != nil ? VideoColorSpec(space: settings.lutOutputColorSpace) : input
        let range = settings.outputRange.ffmpegFilterValue ?? afterLUT?.range ?? "limited"
        if settings.outputColorSpace == .source {
            var target = afterLUT
            target?.range = range
            output = target
        } else { output = VideoColorSpec(space: settings.outputColorSpace, range: range) }
        var reasons: [String] = []
        if settings.activeLUTFile != nil {
            if let name = settings.activeLUTFile?.displayName,
               let expected = CameraColorProfile.inferred(fromLUTName: name), let declared, declared != expected {
                reasons.append("素材声明为 \(declared.displayName)，LUT 文件名指向 \(expected.displayName)；请核对输入曲线")
            }
            if declared == nil && !settings.confirmsLUTCompatibility {
                reasons.append("无法确认素材的 Log 曲线，请手动声明或勾选已核对 LUT 匹配")
            }
            if settings.lutOutputColorSpace == .source { reasons.append("请明确声明 LUT 自身的输出色彩空间") }
        } else if settings.outputColorSpace != .source || settings.outputRange != .source {
            if let declared, declared != .rec709 {
                reasons.append("\(declared.displayName) 需要匹配的还原 LUT，不能用通用色彩转换代替")
            } else if input == nil {
                reasons.append("输入色彩标签不完整或不受支持，请先确认输入色彩空间；不会猜测 HDR 曲线")
            }
        }
        if source?.hasDynamicHDR == true && !settings.discardsDynamicHDR {
            reasons.append("动态 HDR 仅支持原样快速导出；处理画面前请明确允许移除动态元数据")
        }
        if source?.hdrDescription == "Dolby Vision", settings.discardsDynamicHDR,
           (source?.dolbyVisionProfile != 8 || ![1, 2, 4].contains(source?.dolbyVisionCompatibilityID ?? -1)) {
            reasons.append("仅能转换已标明兼容底层的 Dolby Vision 8.1/8.2/8.4；其他或未知 Profile 请原样快速导出")
        }
        if !settings.hdrPeakNits.isFinite || !(100...10_000).contains(settings.hdrPeakNits) {
            reasons.append("HDR 峰值亮度应在 100–10000 nit 之间")
        }
        blockers = reasons
    }

    func filters(lutFilters: [String]? = nil) -> [String] {
        guard needsConversion || settings.discardsDynamicHDR else { return [] }
        var result: [String] = []
        var from = input
        if let lut = settings.activeLUTFile {
            let matrix = input?.matrix ?? source?.colorSpace.flatMap { VideoColorSpec.matrices.contains($0) ? $0 : nil } ?? "bt709"
            let range = input?.range ?? VideoColorSpec.range(source?.colorRange) ?? "limited"
            result += ["scale=\(matrix == "gbr" ? "" : "in_color_matrix=\(matrix):")in_range=\(range):flags=accurate_rnd", "format=gbrpf32le"]
            result += lutFilters ?? ["lut3d=file='\(FFmpegFilterPath.escape(lut.url.path))':interp=trilinear"]
            from = VideoColorSpec(space: settings.lutOutputColorSpace, range: "full")
            from?.matrix = "gbr"
        }
        if let from, let output, needsConversion {
            let inputOptions = "pin=\(from.primaries):tin=\(from.transfer):min=\(from.matrix):rin=\(from.range)"
            if from.isHDR && !output.isHDR {
                result += ["zscale=\(inputOptions):p=\(from.primaries):m=gbr:r=full:t=linear:npl=100", "format=gbrpf32le",
                           "zscale=p=\(output.primaries)",
                           "tonemap=tonemap=hable:desat=2:peak=\(settings.hdrPeakNits / 100)",
                           "zscale=p=\(output.primaries):t=\(output.transfer):m=\(output.matrix):r=\(output.range):npl=100:d=error_diffusion"]
            } else {
                result += ["zscale=\(inputOptions):p=\(output.primaries):t=\(output.transfer):m=\(output.matrix):r=\(output.range):npl=100:d=error_diffusion"]
            }
            result.append("setparams=range=\(output.range):color_primaries=\(output.primaries):color_trc=\(output.transfer):colorspace=\(output.matrix)")
        }
        // Source mastering values are not true of converted pixels. Never leave
        // stale HDR SEI on an SDR render, nor dynamic metadata on edited frames.
        if needsConversion || settings.discardsDynamicHDR {
            result += ["MASTERING_DISPLAY_METADATA", "CONTENT_LIGHT_LEVEL", "DYNAMIC_HDR_PLUS", "DOVI_RPU_BUFFER", "DOVI_METADATA", "DYNAMIC_HDR_VIVID"].map { "sidedata=mode=delete:type=\($0)" }
        }
        return result
    }

    var outputArguments: [String] {
        guard needsConversion, let output else { return [] }
        return ["-color_primaries", output.primaries, "-color_trc", output.transfer, "-colorspace", output.matrix,
                "-color_range", output.range == "full" ? "pc" : "tv"]
    }
}
