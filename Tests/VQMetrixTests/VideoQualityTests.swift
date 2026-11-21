import AVFoundation
import Foundation
import Testing
@testable import VQMetrix

@Suite(.serialized)
struct VQMetrixTests {
    private func image(width: Int = 256, height: Int = 144, flat: Bool = false, shift: Int = 0) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), "test image")
        let result = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let y = try #require(CVPixelBufferGetBaseAddressOfPlane(result, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(result, 1))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        for row in 0..<height {
            for col in 0..<width {
                y[row * stride + col] = flat ? 128 : UInt8(40 + ((row / 8 + (col + shift) / 8) % 2) * 140)
            }
        }
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(result, 1) * (height / 2))
        return result
    }

    @Test(arguments: VMAFModel.allCases) func identityAndDegradation(model: VMAFModel) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = try image()
        let flat = try image(flat: true)
        let identity = try VMAFEvaluator(windowFrames: 3, model: model)
        let degraded = try VMAFEvaluator(windowFrames: 3, model: model)
        for _ in 0..<8 {
            _ = try identity.submit(reference: reference, decoded: reference)
            _ = try degraded.submit(reference: reference, decoded: flat)
        }
        // Two windows must be available before the final flush.
        #expect(identity.scores.count == 6)
        try identity.finish(output: directory.appendingPathComponent("identity.json").path)
        try degraded.finish(output: directory.appendingPathComponent("degraded.json").path)
        #expect(identity.scores.count == 8)
        #expect(try #require(identity.scores.min()) > 95)
        #expect(degraded.scores.allSatisfy { $0 < 80 })
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("identity.json"))) as? [String: Any]
        #expect(json?["model"] as? String == model.rawValue)
        #expect(json?["evaluationBitDepth"] as? Int == model.bitDepth)
        #expect((json?["frames"] as? [Any])?.count == 8)
    }

    @Test(arguments: VMAFModel.allCases) func windowBoundariesMatchContinuousEvaluation(model: VMAFModel) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windowed = try VMAFEvaluator(windowFrames: 3, model: model)
        let continuous = try VMAFEvaluator(windowFrames: 100, model: model)
        let distorted = try image(flat: true)
        for index in 0..<14 {
            let reference = try image(shift: index * index % 31)
            _ = try windowed.submit(reference: reference, decoded: distorted)
            _ = try continuous.submit(reference: reference, decoded: distorted)
        }
        try windowed.finish(output: directory.appendingPathComponent("windowed.json").path)
        try continuous.finish(output: directory.appendingPathComponent("continuous.json").path)
        #expect(windowed.scores.count == 14)
        #expect(continuous.scores.count == 14)
        for (actual, expected) in zip(windowed.scores, continuous.scores) {
            #expect(abs(actual - expected) < 0.000001)
        }
    }

    @Test func rejectsMismatchedDimensions() throws {
        let evaluator = try VMAFEvaluator()
        let reference = try image()
        let other = try image(width: 128)
        #expect(throws: QualityError.self) {
            try evaluator.submit(reference: reference, decoded: other)
        }
    }
@Test func unsupportedV1EncodingFailsWithoutFallback() throws {
    #expect(throws: QualityError.self) {
        try VMAFEvaluator(model: .v1, encoding: VMAFEncoding(width: 64, height: 64, bitDepth: 8))
    }
    let old = try VMAFEvaluator(model: .legacy, encoding: VMAFEncoding(width: 64, height: 64, bitDepth: 8))
    let reference = try image(width: 64, height: 64)
    _ = try old.submit(reference: reference, decoded: reference)
}

}
