import AVFoundation
import VideoToolbox

/// Confined to the VMAF worker. Keep the reference at its source dimensions so
/// downscaling loss is included rather than comparing at a lower native size.
final class EvaluationScaler {
    private var session: VTPixelTransferSession?
    init() throws {
        try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session), "evaluation scaler")
        if let session {
            try check(VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal), "evaluation scaling mode")
        }
    }
    deinit { if let session { VTPixelTransferSessionInvalidate(session) } }

    func match(_ decoded: CVPixelBuffer, to reference: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(reference), height = CVPixelBufferGetHeight(reference)
        guard CVPixelBufferGetWidth(decoded) != width || CVPixelBufferGetHeight(decoded) != height else { return decoded }
        var destination: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &destination), "evaluation buffer")
        guard let session, let destination else { throw QualityError("Missing evaluation scaling buffer") }
        CVBufferPropagateAttachments(decoded, destination)
        try check(VTPixelTransferSessionTransferImage(session, from: decoded, to: destination), "evaluation resize")
        return destination
    }
}

enum EncodedProfile {
    static func read(_ format: CMFormatDescription) -> BenchmarkProfile? {
        guard let dictionary = CMFormatDescriptionGetExtensions(format) else { return nil }
        let extensions = dictionary as NSDictionary
        guard let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary else { return nil }
        if let bytes = atoms["avcC"] as? Data, bytes.count >= 2 {
            switch bytes[bytes.startIndex + 1] {
            case 66: return .baseline
            case 77: return .main
            case 100: return .high
            default: return nil
            }
        }
        if let bytes = atoms["hvcC"] as? Data, bytes.count >= 2 {
            switch bytes[bytes.startIndex + 1] & 31 {
            case 1: return .main
            case 2: return .main10
            default: return nil
            }
        }
        return nil
    }
}
