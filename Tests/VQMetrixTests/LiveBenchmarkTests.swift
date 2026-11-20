@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import VQMetrix

@Suite(.serialized)
@MainActor
struct LiveBenchmarkTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw QualityError("Live benchmark timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fixture(_ url: URL, width: Int = 320, height: Int = 180) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<80 {
            try await wait { input.isReadyForMoreMediaData }
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), "fixture buffer")
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                for col in 0..<width { y[row * stride + col] = UInt8(40 + ((col + index * 3) / 16 + row / 16) % 2 * 140) }
            }
            let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func liveCodecAndBitrateChangesPreserveSegments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.mp4")
        try await fixture(url)
        let engine = LiveBenchmark()
        defer { engine.stop() }
        engine.start(input: url, settings: BenchmarkSettings(codec: .h264, bitrate: 1_000_000), duration: 8)
        try await wait { engine.decodedFrames >= 5 || !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.isRunning)
        let hevc = BenchmarkSettings(codec: .hevc, bitrate: 600_000, profile: .main10, resolution: .p360)
        engine.apply(hevc)
        try await wait { (engine.activeSettings == hevc && engine.decodedFrames >= 15) || !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.sourceSample != nil)
        #expect(engine.decodedSample != nil)
        let lowerRate = BenchmarkSettings(codec: .hevc, bitrate: 200_000)
        engine.apply(lowerRate)
        try await wait { (engine.activeSettings == lowerRate && engine.decodedFrames >= 25) || !engine.isRunning }
        #expect(engine.errorMessage == nil)
        engine.stop()
        try await wait { !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.reports.count == 3)
        let reports = engine.reports
        if reports.count == 3 {
            #expect(reports[0].encodedCodec == kCMVideoCodecType_H264)
            #expect(reports[1].encodedCodec == kCMVideoCodecType_HEVC)
            #expect(reports[1].encodedWidth == 640 && reports[1].encodedHeight == 360)
            #expect(reports[1].encodedProfile == "Main 10")
            #expect(reports[2].encodedWidth == 320 && reports[2].encodedHeight == 180)
            #expect(reports[2].settings == lowerRate)
            #expect(reports.allSatisfy { $0.inputFrames > 0 && $0.inputFrames == $0.encodedFrames && $0.encodedFrames == $0.decodedFrames })
        }
        #expect(engine.scores.count == engine.reports.reduce(0) { $0 + $1.evaluatedFrames })
        #expect(engine.scores.count == engine.inputFrames)
        #expect(engine.scores.allSatisfy { $0.score.isFinite && $0.latencyMilliseconds >= 0 })
        let output = try #require(engine.resultDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("live-summary.json"))) as? [String: Any]
        #expect(summary?["stoppedByUser"] as? Bool == true)
        #expect(summary?["completeEvaluation"] as? Bool == true)
        #expect((summary?["segments"] as? [Any])?.count == 3)
    }
    @Test func profileAndResolutionAreVerifiedInEncodedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.mp4")
        try await fixture(url, width: 640, height: 360)
        for codec in BenchmarkCodec.allCases {
            for profile in codec.profiles {
                let engine = LiveBenchmark()
                let settings = BenchmarkSettings(codec: codec, bitrate: 800_000, profile: profile, resolution: .p180)
                engine.start(input: url, settings: settings, duration: 0.8)
                try await wait { !engine.isRunning }
                #expect(engine.errorMessage == nil, "\(codec.rawValue) \(profile.rawValue): \(engine.errorMessage ?? "")")
                let report = try #require(engine.reports.first)
                #expect(report.encodedWidth == 320 && report.encodedHeight == 180)
                #expect(report.referenceWidth == 640 && report.referenceHeight == 360)
                #expect(report.encodedProfile == profile.rawValue)
                #expect(report.evaluatedFrames > 0)
                #expect(engine.scores.allSatisfy { $0.score.isFinite })
                if let output = engine.resultDirectory { try? FileManager.default.removeItem(at: output) }
            }
        }
    }

}
