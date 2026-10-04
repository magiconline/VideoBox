import Foundation

struct MediaProbe: Codable, Equatable, Sendable {
    let sourceURL: URL
    let formatName: String?
    let duration: TimeInterval?
    let sizeInBytes: Int64?
    let bitRate: Int64?
    let streams: [MediaStream]
    let metadata: [String: String]
    let chapters: [MediaChapter]
    var rawReport: String?

    init(
        sourceURL: URL,
        formatName: String?,
        duration: TimeInterval?,
        sizeInBytes: Int64?,
        streams: [MediaStream],
        metadata: [String: String] = [:],
        bitRate: Int64? = nil,
        chapters: [MediaChapter] = []
    ) {
        self.sourceURL = sourceURL
        self.formatName = formatName
        self.duration = duration
        self.sizeInBytes = sizeInBytes
        self.bitRate = bitRate
        self.streams = streams
        self.metadata = metadata
        self.chapters = chapters
    }

    var primaryVideoStream: MediaStream? {
        streams.first { $0.kind == .video && !$0.isAttachedPicture }
            ?? streams.first { $0.kind == .video }
    }

    var averageBitRate: Int64? {
        if let streamBitRate = primaryVideoStream?.bitRate, streamBitRate > 0 {
            return streamBitRate
        }
        if let bitRate, bitRate > 0 { return bitRate }
        guard let sizeInBytes, let duration, duration > 0 else { return nil }
        return Int64((Double(sizeInBytes) * 8) / duration)
    }

    var coverStreams: [MediaStream] {
        streams.filter(\.isAttachedPicture)
    }
}

struct MediaStream: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let kind: MediaStreamKind
    let codecName: String?
    let codecProfile: String?
    let width: Int?
    let height: Int?
    let averageFrameRate: String?
    let sampleRate: Int?
    let channels: Int?
    let language: String?
    let title: String?
    let isDefault: Bool
    let bitRate: Int64?
    let pixelFormat: String?
    let bitsPerRawSample: Int?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let colorRange: String?
    let chromaLocation: String?
    let isAttachedPicture: Bool
    let sideDataTypes: [String]
    var metadata: [String: String] = [:]
    var dolbyVisionProfile: Int?
    var dolbyVisionCompatibilityID: Int?

    var id: Int { index }

    init(
        index: Int,
        kind: MediaStreamKind,
        codecName: String?,
        codecProfile: String? = nil,
        width: Int?,
        height: Int?,
        averageFrameRate: String? = nil,
        sampleRate: Int?,
        channels: Int?,
        language: String?,
        title: String? = nil,
        isDefault: Bool = false,
        bitRate: Int64? = nil,
        pixelFormat: String? = nil,
        bitsPerRawSample: Int? = nil,
        colorSpace: String? = nil,
        colorTransfer: String? = nil,
        colorPrimaries: String? = nil,
        colorRange: String? = nil,
        chromaLocation: String? = nil,
        isAttachedPicture: Bool = false,
        sideDataTypes: [String] = []
    ) {
        self.index = index
        self.kind = kind
        self.codecName = codecName
        self.codecProfile = codecProfile
        self.width = width
        self.height = height
        self.averageFrameRate = averageFrameRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.bitRate = bitRate
        self.pixelFormat = pixelFormat
        self.bitsPerRawSample = bitsPerRawSample
        self.colorSpace = colorSpace
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.colorRange = colorRange
        self.chromaLocation = chromaLocation
        self.isAttachedPicture = isAttachedPicture
        self.sideDataTypes = sideDataTypes
    }

    var bitDepth: Int? {
        if let bitsPerRawSample, bitsPerRawSample > 0 { return bitsPerRawSample }
        guard let pixelFormat = pixelFormat?.lowercased() else { return nil }
        for depth in [10, 12, 16] where pixelFormat.hasPrefix("p0\(depth)")
            || pixelFormat.hasPrefix("p2\(depth)") || pixelFormat.hasPrefix("p4\(depth)") {
            return depth
        }
        if pixelFormat.contains("rgb48") || pixelFormat.contains("bgr48")
            || pixelFormat.contains("rgba64") || pixelFormat.contains("bgra64") { return 16 }
        if pixelFormat.hasPrefix("x2rgb10") || pixelFormat.hasPrefix("x2bgr10") { return 10 }
        for depth in [16, 14, 12, 10, 9] where pixelFormat.contains("p\(depth)") {
            return depth
        }
        if pixelFormat.hasPrefix("gray16") || pixelFormat.hasPrefix("ya16") { return 16 }
        if pixelFormat.contains("f32") { return 32 }
        return kind == .video && pixelFormat != "unknown" ? 8 : nil
    }

    var frameRate: Double? {
        guard let averageFrameRate else { return nil }
        let components = averageFrameRate.split(separator: "/", maxSplits: 1)
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            return numerator / denominator
        }
        return Double(averageFrameRate)
    }

    var chromaSubsampling: ChromaSubsampling? {
        guard let pixelFormat = pixelFormat?.lowercased() else { return nil }
        if pixelFormat.contains("420") || pixelFormat.hasPrefix("p0") || ["nv12", "nv21"].contains(pixelFormat) { return .fourTwoZero }
        if pixelFormat.contains("422") || pixelFormat.hasPrefix("p2") || ["nv16", "nv20le"].contains(pixelFormat) { return .fourTwoTwo }
        if pixelFormat.contains("444") || pixelFormat.hasPrefix("p4") || pixelFormat.hasPrefix("gbr")
            || pixelFormat.contains("rgb") || pixelFormat.contains("bgr") {
            return .fourFourFour
        }
        return nil
    }

    var hdrDescription: String {
        let transfer = colorTransfer?.lowercased() ?? ""
        let sideData = sideDataTypes.joined(separator: " ").lowercased()
        if sideData.contains("dolby vision") || sideData.contains("dovi") {
            return "Dolby Vision"
        }
        if sideData.contains("hdr10+") || sideData.contains("dynamic hdr") {
            return "HDR10+"
        }
        if transfer.contains("smpte2084") || transfer == "pq" {
            return sideData.contains("mastering display") ? "HDR10 / PQ" : "PQ（静态 HDR 信息未标记）"
        }
        if transfer.contains("arib-std-b67") || transfer == "hlg" {
            return "HLG"
        }
        if ["bt709", "gamma22", "gamma28", "smpte170m", "smpte240m", "iec61966-2-1", "bt2020-10", "bt2020-12"].contains(transfer) {
            return "SDR"
        }
        return "未标记"
    }

    var hasDynamicHDR: Bool { ["Dolby Vision", "HDR10+"].contains(hdrDescription) }
    var isHDR: Bool { hasDynamicHDR || ["smpte2084", "pq", "arib-std-b67", "hlg"].contains(colorTransfer?.lowercased() ?? "") }
}

struct MediaChapter: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let title: String?

    var duration: TimeInterval { max(0, endTime - startTime) }
}

enum MediaStreamKind: String, Codable, Equatable, Sendable {
    case video
    case audio
    case subtitle
    case attachment
    case data
    case unknown

    var shortDisplayName: String {
        switch self {
        case .video: "视频"
        case .audio: "音频"
        case .subtitle: "字幕"
        case .attachment: "附件"
        case .data: "数据"
        case .unknown: "轨道"
        }
    }
}
