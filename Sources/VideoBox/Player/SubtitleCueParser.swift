import Foundation

struct SubtitleCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

enum SubtitleCueParser {
    static func parse(contentsOf url: URL) throws -> [SubtitleCue] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    static func parse(_ contents: String) -> [SubtitleCue] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized
            .components(separatedBy: "\n\n")
            .compactMap(parseBlock)
            .sorted { lhs, rhs in
                lhs.startTime == rhs.startTime
                    ? lhs.endTime < rhs.endTime
                    : lhs.startTime < rhs.startTime
            }
    }

    private static func parseBlock(_ block: String) -> SubtitleCue? {
        let lines = block.components(separatedBy: "\n")
        guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
            return nil
        }
        let timingParts = lines[timingIndex].components(separatedBy: "-->")
        guard timingParts.count == 2,
              let startTime = parseTimestamp(timingParts[0]),
              let endTime = parseTimestamp(
                  timingParts[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
              ),
              endTime > startTime else { return nil }

        let text = lines
            .dropFirst(timingIndex + 1)
            .joined(separator: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]+\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return SubtitleCue(startTime: startTime, endTime: endTime, text: text)
    }

    private static func parseTimestamp(_ input: String) -> TimeInterval? {
        let parts = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}
