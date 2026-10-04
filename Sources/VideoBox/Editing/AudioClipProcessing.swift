import Foundation

enum AudioClipProcessing {
    static func filters(_ clip: EditSegment) -> [String] {
        var filters = ["atrim=start=\(decimal(clip.sourceRange.start)):duration=\(decimal(clip.sourceRange.duration))", "asetpts=PTS-STARTPTS"]
        var rate = min(100, max(0.01, clip.playbackRate))
        while rate < 0.5 { filters.append("atempo=0.500"); rate /= 0.5 }
        while rate > 2 { filters.append("atempo=2.000"); rate /= 2 }
        if abs(rate - 1) > 0.000_1 { filters.append("atempo=\(decimal(rate))") }
        if abs(clip.volume - 1) > 0.000_1 { filters.append("volume=\(decimal(clip.volume))") }
        filters += ["apad=whole_dur=\(decimal(clip.outputDuration))", "atrim=duration=\(decimal(clip.outputDuration))"]
        return filters
    }
    private static func decimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
