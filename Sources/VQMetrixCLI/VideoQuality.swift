@preconcurrency import AVFoundation
import CVMAF
import VQMetrixCore
@_spi(VideoQuality) import HaishinKit
import VideoToolbox

struct Frame: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

struct FramePair: @unchecked Sendable {
    let reference: CVPixelBuffer
    let decoded: CVPixelBuffer
    let pts: Double
    let receivedAt: Double
}

final class MixerTap: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8? = 0
    let audioTrackId: UInt8? = nil
    let stream: AsyncStream<Frame>
    let continuation: AsyncStream<Frame>.Continuation
    private let lock = NSLock()
    private var received = 0
    private var dropped = 0

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(8))
    }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        lock.lock()
        received += 1
        if case .dropped = continuation.yield(Frame(buffer: sampleBuffer)) { dropped += 1 }
        lock.unlock()
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
    func counts() -> (received: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (received, dropped)
    }
}

struct Options {
    var input: String
    var duration = 10.0
    var bitRate = 2_000_000
    var output = "video-quality.json"

    var summaryURL: URL {
        URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("summary.json")
    }

    init(_ args: [String]) throws {
        guard let first = args.first, !first.hasPrefix("--") else {
            throw QualityError("Usage: vqmetrix INPUT [--duration SECONDS] [--bitrate BPS] [--output FILE.json]")
        }
        input = first
        var index = 1
        while index < args.count {
            guard index + 1 < args.count else { throw QualityError("Missing value for \(args[index])") }
            switch args[index] {
            case "--duration":
                guard let value = Double(args[index + 1]), value.isFinite, value > 0, value <= 300 else {
                    throw QualityError("Duration must be in (0, 300] seconds")
                }
                duration = value
            case "--bitrate":
                guard let value = Int(args[index + 1]), value > 0, value <= 100_000_000 else {
                    throw QualityError("Bitrate must be in 1...100000000 bps")
                }
                bitRate = value
            case "--output": output = args[index + 1]
            default: throw QualityError("Unknown option: \(args[index])")
            }
            index += 2
        }
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        guard inputURL != URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath(),
              inputURL != summaryURL.standardizedFileURL.resolvingSymlinksInPath(),
              summaryURL.standardizedFileURL != URL(fileURLWithPath: output).standardizedFileURL else {
            throw QualityError("Output must differ from input")
        }
    }
}

struct WorkerResult: Sendable {
    let count: Int
    let mean: Double
    let processingSeconds: Double
    let meanQueueSeconds: Double
    let meanScoreLatencyMilliseconds: Double
    let frames: [ScoredFrame]
}

struct ScoredFrame: Codable, Sendable {
    let pts: Double
    let evaluationMilliseconds: Double
    let queueMilliseconds: Double
    var scoreLatencyMilliseconds: Double?
}

@MainActor
final class Measurement {
    let encoder = VideoCodecProbe()
    let decoder = VideoCodecProbe()
    var references: [Int64: Frame] = [:]
    var encodedBytes = 0
    var encodedCount = 0
    var decodedCount = 0
    var referenceEvictions = 0
    var unmatched = 0
    var evaluationDropped = 0
    var submitted = 0
    var lastPTS: Int64?
    let pairs: AsyncStream<FramePair>
    let pairContinuation: AsyncStream<FramePair>.Continuation

    init() {
        // Allow a short burst while a window's predictions are finalized.
        (pairs, pairContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(16))
    }

