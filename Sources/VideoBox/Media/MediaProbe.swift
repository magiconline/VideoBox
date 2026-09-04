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
    let width: Int?
    let height: Int?
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
    let isAttachedPicture: Bool
    let sideDataTypes: [String]

    var id: Int { index }

    init(
        index: Int,
        kind: MediaStreamKind,
        codecName: String?,
        width: Int?,
        height: Int?,
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
        isAttachedPicture: Bool = false,
        sideDataTypes: [String] = []
    ) {
        self.index = index
        self.kind = kind
        self.codecName = codecName
        self.width = width
        self.height = height
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
        self.isAttachedPicture = isAttachedPicture
        self.sideDataTypes = sideDataTypes
    }

    var bitDepth: Int? {
        if let bitsPerRawSample, bitsPerRawSample > 0 { return bitsPerRawSample }
        guard let pixelFormat = pixelFormat?.lowercased() else { return nil }
        for depth in [16, 14, 12, 10, 9] where pixelFormat.contains("p\(depth)") {
            return depth
        }
        return kind == .video ? 8 : nil
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
            return "HDR10 / PQ"
        }
        if transfer.contains("arib-std-b67") || transfer == "hlg" {
            return "HLG"
        }
        return "SDR"
    }
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
}
