import AVFoundation
import CVMAF
import VideoToolbox

package struct QualityError: Error, CustomStringConvertible {
    package let description: String
    package init(_ description: String) { self.description = description }
}

package func check(_ status: Int32, _ operation: String) throws {
    guard status == 0 else { throw QualityError("\(operation) failed (\(status))") }
}

/// Confined to the evaluation worker; retains two pairs for boundary overlap.
package final class VMAFEvaluator {
    package static let modelVersion = "vmaf_v0.6.1"
    private var context: OpaquePointer?
    private var model: OpaquePointer?
    private var transfer: VTPixelTransferSession?
    private var count: UInt32 = 0
    private var prefix: UInt32 = 0
    private let windowFrames: UInt32
    private var tail: [(CVPixelBuffer, CVPixelBuffer)] = []
    package private(set) var scores: [Double] = []

    package init(windowFrames: UInt32 = 30) throws {
        guard windowFrames >= 2 else { throw QualityError("Evaluation window must contain at least two frames") }
        self.windowFrames = windowFrames
        var config = VmafConfiguration()
        config.log_level = VMAF_LOG_LEVEL_ERROR
        // Run synchronously on our worker to bound in-flight feature extraction.
        config.n_threads = 0
        config.n_subsample = 1
        try check(vmaf_init(&context, config), "vmaf_init")
        do {
            var modelConfig = VmafModelConfig()
            try check(vmaf_model_load(&model, &modelConfig, Self.modelVersion), "vmaf_model_load")
            try check(vmaf_use_features_from_model(context, model), "vmaf_use_features_from_model")
            try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "pixel transfer")
        } catch {
            if let model { vmaf_model_destroy(model) }
            if let context { vmaf_close(context) }
            throw error
        }
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let context { vmaf_close(context) }
        if let model { vmaf_model_destroy(model) }
    }

    private func picture(_ source: CVPixelBuffer) throws -> VmafPicture {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let normalized: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            normalized = source
        } else {
            var converted: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &converted), "pixel buffer")
            guard let converted, let transfer else { throw QualityError("Missing pixel transfer buffer") }
            try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: converted), "pixel conversion")
            normalized = converted
        }
        try check(CVPixelBufferLockBaseAddress(normalized, .readOnly), "pixel lock")
        defer { CVPixelBufferUnlockBaseAddress(normalized, .readOnly) }
        var result = VmafPicture()
        try check(vmaf_picture_alloc(&result, VMAF_PIX_FMT_YUV420P, 8, UInt32(width), UInt32(height)), "picture allocation")
        guard let y = CVPixelBufferGetBaseAddressOfPlane(normalized, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(normalized, 1),
              let destY = result.data.0, let destU = result.data.1, let destV = result.data.2 else {
            vmaf_picture_unref(&result)
            throw QualityError("Missing YUV planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 1)
        for row in 0..<height {
            memcpy(destY.advanced(by: row * result.stride.0), y.advanced(by: row * yStride), width)
        }
        for row in 0..<(height / 2) {
            let source = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            let u = destU.advanced(by: row * result.stride.1).assumingMemoryBound(to: UInt8.self)
            let v = destV.advanced(by: row * result.stride.2).assumingMemoryBound(to: UInt8.self)
            for col in 0..<(width / 2) {
                u[col] = source[col * 2]
                v[col] = source[col * 2 + 1]
            }
        }
        return result
    }

    package func submit(reference: CVPixelBuffer, decoded: CVPixelBuffer) throws -> Double? {
        guard CVPixelBufferGetWidth(reference) == CVPixelBufferGetWidth(decoded),
              CVPixelBufferGetHeight(reference) == CVPixelBufferGetHeight(decoded) else {
            throw QualityError("Reference and decoded dimensions differ")
        }
        try read(reference: reference, decoded: decoded)
        tail.append((reference, decoded))
        if tail.count > 2 { tail.removeFirst() }
        // libvmaf 3.2 computes motion2 on flush. Include one frame of
        // lookahead, then restart with the prior frame and that lookahead.
        guard count == prefix + windowFrames + 1 else { return nil }
        try check(vmaf_read_pictures(context, nil, nil, 0), "VMAF window flush")
        try collect(until: count - 1)
        let latest = scores.last
        if let context { vmaf_close(context) }
        context = nil
        var config = VmafConfiguration()
        config.log_level = VMAF_LOG_LEVEL_ERROR
        config.n_subsample = 1
        try check(vmaf_init(&context, config), "VMAF next window")
        try check(vmaf_use_features_from_model(context, model), "VMAF next window features")
        count = 0
        prefix = 1
        for pair in tail { try read(reference: pair.0, decoded: pair.1) }
        return latest
    }

    private func read(reference: CVPixelBuffer, decoded: CVPixelBuffer) throws {
        var ref = try picture(reference)
        var dist: VmafPicture
        do { dist = try picture(decoded) } catch {
            vmaf_picture_unref(&ref)
            throw error
        }
        // libvmaf takes ownership of the picture references.
        try check(vmaf_read_pictures(context, &ref, &dist, count), "vmaf_read_pictures")
        count += 1
    }

    private func collect(until end: UInt32) throws {
        for index in prefix..<end {
            var score = 0.0
            try check(vmaf_score_at_index(context, model, &score, index), "VMAF score")
            scores.append(score)
        }
    }

    package func finish(output: String) throws {
        try check(vmaf_read_pictures(context, nil, nil, 0), "vmaf flush")
        try collect(until: count)
        guard !scores.isEmpty else { throw QualityError("No complete VMAF results") }
        let result: [String: Any] = [
            "version": String(cString: vmaf_version()), "model": Self.modelVersion,
            "windowFrames": windowFrames, "boundaryOverlapFrames": 2,
            "frames": scores.enumerated().map { ["frameNum": $0.offset, "metrics": ["vmaf": $0.element]] as [String: Any] }
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