    func key(_ buffer: CMSampleBuffer) -> Int64 {
        CMTimeConvertScale(buffer.presentationTimeStamp, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    func encode(_ frame: Frame) {
        let id = key(frame.buffer)
        if let lastPTS, id <= lastPTS { return }
        lastPTS = id
        if references.count >= 60, let oldest = references.keys.min() {
            references.removeValue(forKey: oldest)
            referenceEvictions += 1
        }
        references[id] = frame
        submitted += 1
        encoder.append(frame.buffer)
    }

    func decode(_ buffer: CMSampleBuffer) {
        encodedBytes += buffer.totalSampleSize
        encodedCount += 1
        decoder.append(buffer)
    }

    func evaluate(_ buffer: CMSampleBuffer) {
        decodedCount += 1
        guard let reference = references.removeValue(forKey: key(buffer))?.buffer.imageBuffer,
              let decoded = buffer.imageBuffer else {
            unmatched += 1
            return
        }
        let pair = FramePair(reference: reference, decoded: decoded,
            pts: buffer.presentationTimeStamp.seconds - 1, receivedAt: ProcessInfo.processInfo.systemUptime)
        if case .dropped = pairContinuation.yield(pair) { evaluationDropped += 1 }
    }
}

@main
struct VQMetrix {
    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do {
            guard #available(macOS 13.0, *) else { throw QualityError("VQMetrix requires macOS 13 or later") }
            if CommandLine.arguments.dropFirst() == ["--version"] {
                print("VQMetrix prototype; libvmaf \(String(cString: vmaf_version())); model \(VMAFEvaluator.modelVersion)")
                return
            }
            if CommandLine.arguments.dropFirst() == ["--help"] {
                print("Usage: vqmetrix INPUT [--duration SECONDS] [--bitrate BPS] [--output FILE.json]")
                return
            }
            try await run(Options(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("VQMetrix: \(error)\n".utf8))
            exit(1)
        }
    }

    @available(macOS 13.0, *)
    @MainActor
    static func run(_ options: Options) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: options.input))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw QualityError("No video track")
        }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw QualityError("Missing video format") }
        let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
           transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            throw QualityError("This prototype supports SDR input only")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width >= 64, height >= 64, width <= 1920, height <= 1080, width % 2 == 0, height % 2 == 0 else {
            throw QualityError("Use even SDR dimensions between 64x64 and 1920x1080; no implicit scaling is performed")
        }
        let fps = try await track.load(.nominalFrameRate)
        guard fps > 0, fps <= 60 else { throw QualityError("Use input with a nominal frame rate in (0, 60]") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? QualityError("Cannot start reader") }
        let measurement = Measurement()
        measurement.encoder.settings = VideoCodecSettings(
            videoSize: CGSize(width: width, height: height), bitRate: options.bitRate,
            profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String,
            allowFrameReordering: false, expectedFrameRate: Double(fps))
        let encoded = measurement.encoder.outputStream
        let decoded = measurement.decoder.outputStream
        measurement.encoder.startRunning()
        measurement.decoder.startRunning()
        defer {
            reader.cancelReading()
            measurement.encoder.stopRunning()
            measurement.decoder.stopRunning()
            measurement.pairContinuation.finish()
        }
        let encodedTask = Task { @MainActor in
            for await buffer in encoded { measurement.decode(buffer) }
        }
        let decodedTask = Task { @MainActor in
            for await buffer in decoded { measurement.evaluate(buffer) }
        }
        let pairs = measurement.pairs
        let windowFrames = UInt32(max(2, Int(fps.rounded())))
        let worker = Task.detached { () throws -> WorkerResult in
            let evaluator = try VMAFEvaluator(windowFrames: windowFrames)
            var processing = 0.0
            var queue = 0.0
            var frames: [ScoredFrame] = []
            var receivedTimes: [Double] = []
            var timedScores = 0
            var lastPrint = 0.0
            for await pair in pairs {
                let start = ProcessInfo.processInfo.systemUptime
                let score = try evaluator.submit(reference: pair.reference, decoded: pair.decoded)
                let end = ProcessInfo.processInfo.systemUptime
                processing += end - start
                queue += start - pair.receivedAt
                frames.append(ScoredFrame(pts: pair.pts, evaluationMilliseconds: (end - start) * 1000,
                    queueMilliseconds: (start - pair.receivedAt) * 1000))
                receivedTimes.append(pair.receivedAt)
                for index in timedScores..<evaluator.scores.count {
                    frames[index].scoreLatencyMilliseconds = (end - receivedTimes[index]) * 1000
                }
                timedScores = evaluator.scores.count
                if let score, end - lastPrint >= 1 {
                    let scorePTS = frames[evaluator.scores.count - 1].pts
                    print(String(format: "PTS %.2fs  VMAF %.2f  evaluation %.1fms  queue %.1fms", scorePTS, score,
                        (end - start) * 1000, (start - pair.receivedAt) * 1000))
                    lastPrint = end
                }
            }
            let finishStart = ProcessInfo.processInfo.systemUptime
            try evaluator.finish(output: options.output)
            let finishEnd = ProcessInfo.processInfo.systemUptime
            processing += finishEnd - finishStart
            for index in timedScores..<evaluator.scores.count {
                frames[index].scoreLatencyMilliseconds = (finishEnd - receivedTimes[index]) * 1000
            }
            let scores = evaluator.scores
            return WorkerResult(count: scores.count, mean: scores.reduce(0, +) / Double(scores.count),
                processingSeconds: processing, meanQueueSeconds: queue / Double(scores.count),
                meanScoreLatencyMilliseconds: frames.compactMap(\.scoreLatencyMilliseconds).reduce(0, +) / Double(scores.count),
                frames: frames)
        }
        let mixer = MediaMixer(captureSessionMode: .manual)
        let tap = MixerTap()
        await mixer.addOutput(tap)
        await mixer.startRunning()
        let tapTask = Task { @MainActor in
            for await frame in tap.stream { measurement.encode(frame) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var firstPTS: CMTime?
        var lastPTS: CMTime?
        var inputCount = 0
        print("H.264 \(width)x\(height) @ \(fps)fps, \(options.bitRate)bps; libvmaf \(String(cString: vmaf_version())), \(VMAFEvaluator.modelVersion)")
        do {
            while let sample = output.copyNextSampleBuffer() {
                let pts = sample.presentationTimeStamp
                guard pts.isValid, pts.isNumeric else { throw QualityError("Invalid input timestamp") }
                if firstPTS == nil { firstPTS = pts }
                let elapsed = (pts - firstPTS!).seconds
                guard elapsed >= 0 else { throw QualityError("Input timestamps must be increasing") }
                if elapsed >= options.duration { break }
                try await clock.sleep(until: start.advanced(by: .seconds(elapsed)))
                // VideoCodec accepts strictly positive timestamps. Use a common
                // 1-second origin for the reference and encoded stream.
                var timing = CMSampleTimingInfo(duration: sample.duration,
                    presentationTimeStamp: CMTime(seconds: elapsed + 1, preferredTimescale: 1_000_000_000),
                    decodeTimeStamp: .invalid)
                var retimed: CMSampleBuffer?
                try check(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed), "input timing")
                guard let retimed else { throw QualityError("Cannot normalize input timestamps") }
                await mixer.append(retimed)
                inputCount += 1
                lastPTS = pts
            }
            if reader.status == .failed { throw reader.error ?? QualityError("Reader failed") }
            // A mixer callback is asynchronous. Wait for delivery, with a finite timeout.
            let deadline = clock.now.advanced(by: .seconds(3))
            while tap.counts().received < inputCount, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            await mixer.removeOutput(tap)
            await mixer.stopRunning()
            tap.continuation.finish()
            await tapTask.value
            try measurement.encoder.finish()
            await encodedTask.value
            try measurement.decoder.finish()
            await decodedTask.value
            measurement.pairContinuation.finish()
            let result = try await worker.value
            let mediaSeconds = firstPTS.flatMap { first in lastPTS.map { ($0 - first).seconds + 1 / Double(fps) } } ?? 0
            let summary: [String: Any] = [
                "input": options.input, "width": width, "height": height, "nominalFPS": fps,
                "codec": "H264", "requestedBitrate": options.bitRate,
                "actualBitrate": mediaSeconds > 0 ? Double(measurement.encodedBytes * 8) / mediaSeconds : 0,
                "model": VMAFEvaluator.modelVersion, "libvmafVersion": String(cString: vmaf_version()),
                "evaluationWindowFrames": windowFrames,
                "reference": "MediaMixer track 0, before encoding", "pixelFormat": "YUV420P8 video range",
                "inputFrames": inputCount, "mixerFrames": tap.counts().received, "mixerQueueDropped": tap.counts().dropped,
                "mixerUndelivered": inputCount - tap.counts().received,
                "encoderInputFrames": measurement.submitted, "encodedFrames": measurement.encodedCount,
                "decodedFrames": measurement.decodedCount, "referenceEvictions": measurement.referenceEvictions,
                "unresolvedReferences": measurement.references.count, "unmatchedDecoded": measurement.unmatched,
                "evaluationQueueDropped": measurement.evaluationDropped, "evaluatedFrames": result.count,
                "completeEvaluation": result.count == inputCount,
                "timestampOriginSeconds": 1,
                "meanVMAF": result.mean, "mediaSeconds": mediaSeconds,
                "evaluationFPS": Double(result.count) / result.processingSeconds,
                "meanEvaluationMilliseconds": result.processingSeconds * 1000 / Double(result.count),
                "meanQueueMilliseconds": result.meanQueueSeconds * 1000,
                "meanScoreLatencyMilliseconds": result.meanScoreLatencyMilliseconds,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "host": ProcessInfo.processInfo.hostName,
                "timings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.frames))
            ]
            let summaryURL = options.summaryURL
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: summaryURL, options: .atomic)
            print(String(format: "Mean VMAF %.2f; %d/%d frames evaluated; %.1f evaluation fps", result.mean, result.count, inputCount,
                Double(result.count) / result.processingSeconds))
            print("Results: \(options.output), \(summaryURL.path)")
        } catch {
            await mixer.removeOutput(tap)
            await mixer.stopRunning()
            tap.continuation.finish()
            await tapTask.value
            measurement.encoder.stopRunning()
            measurement.decoder.stopRunning()
            await encodedTask.value
            await decodedTask.value
            measurement.pairContinuation.finish()
            _ = await worker.result
            throw error
        }
    }
}
