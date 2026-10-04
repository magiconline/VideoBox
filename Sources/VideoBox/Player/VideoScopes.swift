import CoreGraphics
import Foundation

struct VideoScopeData: Sendable {
    var histograms: [[Int]]
    var waveform: [[Int]]
    var sampleCount: Int
    static func measure(_ image: CGImage) -> VideoScopeData? {
        let width = 256, height = max(1, Int(256.0 * Double(image.height) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drew else { return nil }
        var histogram = Array(repeating: Array(repeating: 0, count: 256), count: 4)
        var waveform = Array(repeating: Array(repeating: 0, count: 256), count: width)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let luma = min(255, max(0, Int(0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b))))
            histogram[0][r] += 1; histogram[1][g] += 1; histogram[2][b] += 1; histogram[3][luma] += 1
            waveform[x][luma] += 1
        } }
        return VideoScopeData(histograms: histogram, waveform: waveform, sampleCount: width * height)
    }
}
