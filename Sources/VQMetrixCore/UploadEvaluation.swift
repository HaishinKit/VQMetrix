@preconcurrency import AVFoundation
import CVMAF
import Foundation

private final class Y4MInput {
    let handle: FileHandle
    let reference: CaptureManifest.Reference
    init(url: URL, reference: CaptureManifest.Reference) throws {
        self.reference = reference
        handle = try FileHandle(forReadingFrom: url)
        let header = try line()
        let fields = header.split(separator: " ").map(String.init)
        guard fields.first == "YUV4MPEG2", fields.contains("W\(reference.width)"), fields.contains("H\(reference.height)"),
              fields.contains("F\(reference.fpsNumerator):1"), fields.contains("Ip"), fields.contains("C420jpeg") else {
            throw QualityError("Y4M header differs from manifest")
        }
    }
    deinit { try? handle.close() }
    func line() throws -> String {
        var data = Data()
        while data.count < 4096 {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { throw QualityError("Truncated Y4M header") }
            if byte[0] == 10 { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        throw QualityError("Y4M header is too large")
    }
    func frame() throws -> CVPixelBuffer {
        guard try line() == "FRAME" else { throw QualityError("Invalid Y4M frame marker") }
        let w = reference.width, h = reference.height, size = w * h * 3 / 2
        guard let data = try handle.read(upToCount: size), data.count == size else { throw QualityError("Truncated Y4M frame") }
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), "Reference pixel buffer")
        guard let pixel else { throw QualityError("Missing reference buffer") }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h { memcpy(y.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)), bytes.advanced(by: row * w), w) }
            for row in 0..<(h/2) { for col in 0..<(w/2) {
                let offset = row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + col * 2
                uv[offset] = bytes[w*h + row*w/2 + col]
                uv[offset+1] = bytes[w*h*5/4 + row*w/2 + col]
            } }
        }
        return pixel
    }
    func finish() throws {
        guard (try handle.read(upToCount: 1))?.isEmpty != false else { throw QualityError("Extra reference frames") }
    }
}

struct UploadEvaluation {
    static func evaluate(manifest: CaptureManifest, payload: URL, output: URL) async throws {
        var segments: [SegmentReport] = []
        var points: [QualityPoint] = []
        let ref = manifest.reference
        var failure: String?
        do {
            guard ref.colorRange == "limited", ref.colorMatrix == "bt709" else {
                throw QualityError("Color interpretation is unspecified or unsupported. Capture the existing mixer output (limited BT.709).")
            }
            for (index, variant) in manifest.variants.enumerated() {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: payload.appendingPathComponent(variant.file))
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw QualityError("MP4 has no video track") }
                let descriptions = try await track.load(.formatDescriptions)
                let expectedCodec = variant.codec == "h264" ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
                guard descriptions.count == 1, CMFormatDescriptionGetMediaSubType(descriptions[0]) == expectedCodec else { throw QualityError("MP4 codec differs from manifest") }
                let dimensions = CMVideoFormatDescriptionGetDimensions(descriptions[0])
                guard dimensions.width == Int32(ref.width), dimensions.height == Int32(ref.height) else { throw QualityError("MP4 dimensions differ from reference") }
                let reader = try AVAssetReader(asset: asset)
                let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                decoded.alwaysCopiesSampleData = false
                guard reader.canAdd(decoded) else { throw QualityError("Cannot decode uploaded video") }
                reader.add(decoded)
                guard reader.startReading() else { throw QualityError("Cannot start video decoder") }
                defer { reader.cancelReading() }
                let raw = try Y4MInput(url: payload.appendingPathComponent(ref.file), reference: ref)
                let evaluator = try VMAFEvaluator(windowFrames: UInt32(ref.fpsNumerator))
                for frame in 0..<ref.frameCount {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        guard let sample = decoded.copyNextSampleBuffer(), let image = sample.imageBuffer else { throw QualityError("Decoded frame count differs from reference") }
                        let expected = Double(Int64(frame) * 1_000_000 / Int64(ref.fpsNumerator)) / 1_000_000
                        guard abs(sample.presentationTimeStamp.seconds - expected) <= 0.000002 else { throw QualityError("Decoded timestamps differ from reference") }
                        _ = try evaluator.submit(reference: raw.frame(), decoded: image)
                    }
                }
                guard decoded.copyNextSampleBuffer() == nil, reader.status == .completed else { throw QualityError("Extra frames or incomplete MP4 decode") }
                try raw.finish()
                try evaluator.finish(output: output.appendingPathComponent("variant-\(index)-vmaf.json").path)
                let settings = BenchmarkSettings(codec: variant.codec == "h264" ? .h264 : .hevc, bitrate: variant.targetBitrate)
                for (frame, score) in evaluator.scores.enumerated() {
                    points.append(QualityPoint(segment: index, index: frame, pts: Double(frame)/Double(ref.fpsNumerator), score: score, settings: settings, latencyMilliseconds: 0))
                }
                let bytes = try payload.appendingPathComponent(variant.file).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                segments.append(SegmentReport(index: index, settings: settings, inputFrames: ref.frameCount,
                    encodedFrames: ref.frameCount, decodedFrames: ref.frameCount, evaluatedFrames: evaluator.scores.count,
                    evaluationQueueDropped: 0, referenceEvictions: 0, unresolvedReferences: 0, unmatchedDecoded: 0,
                    encodedBytes: bytes, encodedCodec: expectedCodec, firstPTS: 0,
                    lastPTS: Double(ref.frameCount-1)/Double(ref.fpsNumerator), meanVMAF: evaluator.scores.reduce(0,+)/Double(evaluator.scores.count)))
            }
        } catch { failure = String(describing: error) }
        let run = SavedRun(input: payload.path, model: VMAFEvaluator.modelVersion, libvmafVersion: String(cString: vmaf_version()),
            inputFrames: ref.frameCount * manifest.variants.count, evaluatedFrames: points.count, completeEvaluation: failure == nil,
            stoppedByUser: false, mixerQueueDropped: 0, mixerUndelivered: 0, segments: segments, scores: points,
            sourceKind: "upload", sourceName: "Device · \(ref.source) · \(manifest.runId.prefix(8))", createdAt: Date(),
            format: "\(ref.width)×\(ref.height) · \(ref.fpsNumerator) fps · \(ref.colorRange) \(ref.colorMatrix)", failure: failure)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: output.appendingPathComponent("live-summary.json"), options: .atomic)
        try encoder.encode(RunMetadata(run: run)).write(to: output.appendingPathComponent("history.json"), options: .atomic)
        await MainActor.run { NotificationCenter.default.post(name: .benchmarkSaved, object: nil) }
        if let failure { throw QualityError(failure) }
    }
}
