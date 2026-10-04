import Foundation

/// Adobe/Resolve .cube: 1D, 3D, or a 1D shaper followed by a 3D table.
/// Stages stay separate; baking a shaper into a small cube would lose precision.
struct CubeLUT: Equatable, Sendable {
    struct Stage: Equatable, Sendable {
        let size: Int
        let is1D: Bool
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let values: [SIMD3<Float>]

        var rgbaData: Data {
            values.flatMap { [$0.x, $0.y, $0.z, Float(1)] }.withUnsafeBytes { Data($0) }
        }
        var normalizedCube: String {
            ([is1D ? "LUT_1D_SIZE \(size)" : "LUT_3D_SIZE \(size)"]
                + values.map { "\($0.x) \($0.y) \($0.z)" }).joined(separator: "\n") + "\n"
        }
        var normalizationFilter: String? {
            guard minimum != SIMD3<Float>(repeating: 0) || maximum != SIMD3<Float>(repeating: 1) else { return nil }
            let expressions = ["r", "g", "b"].enumerated().map { i, channel in
                "\(channel)='clip((\(channel)(X,Y)-(\(minimum[i])))/(\(maximum[i] - minimum[i])),0,1)'"
            }
            return "geq=" + expressions.joined(separator: ":")
        }
    }
    let title: String?
    let stages: [Stage]

    static func load(from url: URL) throws -> CubeLUT {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 160_000_000 else { throw LUT3DError.invalidDimension }
        let contents = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        guard let contents else { throw LUT3DError.unreadableFile }
        return try parse(contents)
    }

    static func parse(_ contents: String) throws -> CubeLUT {
        var title: String?
        var oneSize: Int?
        var threeSize: Int?
        var minimum = SIMD3<Float>(repeating: 0)
        var maximum = SIMD3<Float>(repeating: 1)
        var oneRange: (SIMD3<Float>, SIMD3<Float>)?
        var threeRange: (SIMD3<Float>, SIMD3<Float>)?
        var values: [SIMD3<Float>] = []
        func triple(_ fields: [Substring]) throws -> SIMD3<Float> {
            guard fields.count == 3, let a = Float(fields[0]), let b = Float(fields[1]), let c = Float(fields[2]),
                  a.isFinite, b.isFinite, c.isFinite else { throw LUT3DError.invalidDomain }
            return SIMD3(a, b, c)
        }
        for raw in contents.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first else { continue }
            switch key.uppercased() {
            case "TITLE": title = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_1D_SIZE", "LUT_3D_SIZE":
                let is1D = key.uppercased() == "LUT_1D_SIZE"
                guard values.isEmpty, fields.count == 2, let size = Int(fields[1]),
                      (2...(is1D ? 65_536 : 128)).contains(size),
                      (is1D ? oneSize : threeSize) == nil else { throw LUT3DError.invalidDimension }
                if is1D { oneSize = size } else { threeSize = size }
            case "DOMAIN_MIN": minimum = try triple(Array(fields.dropFirst()))
            case "DOMAIN_MAX": maximum = try triple(Array(fields.dropFirst()))
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                guard fields.count == 3, let low = Float(fields[1]), let high = Float(fields[2]),
                      low.isFinite, high.isFinite, high > low else { throw LUT3DError.invalidDomain }
                let range = (SIMD3<Float>(repeating: low), SIMD3<Float>(repeating: high))
                if key.uppercased() == "LUT_1D_INPUT_RANGE" { oneRange = range } else { threeRange = range }
            default:
                do { values.append(try triple(fields)) }
                catch { throw LUT3DError.invalidDataLine(line) }
                guard values.count <= 128 * 128 * 128 + 65_536 else { throw LUT3DError.invalidDimension }
            }
        }
        guard oneSize != nil || threeSize != nil else { throw LUT3DError.missingDimension }
        let count1 = oneSize ?? 0
        let count3 = threeSize.map { $0 * $0 * $0 } ?? 0
        guard values.count == count1 + count3 else {
            throw LUT3DError.invalidEntryCount(expected: count1 + count3, actual: values.count)
        }
        var stages: [Stage] = []
        if let oneSize {
            let range = oneRange ?? (minimum, maximum)
            stages.append(Stage(size: oneSize, is1D: true, minimum: range.0, maximum: range.1, values: Array(values.prefix(count1))))
        }
        if let threeSize {
            let range = threeRange ?? (oneSize == nil ? (minimum, maximum) : (SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)))
            stages.append(Stage(size: threeSize, is1D: false, minimum: range.0, maximum: range.1, values: Array(values.suffix(count3))))
        }
        if stages.contains(where: { stage in (0..<3).contains(where: { stage.maximum[$0] <= stage.minimum[$0] }) }) {
            throw LUT3DError.invalidDomain
        }
        return CubeLUT(title: title, stages: stages)
    }

    func prepareFilters(in directory: URL) throws -> [String] {
        var filters = ["format=gbrpf32le"]
        for (index, stage) in stages.enumerated() {
            let url = directory.appendingPathComponent("lut-stage-\(index).cube")
            try stage.normalizedCube.write(to: url, atomically: true, encoding: .utf8)
            if let normalize = stage.normalizationFilter { filters.append(normalize) }
            filters.append("\(stage.is1D ? "lut1d" : "lut3d")=file='\(FFmpegFilterPath.escape(url.path))':interp=\(stage.is1D ? "linear" : "trilinear")")
        }
        return filters
    }
}

enum FFmpegFilterPath {
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\\\\\''")
            .replacingOccurrences(of: ":", with: "\\:")
    }
}
