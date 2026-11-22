@preconcurrency import AVFoundation
import AOMHaishinKit
import VPXHaishinKit

/// Each uploaded variant is decoded on the evaluation worker, never on the UI actor.
final class UploadVideoInput {
    let codec: BenchmarkCodec
    let profile: BenchmarkProfile
    private let reader: AVAssetReader?
    private let trackOutput: AVAssetReaderTrackOutput?
    private let ivf: IVFUploadInput?

    init(url: URL, variant: CaptureManifest.Variant, reference: CaptureManifest.Reference) async throws {
        guard let codec = variant.benchmarkCodec else { throw QualityError("Unsupported uploaded codec") }
        self.codec = codec
        if codec.isSoftware {
            ivf = try IVFUploadInput(url: url, codec: codec, reference: reference)
            profile = codec.defaultProfile
            reader = nil; trackOutput = nil
        } else {
            ivf = nil
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw QualityError("MP4 has no video track") }
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, CMFormatDescriptionGetMediaSubType(descriptions[0]) == codec.codecType else {
                throw QualityError("MP4 codec differs from manifest")
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(descriptions[0])
            guard dimensions.width == reference.width, dimensions.height == reference.height else {
                throw QualityError("MP4 dimensions differ from reference")
            }
            profile = EncodedProfile.read(descriptions[0]) ?? codec.defaultProfile
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw QualityError("Cannot decode uploaded video") }
            reader.add(output)
            guard reader.startReading() else { throw QualityError("Cannot start video decoder") }
            self.reader = reader; trackOutput = output
        }
    }

    deinit { reader?.cancelReading() }

    func next() throws -> CMSampleBuffer? {
        if let ivf { return try ivf.next() }
        return trackOutput?.copyNextSampleBuffer()
    }

    func finish() throws {
        if let ivf { try ivf.finish(); return }
        guard trackOutput?.copyNextSampleBuffer() == nil, reader?.status == .completed else {
            throw QualityError("Extra frames or incomplete MP4 decode")
        }
    }
}

/// Strict IVF subset: one displayed frame per packet, microsecond CFR timestamps, 8-bit limited-range 4:2:0.
/// Reads a bounded packet at a time, regardless of untrusted packet length fields.
final class IVFUploadInput {
    private let handle: FileHandle
    private let reference: CaptureManifest.Reference
    private let description: CMVideoFormatDescription
    private let aom: AOMVideoDecoder?
    private let vpx: VPXVideoDecoder?
    private var index = 0
    static let maximumPacketBytes = 16 * 1024 * 1024

    init(url: URL, codec: BenchmarkCodec, reference: CaptureManifest.Reference) throws {
        self.reference = reference
        handle = try FileHandle(forReadingFrom: url)
        let header = try Self.read(handle, count: 32)
        let fourCC: String
        switch codec {
        case .av1: fourCC = "AV01"
        case .vp8: fourCC = "VP80"
        case .vp9: fourCC = "VP90"
        default: throw QualityError("IVF requires AV1, VP8, or VP9")
        }
        guard header.prefix(4) == Data("DKIF".utf8), header.integer(at: 4, as: UInt16.self) == 0,
              header.integer(at: 6, as: UInt16.self) == 32, header.subdata(in: 8..<12) == Data(fourCC.utf8),
              header.integer(at: 12, as: UInt16.self) == reference.width,
              header.integer(at: 14, as: UInt16.self) == reference.height,
              header.integer(at: 16, as: UInt32.self) == 1_000_000,
              header.integer(at: 20, as: UInt32.self) == 1,
              header.integer(at: 24, as: UInt32.self) == reference.frameCount,
              header.integer(at: 28, as: UInt32.self) == 0 else { throw QualityError("IVF header differs from manifest") }
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec.codecType,
                                               width: Int32(reference.width), height: Int32(reference.height),
                                               extensions: nil, formatDescriptionOut: &format), "IVF format")
        guard let format else { throw QualityError("Missing IVF format") }
        description = format
        aom = try codec == .av1 ? AOMVideoDecoder() : nil
        vpx = try codec == .av1 ? nil : VPXVideoDecoder(format: codec == .vp8 ? .vp8 : .vp9)
    }

    deinit { try? handle.close(); aom?.invalidate(); vpx?.invalidate() }

    func next() throws -> CMSampleBuffer? {
        guard index < reference.frameCount else { return nil }
        let header = try Self.read(handle, count: 12)
        let length = Int(header.integer(at: 0, as: UInt32.self))
        let pts = Int64(index) * 1_000_000 / Int64(reference.fpsNumerator)
        guard length > 0, length <= Self.maximumPacketBytes else { throw QualityError("IVF packet exceeds size limit") }
        guard header.integer(at: 4, as: UInt64.self) == UInt64(pts) else { throw QualityError("IVF timestamps differ from reference") }
        let bytes = try Self.read(handle, count: length)
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: length, flags: 0, blockBufferOut: &block), "IVF packet buffer")
        guard let block else { throw QualityError("Missing IVF packet buffer") }
        try bytes.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length), "IVF packet copy")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(reference.fpsNumerator)),
                                       presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = length
        var packet: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &packet), "IVF sample")
        guard let packet else { throw QualityError("Missing IVF sample") }
        let samples: [CMSampleBuffer]
        if let aom { samples = try aom.decode(packet) }
        else if let vpx { samples = try vpx.decode(packet) }
        else { throw QualityError("Missing IVF decoder") }
        guard samples.count == 1, let sample = samples.first, let image = sample.imageBuffer,
              CVPixelBufferGetWidth(image) == reference.width, CVPixelBufferGetHeight(image) == reference.height,
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw QualityError("IVF decoded frame count, dimensions, or pixel range differs from reference")
        }
        index += 1
        return sample
    }

    func finish() throws {
        guard index == reference.frameCount, (try handle.read(upToCount: 1))?.isEmpty != false else {
            throw QualityError("Extra frames or incomplete IVF decode")
        }
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else { throw QualityError("Truncated IVF data") }
        return data
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}
