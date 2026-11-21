import AVFoundation

/// Application-owned color/range conversion and resizing. Codec wrappers only accept prepared I420.
final class SoftwareInputConverter {
    private let scaler: EvaluationScaler
    init() throws { scaler = try EvaluationScaler() }
    func prepare(_ source: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let nv12 = try scaler.resize(source, width: width, height: height)
        var planar: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8Planar, nil, &planar), "I420 input buffer")
        guard let planar else { throw QualityError("Missing I420 input buffer") }
        try check(CVPixelBufferLockBaseAddress(nv12, .readOnly), "NV12 lock")
        defer { CVPixelBufferUnlockBaseAddress(nv12, .readOnly) }
        try check(CVPixelBufferLockBaseAddress(planar, []), "I420 lock")
        defer { CVPixelBufferUnlockBaseAddress(planar, []) }
        guard let sourceY = CVPixelBufferGetBaseAddressOfPlane(nv12, 0),
              let sourceUV = CVPixelBufferGetBaseAddressOfPlane(nv12, 1)?.assumingMemoryBound(to: UInt8.self),
              let y = CVPixelBufferGetBaseAddressOfPlane(planar, 0),
              let u = CVPixelBufferGetBaseAddressOfPlane(planar, 1)?.assumingMemoryBound(to: UInt8.self),
              let v = CVPixelBufferGetBaseAddressOfPlane(planar, 2)?.assumingMemoryBound(to: UInt8.self) else { throw QualityError("Missing I420 planes") }
        for row in 0..<height {
            memcpy(y.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(planar, 0)), sourceY.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(nv12, 0)), width)
        }
        for row in 0..<height / 2 {
            for col in 0..<width / 2 {
                let offset = row * CVPixelBufferGetBytesPerRowOfPlane(nv12, 1) + col * 2
                u[row * CVPixelBufferGetBytesPerRowOfPlane(planar, 1) + col] = sourceUV[offset]
                v[row * CVPixelBufferGetBytesPerRowOfPlane(planar, 2) + col] = sourceUV[offset + 1]
            }
        }
        CVBufferPropagateAttachments(nv12, planar)
        return planar
    }
}
