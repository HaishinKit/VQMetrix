@preconcurrency import AVFoundation
import VPXHaishinKit
import AOMHaishinKit

struct CodecSamples: @unchecked Sendable { let samples: [CMSampleBuffer] }
struct SoftwareCodecOutput: Sendable { let frames: CodecSamples; let statistics: EncoderStatistics }

/// Owns conversion and software codecs off the main actor. Input queues remain bounded by the mixer tap.
actor SoftwareCodecWorker {
    private let converter: SoftwareInputConverter
    private let width: Int
    private let height: Int
    private let vpxEncoder: VPXVideoEncoder?
    private let vpxDecoder: VPXVideoDecoder?
    private let aomEncoder: AOMVideoEncoder?
    private let aomDecoder: AOMVideoDecoder?

    init(settings: BenchmarkSettings, width: Int, height: Int, fps: Float) throws {
        self.width = width; self.height = height
        converter = try SoftwareInputConverter()
        if settings.codec == .vp8 || settings.codec == .vp9 {
            let format: VPXVideoCodecSettings.Format = settings.codec == .vp8 ? .vp8 : .vp9
            vpxEncoder = try VPXVideoEncoder(settings: .init(videoSize: CGSize(width: width, height: height), bitRate: settings.bitrate, expectedFrameRate: Double(fps), format: format))
            vpxDecoder = try VPXVideoDecoder(format: format); aomEncoder = nil; aomDecoder = nil
        } else {
            aomEncoder = try AOMVideoEncoder(settings: .init(videoSize: CGSize(width: width, height: height), bitRate: settings.bitrate, expectedFrameRate: Double(fps)))
            aomDecoder = try AOMVideoDecoder(); vpxEncoder = nil; vpxDecoder = nil
        }
    }

    func process(_ input: CodecSamples) throws -> SoftwareCodecOutput {
        var decoded: [CMSampleBuffer] = []
        for sample in input.samples {
            guard let image = sample.imageBuffer else { throw QualityError("Missing input image") }
            let prepared = try converter.prepare(image, width: width, height: height)
            var description: CMFormatDescription?
            try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: prepared, formatDescriptionOut: &description), "software input format")
            guard let description else { throw QualityError("Missing software input format") }
            var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: .invalid)
            var converted: CMSampleBuffer?
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: prepared, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &converted), "software input sample")
            guard let converted else { throw QualityError("Missing converted input") }
            if let vpxEncoder, let vpxDecoder { for packet in try vpxEncoder.encode(converted) { decoded += try vpxDecoder.decode(packet) } }
            if let aomEncoder, let aomDecoder { for packet in try aomEncoder.encode(converted) { decoded += try aomDecoder.decode(packet) } }
        }
        return output(decoded)
    }

    func finish() throws -> SoftwareCodecOutput {
        defer { invalidate() }
        var decoded: [CMSampleBuffer] = []
        if let vpxEncoder, let vpxDecoder { for packet in try vpxEncoder.finish() { decoded += try vpxDecoder.decode(packet) } }
        if let aomEncoder, let aomDecoder { for packet in try aomEncoder.finish() { decoded += try aomDecoder.decode(packet) } }
        return output(decoded)
    }

    func invalidate() { vpxEncoder?.invalidate(); vpxDecoder?.invalidate(); aomEncoder?.invalidate(); aomDecoder?.invalidate() }

    private func output(_ frames: [CMSampleBuffer]) -> SoftwareCodecOutput {
        let statistics: EncoderStatistics
        if let value = vpxEncoder?.statistics {
            statistics = .init(backend: "libvpx", measurement: "Native encode call", submittedFrameCount: value.submittedFrameCount, outputPacketCount: value.outputPacketCount,
                encodedByteCount: value.encodedByteCount, timedFrameCount: value.submittedFrameCount, lastEncodingDuration: value.lastEncodingDuration,
                totalEncodingDuration: value.totalEncodingDuration, maximumEncodingDuration: value.maximumEncodingDuration)
        } else if let value = aomEncoder?.statistics {
            statistics = .init(backend: "libaom", measurement: "Native encode call", submittedFrameCount: value.submittedFrameCount, outputPacketCount: value.outputPacketCount,
                encodedByteCount: value.encodedByteCount, timedFrameCount: value.submittedFrameCount, lastEncodingDuration: value.lastEncodingDuration,
                totalEncodingDuration: value.totalEncodingDuration, maximumEncodingDuration: value.maximumEncodingDuration)
        } else { statistics = .empty(backend: "Unknown", measurement: "Native encode call") }
        return .init(frames: .init(samples: frames), statistics: statistics)
    }
}
