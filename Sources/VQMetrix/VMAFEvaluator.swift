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
    private let evaluationModel: VMAFModel
    private let scaler: EvaluationScaler
    private let encoding: VMAFEncoding?
    private var evaluationDimensions: (width: Int, height: Int)?
    private var context: OpaquePointer?
    private var model: OpaquePointer?
    private var transfer: VTPixelTransferSession?
    private var count: UInt32 = 0
    private var prefix: UInt32 = 0
    private let windowFrames: UInt32
    private var tail: [(CVPixelBuffer, CVPixelBuffer)] = []
    package private(set) var scores: [Double] = []

    package init(windowFrames: UInt32 = 30, model selection: VMAFModel = .v1, encoding: VMAFEncoding? = nil) throws {
        self.evaluationModel = selection
        self.encoding = encoding; self.scaler = try EvaluationScaler()
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
            try check(vmaf_model_load(&model, &modelConfig, evaluationModel.rawValue), "vmaf_model_load")
            if selection == .v1, let encoding {
                guard encoding.width >= 180, encoding.height >= 150 else {
                    throw QualityError("VMAF v1 requires encoded dimensions of at least 180 × 150. Choose a larger output or VMAF v0.6.1.")
                }
                var options: OpaquePointer?
                do {
                    for (key, value) in [("enc_width", encoding.width), ("enc_height", encoding.height), ("enc_bitdepth", encoding.bitDepth)] {
                        try check(vmaf_feature_dictionary_set(&options, key, String(value)), "CAMBI encoding options")
                    }
                } catch { vmaf_feature_dictionary_free(&options); throw error }
                // libvmaf consumes the options dictionary, including on overload failure.
                try check(vmaf_model_feature_overload(model, "cambi", options), "CAMBI model options")
            }
            try check(vmaf_use_features_from_model(context, model), "vmaf_use_features_from_model")
            try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "pixel transfer")
        } catch {
            if let model { vmaf_model_destroy(model); self.model = nil }
            if let context { vmaf_close(context); self.context = nil }
            throw error
        }
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let context { vmaf_close(context) }
        if let model { vmaf_model_destroy(model) }
    }

    private func picture(_ original: CVPixelBuffer) throws -> VmafPicture {
        let originalWidth = CVPixelBufferGetWidth(original), originalHeight = CVPixelBufferGetHeight(original)
        guard originalWidth > 0, originalHeight > 0 else { throw QualityError("Invalid evaluation dimensions") }
        if evaluationModel == .v1, max(originalWidth, originalHeight) > min(originalWidth, originalHeight) * 4 {
            throw QualityError("VMAF v1 supports aspect ratios up to 4:1.")
        }
        let dimensions = evaluationModel.dimensions(width: originalWidth, height: originalHeight)
        evaluationDimensions = dimensions
        let pixelFormat = evaluationModel == .v1 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let source = try scaler.resize(original, width: dimensions.width, height: dimensions.height, pixelFormat: pixelFormat)
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let normalized: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(source) == pixelFormat {
            normalized = source
        } else {
            var converted: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, width, height,
                pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &converted), "pixel buffer")
            guard let converted, let transfer else { throw QualityError("Missing pixel transfer buffer") }
            try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: converted), "pixel conversion")
            normalized = converted
        }
        try check(CVPixelBufferLockBaseAddress(normalized, .readOnly), "pixel lock")
        defer { CVPixelBufferUnlockBaseAddress(normalized, .readOnly) }
        var result = VmafPicture()
        try check(vmaf_picture_alloc(&result, VMAF_PIX_FMT_YUV420P, UInt32(evaluationModel.bitDepth), UInt32(width), UInt32(height)), "picture allocation")
        guard let y = CVPixelBufferGetBaseAddressOfPlane(normalized, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(normalized, 1),
              let destY = result.data.0, let destU = result.data.1, let destV = result.data.2 else {
            vmaf_picture_unref(&result)
            throw QualityError("Missing YUV planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 1)
        for row in 0..<height {
            if evaluationModel == .legacy {
                memcpy(destY.advanced(by: row * result.stride.0), y.advanced(by: row * yStride), width)
            } else {
                let input = y.advanced(by: row * yStride).assumingMemoryBound(to: UInt16.self)
                let output = destY.advanced(by: row * result.stride.0).assumingMemoryBound(to: UInt16.self)
                for col in 0..<width { output[col] = input[col] >> 6 }
            }
        }
        for row in 0..<(height / 2) {
            let source = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            let u = destU.advanced(by: row * result.stride.1).assumingMemoryBound(to: UInt8.self)
            let v = destV.advanced(by: row * result.stride.2).assumingMemoryBound(to: UInt8.self)
            for col in 0..<(width / 2) {
                if evaluationModel == .legacy {
                    u[col] = source[col * 2]; v[col] = source[col * 2 + 1]
                } else {
                    let u10 = destU.advanced(by: row * result.stride.1).assumingMemoryBound(to: UInt16.self)
                    let v10 = destV.advanced(by: row * result.stride.2).assumingMemoryBound(to: UInt16.self)
                    let input10 = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt16.self)
                    u10[col] = input10[col * 2] >> 6; v10[col] = input10[col * 2 + 1] >> 6
                }
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
        var result: [String: Any] = [
            "version": String(cString: vmaf_version()), "model": evaluationModel.rawValue,
            "evaluationBitDepth": evaluationModel.bitDepth, "evaluationSizing": evaluationModel == .v1 ? "Short side 1080; aspect ratio preserved" : "Source dimensions", "windowFrames": windowFrames, "boundaryOverlapFrames": 2,
            "frames": scores.enumerated().map { ["frameNum": $0.offset, "metrics": ["vmaf": $0.element]] as [String: Any] }
        ]
        if let dimensions = evaluationDimensions { result["evaluationWidth"] = dimensions.width; result["evaluationHeight"] = dimensions.height }
        if let encoding { result["encoding"] = ["width": encoding.width, "height": encoding.height, "bitDepth": encoding.bitDepth] }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
