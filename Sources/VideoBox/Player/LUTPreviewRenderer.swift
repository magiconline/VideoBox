import CoreImage
import Foundation

/// Only the divider geometry is shared with the render callback. Both sides use
/// the same decoded image from the same composition request, never two players.
final class LUTComparisonState: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = 0.5
    private var viewport = CGSize(width: 16, height: 9)
    private var editing = EditSettings()

    func update(fraction: Double? = nil, viewport: CGSize? = nil, editing: EditSettings? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let fraction { self.fraction = min(1, max(0, fraction)) }
        if let viewport { self.viewport = viewport }
        if let editing { self.editing = editing }
    }

    func originalRegion(extent: CGRect, outputTime: Double) -> CGRect {
        lock.lock()
        let fraction = fraction, viewport = viewport, editing = editing
        lock.unlock()
        let clip = editing.location(atOutputTime: outputTime).map { editing.clips[$0.clipIndex] }
        let turns = ((clip?.transform.quarterTurnsClockwise ?? 0) % 4 + 4) % 4
        let preSize = turns.isMultiple(of: 2) ? viewport : CGSize(width: viewport.height, height: viewport.width)
        let scale = min(preSize.width / max(1, extent.width), preSize.height / max(1, extent.height)) * (clip?.scale ?? 1)
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: -Double(turns) * .pi / 2))
            .concatenating(CGAffineTransform(scaleX: clip?.transform.isFlippedHorizontally == true ? -1 : 1,
                                             y: clip?.transform.isFlippedVertically == true ? -1 : 1))
            .concatenating(CGAffineTransform(translationX: viewport.width / 2, y: viewport.height / 2))
        return CGRect(x: 0, y: 0, width: viewport.width * fraction, height: viewport.height)
            .applying(transform.inverted()).intersection(extent)
    }
}

enum LUTPreviewRenderer {
    private static let shaperKernel = CIKernel(source: """
    vec3 lookup(sampler table, float index) {
        return sample(table, vec2(mod(index, 256.0) + 0.5, floor(index / 256.0) + 0.5)).rgb;
    }
    kernel vec4 shape(sampler source, sampler table, float count) {
        vec4 c = sample(source, samplerCoord(source));
        vec3 t = clamp(c.rgb, 0.0, 1.0) * (count - 1.0);
        vec3 a = floor(t);
        vec3 b = min(a + 1.0, count - 1.0);
        return vec4(mix(lookup(table, a.r).r, lookup(table, b.r).r, t.r - a.r),
                    mix(lookup(table, a.g).g, lookup(table, b.g).g, t.g - a.g),
                    mix(lookup(table, a.b).b, lookup(table, b.b).b, t.b - a.b), c.a);
    }
    """)

    static func apply(_ lut: CubeLUT, to source: CIImage) -> CIImage? {
        var input = source
        for stage in lut.stages {
            let span = stage.maximum - stage.minimum
            let scale = SIMD3<Float>(1 / span.x, 1 / span.y, 1 / span.z)
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(-stage.minimum.x * scale.x), y: CGFloat(-stage.minimum.y * scale.y), z: CGFloat(-stage.minimum.z * scale.z), w: 0)
            ])
            if stage.is1D {
                guard let kernel = shaperKernel else { return nil }
                let rows = (stage.size + 255) / 256
                var values = stage.values
                values += Array(repeating: stage.values.last!, count: rows * 256 - stage.size)
                let data = values.flatMap { [$0.x, $0.y, $0.z, Float(1)] }.withUnsafeBytes { Data($0) }
                let table = CIImage(bitmapData: data, bytesPerRow: 256 * 16, size: CGSize(width: 256, height: rows), format: .RGBAf, colorSpace: nil)
                guard let shaped = kernel.apply(extent: source.extent, roiCallback: { index, rect in
                    index == 1 ? table.extent : rect
                }, arguments: [input, table, stage.size]) else { return nil }
                input = shaped
            } else {
                input = input.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": stage.size, "inputCubeData": stage.rgbaData])
            }
        }
        return input.cropped(to: source.extent)
    }
}
