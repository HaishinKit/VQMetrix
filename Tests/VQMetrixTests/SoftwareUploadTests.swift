@preconcurrency import AVFoundation
import AOMHaishinKit
import VPXHaishinKit
import Foundation
import Testing
import ZIPFoundation
@testable import VQMetrix

struct SoftwareUploadTests {
    @Test(arguments: [BenchmarkCodec.av1, .vp8, .vp9])
    func softwarePackagesDecodeEvaluateAndPreserveCodec(_ codec: BenchmarkCodec) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try fixture(codec, root: root)
        let zip = root.appendingPathComponent("capture.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for name in ["manifest.json"] + manifest.files.map(\.path) {
                try archive.addEntry(with: name, fileURL: root.appendingPathComponent(name))
            }
        }
        let payload = root.appendingPathComponent("payload")
        let extracted = try UploadPackage.extract(zip, to: payload, runID: try #require(UUID(uuidString: manifest.runId)))
        let variant = try #require(extracted.variants.first)
        #expect(variant.benchmarkCodec == codec)
        let input = try await UploadVideoInput(url: payload.appendingPathComponent(variant.file), variant: variant, reference: manifest.reference)
        for index in 0..<15 {
            let sample = try #require(try input.next())
            #expect(sample.presentationTimeStamp == CMTime(value: Int64(index) * 1_000_000 / 15, timescale: 1_000_000))
        }
        try input.finish()
        let output = root.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await UploadEvaluation.evaluate(manifest: extracted, payload: payload, output: output, model: .legacy)
        let saved = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: output.appendingPathComponent("live-summary.json")))
        #expect(saved.completeEvaluation)
        #expect(saved.evaluatedFrames == 15)
        #expect(saved.segments.first?.settings.codec == codec)
        #expect(saved.segments.first?.settings.profile == codec.defaultProfile)
        #expect(saved.segments.first?.encodedCodec == codec.codecType)
        #expect((saved.segments.first?.meanVMAF ?? 0) > 95)
    }

    @Test func rejectsCorruptIVFBeforeAcceptingDecodedFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try fixture(.vp9, root: root)
        let url = root.appendingPathComponent(manifest.variants[0].file)
        let valid = try Data(contentsOf: url)
        // Signature, version, header length, codec, dimensions, timebase, frame count and reserved field.
        for offset in [0, 4, 6, 8, 12, 14, 16, 20, 24, 28] {
            var invalid = valid; invalid[offset] ^= 1
            try invalid.write(to: url)
            #expect(throws: (any Error).self) { try IVFUploadInput(url: url, codec: .vp9, reference: manifest.reference) }
        }
        // Zero/oversized packet length and incorrect first PTS are rejected before decoding.
        for (range, replacement) in [(32..<36, Data(repeating: 0, count: 4)),
                                     (32..<36, Data(repeating: 255, count: 4)),
                                     (36..<44, Data(repeating: 1, count: 8))] {
            var invalid = valid; invalid.replaceSubrange(range, with: replacement)
            try invalid.write(to: url)
            let input = try IVFUploadInput(url: url, codec: .vp9, reference: manifest.reference)
            #expect(throws: (any Error).self) { try input.next() }
        }
        try valid.prefix(44).write(to: url)
        let truncated = try IVFUploadInput(url: url, codec: .vp9, reference: manifest.reference)
        #expect(throws: (any Error).self) { try truncated.next() }
        try (valid + Data([0])).write(to: url)
        let extra = try IVFUploadInput(url: url, codec: .vp9, reference: manifest.reference)
        for _ in 0..<15 { _ = try extra.next() }
        #expect(throws: (any Error).self) { try extra.finish() }
        // A misleading container codec cannot disguise a different bitstream.
        var mislabeled = valid
        mislabeled.replaceSubrange(8..<12, with: Data("AV01".utf8))
        try mislabeled.write(to: url)
        let wrongDecoder = try IVFUploadInput(url: url, codec: .av1, reference: manifest.reference)
        #expect(throws: (any Error).self) { try wrongDecoder.next() }
    }

    @Test func onlyAllowsCodecSpecificContainers() {
        for name in ["av1-300000.ivf", "vp8-300000.ivf", "vp9-300000.ivf", "h264-300000.mp4", "hevc-300000.mp4"] {
            #expect(UploadPackage.validName(name))
        }
        for name in ["vp9-300000.mp4", "h264-300000.ivf", "av1-300000.webm", "../av1-300000.ivf", "nested/vp8-300000.ivf"] {
            #expect(!UploadPackage.validName(name))
        }
    }

    /// Independent fixture writer for the documented IVF subset, not the sender implementation.
    private func fixture(_ codec: BenchmarkCodec, root: URL) throws -> CaptureManifest {
        let name = "\(codec.rawValue.lowercased())-300000.ivf"
        let reference = CaptureManifest.Reference(file: "reference.y4m", source: "test-pattern-v1", width: 320, height: 180,
            fpsNumerator: 15, fpsDenominator: 1, frameCount: 15, pixelFormat: "yuv420p", bitDepth: 8,
            colorRange: "limited", colorMatrix: "bt709", frameMap: "frame-map.json")
        let aom = try codec == .av1 ? AOMVideoEncoder(settings: .init(videoSize: CGSize(width: 320, height: 180), bitRate: 300000, expectedFrameRate: 15)) : nil
        let vpx = try codec == .av1 ? nil : VPXVideoEncoder(settings: .init(videoSize: CGSize(width: 320, height: 180), bitRate: 300000, expectedFrameRate: 15, format: codec == .vp8 ? .vp8 : .vp9))
        defer { aom?.invalidate(); vpx?.invalidate() }
        var raw = Data("YUV4MPEG2 W320 H180 F15:1 Ip A1:1 C420jpeg\n".utf8)
        var packets: [CMSampleBuffer] = []
        for index in 0..<15 {
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8Planar, nil, &pixel), "Fixture pixels")
            let image = try #require(pixel)
            CVPixelBufferLockBaseAddress(image, [])
            for plane in 0..<3 {
                memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane == 0 ? 16 : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
            }
            CVPixelBufferUnlockBaseAddress(image, [])
            var description: CMVideoFormatDescription?
            try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description), "Fixture format")
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(value: Int64(index) * 1_000_000 / 15, timescale: 1_000_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &sample), "Fixture sample")
            if let aom { packets += try aom.encode(try #require(sample)) }
            if let vpx { packets += try vpx.encode(try #require(sample)) }
            raw.append(Data("FRAME\n".utf8)); raw.append(Data(repeating: 16, count: 320 * 180)); raw.append(Data(repeating: 128, count: 320 * 180 / 2))
        }
        if let aom { packets += try aom.finish() }
        if let vpx { packets += try vpx.finish() }
        var ivf = Data("DKIF".utf8)
        ivf.little(UInt16(0)); ivf.little(UInt16(32))
        ivf.append(Data((codec == .av1 ? "AV01" : codec == .vp8 ? "VP80" : "VP90").utf8))
        ivf.little(UInt16(320)); ivf.little(UInt16(180)); ivf.little(UInt32(1_000_000)); ivf.little(UInt32(1))
        ivf.little(UInt32(packets.count)); ivf.little(UInt32(0))
        for (index, packet) in packets.enumerated() {
            let block = try #require(packet.dataBuffer)
            let length = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: length)
            try bytes.withUnsafeMutableBytes { try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!), "Fixture packet") }
            ivf.little(UInt32(length)); ivf.little(UInt64(index) * 1_000_000 / 15); ivf.append(bytes)
        }
        try raw.write(to: root.appendingPathComponent(reference.file))
        try ivf.write(to: root.appendingPathComponent(name))
        let pts = (0..<15).map { Int64($0) * 1_000_000 / 15 }
        try JSONSerialization.data(withJSONObject: ["referencePtsUs": pts, "captureTimestampsNs": [], "variants": [name: pts]]).write(to: root.appendingPathComponent(reference.frameMap))
        let files = try [reference.file, reference.frameMap, name].map { name in
            let file = root.appendingPathComponent(name)
            return CaptureManifest.Payload(path: name, size: Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), sha256: try UploadPackage.digest(file))
        }
        let manifest = CaptureManifest(schema: "vqmetrix.capture.v1", schemaVersion: 1, runId: UUID().uuidString, reference: reference,
            variants: [.init(file: name, codec: codec.rawValue.lowercased(), targetBitrate: 300000, frameCount: 15, width: 320, height: 180)], files: files)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        return manifest
    }
}

private extension Data {
    mutating func little<T: FixedWidthInteger>(_ value: T) {
        var number = value.littleEndian
        Swift.withUnsafeBytes(of: &number) { append(contentsOf: $0) }
    }
}
