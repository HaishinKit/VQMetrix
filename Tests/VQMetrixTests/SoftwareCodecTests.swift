import AVFoundation
import Testing
@testable import VQMetrix

struct SoftwareCodecTests {
    @Test(arguments: [BenchmarkCodec.vp8, .vp9, .av1])
    func softwareConversionDecodingAndStatistics(codec: BenchmarkCodec) async throws {
        let settings = BenchmarkSettings(codec: codec, bitrate: 300_000)
        #expect(settings.isValid)
        let worker = try SoftwareCodecWorker(settings: settings, width: 64, height: 48, fps: 30)
        var outputFrames: [CMSampleBuffer] = []
        for index in 0..<4 {
            var image: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, 96, 72, kCVPixelFormatType_32BGRA, nil, &image), "test image")
            let pixel = try #require(image)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetBytesPerRow(pixel) * 72)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            var format: CMFormatDescription?
            try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format), "test format")
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 30 + Int64(index), timescale: 30), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample), "test sample")
            let output = try await worker.process(.init(samples: [try #require(sample)]))
            outputFrames += output.frames.samples
            #expect(output.statistics.submittedFrameCount == UInt64(index + 1))
        }
        let final = try await worker.finish()
        outputFrames += final.frames.samples
        #expect(outputFrames.count == 4)
        #expect(final.statistics.outputPacketCount == 4)
        #expect(final.statistics.encodedByteCount > 0)
        #expect(final.statistics.totalEncodingDuration > 0)
        for (index, sample) in outputFrames.enumerated() {
            let image = try #require(sample.imageBuffer)
            #expect(CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 48)
            #expect(abs(sample.presentationTimeStamp.seconds - (1 + Double(index) / 30)) < 0.000002)
        }
        #expect(try JSONDecoder().decode(EncoderStatistics.self, from: JSONEncoder().encode(final.statistics)) == final.statistics)
    }
}
