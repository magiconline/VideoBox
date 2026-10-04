import Foundation

struct LUTFileReference: Codable, Equatable, Sendable {
    var url: URL
    var displayName: String

    init(url: URL, displayName: String? = nil) {
        self.url = url
        self.displayName = displayName ?? url.deletingPathExtension().lastPathComponent
    }
}

struct ColorExportSettings: Codable, Equatable, Sendable {
    var isLUTEnabled = false
    var lutFile: LUTFileReference?
    var inputProfile: CameraColorProfile = .automatic
    var outputColorSpace: OutputColorSpace = .source
    var outputRange: OutputColorRange = .source
    var inputColorSpace: OutputColorSpace = .source
    var lutOutputColorSpace: OutputColorSpace = .rec709SDR
    var confirmsLUTCompatibility = false
    var discardsDynamicHDR = false
    var hdrPeakNits = 1_000.0

    var activeLUTFile: LUTFileReference? {
        isLUTEnabled ? lutFile : nil
    }

    var requiresVideoProcessing: Bool {
        activeLUTFile != nil || outputColorSpace != .source || outputRange != .source
    }
}

enum CameraColorProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case dLogM
    case dLog
    case sLog3
    case cLog2
    case cLog3
    case vLog
    case fLog2
    case logC3
    case logC4
    case blackmagicFilm
    case rec709

    var displayName: String {
        switch self {
        case .automatic: "自动读取元数据 / 未知"
        case .dLogM: "D-Log M"
        case .dLog: "D-Log"
        case .sLog3: "S-Log3"
        case .cLog2: "Canon Log 2"
        case .cLog3: "Canon Log 3"
        case .vLog: "V-Log"
        case .fLog2: "F-Log2"
        case .logC3: "ARRI LogC3"
        case .logC4: "ARRI LogC4"
        case .blackmagicFilm: "Blackmagic Film"
        case .rec709: "Rec.709"
        }
    }

    static func inferred(fromLUTName name: String) -> CameraColorProfile? {
        let normalized = name.lowercased()
        if normalized.contains("d-log m") || normalized.contains("dlog m") {
            return .dLogM
        }
        if normalized.contains("d-log") || normalized.contains("dlog") {
            return .dLog
        }
        if normalized.contains("s-log3") || normalized.contains("slog3") {
            return .sLog3
        }
        if normalized.contains("c-log2") || normalized.contains("clog2") {
            return .cLog2
        }
        if normalized.contains("c-log3") || normalized.contains("clog3") {
            return .cLog3
        }
        if normalized.contains("v-log") || normalized.contains("vlog") {
            return .vLog
        }
        if normalized.contains("f-log2") || normalized.contains("flog2") {
            return .fLog2
        }
        if normalized.contains("logc4") || normalized.contains("log c4") {
            return .logC4
        }
        if normalized.contains("logc3") || normalized.contains("log c3") {
            return .logC3
        }
        if normalized.contains("blackmagic") && normalized.contains("film") {
            return .blackmagicFilm
        }
        return nil
    }
}

enum OutputColorSpace: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case rec709SDR
    case displayP3SDR
    case rec2020HLG
    case rec2020PQ

    var displayName: String {
        switch self {
        case .source: "保持源视频"
        case .rec709SDR: "Rec.709 SDR"
        case .displayP3SDR: "Display P3 SDR"
        case .rec2020HLG: "Rec.2020 HLG"
        case .rec2020PQ: "Rec.2020 PQ"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .source: "原始"
        case .rec709SDR: "Rec.709"
        case .displayP3SDR: "Display P3"
        case .rec2020HLG: "HLG"
        case .rec2020PQ: "PQ"
        }
    }

    var ffmpegPrimaries: String? {
        switch self {
        case .source: nil
        case .rec709SDR: "bt709"
        case .displayP3SDR: "smpte432"
        case .rec2020HLG, .rec2020PQ: "bt2020"
        }
    }

    var ffmpegTransfer: String? {
        switch self {
        case .source: nil
        case .rec709SDR: "bt709"
        case .displayP3SDR: "iec61966-2-1"
        case .rec2020HLG: "arib-std-b67"
        case .rec2020PQ: "smpte2084"
        }
    }

    var ffmpegMatrix: String? {
        switch self {
        case .source: nil
        case .rec709SDR, .displayP3SDR: "bt709"
        case .rec2020HLG, .rec2020PQ: "bt2020nc"
        }
    }

    func matches(_ stream: MediaStream?, declaredInput: CameraColorProfile) -> Bool {
        guard self != .source else { return true }
        guard declaredInput == .automatic || declaredInput == .rec709 else { return false }
        guard let stream else { return false }

        return stream.colorPrimaries?.lowercased() == ffmpegPrimaries
            && stream.colorTransfer?.lowercased() == ffmpegTransfer
            && stream.colorSpace?.lowercased() == ffmpegMatrix
    }
}

enum OutputColorRange: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case limited
    case full

    var displayName: String {
        switch self {
        case .source: "保持源视频"
        case .limited: "Limited"
        case .full: "Full"
        }
    }

    var ffmpegFilterValue: String? {
        switch self {
        case .source: nil
        case .limited: "limited"
        case .full: "full"
        }
    }

    var ffmpegOptionValue: String? {
        switch self {
        case .source: nil
        case .limited: "tv"
        case .full: "pc"
        }
    }

    func matches(_ stream: MediaStream?) -> Bool {
        guard self != .source else { return true }
        let source = stream?.colorRange?.lowercased()
        switch self {
        case .source: return true
        case .limited: return source == "tv" || source == "limited" || source == "mpeg"
        case .full: return source == "pc" || source == "full" || source == "jpeg"
        }
    }
}

enum OutputBitDepth: Int, CaseIterable, Hashable, Sendable {
    case eight = 8
    case ten = 10
    case twelve = 12

    var displayName: String { "\(rawValue)-bit" }
}

enum ChromaSubsampling: String, CaseIterable, Hashable, Sendable {
    case fourTwoZero
    case fourTwoTwo
    case fourFourFour

    var displayName: String {
        switch self {
        case .fourTwoZero: "4:2:0"
        case .fourTwoTwo: "4:2:2"
        case .fourFourFour: "4:4:4"
        }
    }
}

struct QuickExportEligibility {
    static func blockers(
        configuration: ExportConfiguration,
        editing: EditSettings,
        sourceVideo: MediaStream?
    ) -> [String] {
        var quickConfiguration = configuration
        quickConfiguration.mode = .streamCopy
        return ExportPlan(configuration: quickConfiguration, editing: editing, sourceVideo: sourceVideo).blockers
    }
}


enum LUT3DError: LocalizedError, Equatable {
    case unreadableFile
    case missingDimension
    case invalidDimension
    case invalidDataLine(String)
    case invalidEntryCount(expected: Int, actual: Int)
    case invalidDomain

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "无法读取 LUT 文件。"
        case .missingDimension:
            "这个文件没有声明 LUT_1D_SIZE 或 LUT_3D_SIZE。"
        case .invalidDimension:
            "LUT 的网格尺寸无效。"
        case let .invalidDataLine(line):
            "LUT 中包含无法识别的数据：\(line)"
        case let .invalidEntryCount(expected, actual):
            "LUT 数据不完整：应有 \(expected) 个色彩点，实际为 \(actual) 个。"
        case .invalidDomain:
            "LUT 的输入范围无效。"
        }
    }
}
