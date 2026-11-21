@preconcurrency import AVFoundation
import Combine
import CVMAF
@_spi(VideoQuality) import HaishinKit
import VideoToolbox

package struct QualityPoint: Identifiable, Codable, Sendable, Equatable {
    package let segment: Int
    package let index: Int
    package let pts: Double
    package let score: Double
    package let settings: BenchmarkSettings
    package let latencyMilliseconds: Double
    package var id: String { "\(segment)-\(index)" }
    package var series: String { "\(segment + 1): \(settings.label)" }
}

package struct SegmentReport: Codable, Sendable {
    package let index: Int
    package let settings: BenchmarkSettings
    package let inputFrames: Int
    package let encodedFrames: Int
    package let decodedFrames: Int
    package let evaluatedFrames: Int
    package let evaluationQueueDropped: Int
    package let referenceEvictions: Int
    package let unresolvedReferences: Int
    package let unmatchedDecoded: Int
    package let encodedBytes: Int
    package let encodedCodec: UInt32?
    package let firstPTS: Double?
    package let lastPTS: Double?
    package let meanVMAF: Double?
    package var encodedWidth: Int? = nil
    package var encodedHeight: Int? = nil
    package var encodedProfile: String? = nil
    package var referenceWidth: Int? = nil
    package var referenceHeight: Int? = nil
    package var evaluationScaling: String? = nil
    package var evaluationWidth: Int? = nil
    package var evaluationHeight: Int? = nil
    package var evaluationBitDepth: Int? = nil
}

private struct VideoFrame: @unchecked Sendable { let sample: CMSampleBuffer }
private struct EvaluationPair: @unchecked Sendable {
    let reference: CVPixelBuffer
    let decoded: CVPixelBuffer
    let pts: Double
    let arrived: Double
}

private final class LiveMixerTap: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8? = 0
    let audioTrackId: UInt8? = nil
    let stream: AsyncStream<VideoFrame>
    let continuation: AsyncStream<VideoFrame>.Continuation
    private let lock = NSLock()
    private var accepting = true
    private var received = 0
    private var dropped = 0

    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(8)) }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        received += 1
        if case .dropped = continuation.yield(VideoFrame(sample: sampleBuffer)) { dropped += 1 }
        lock.unlock()
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
    func finish() {
        lock.lock()
        accepting = false
        continuation.finish()
        lock.unlock()
    }
    func counts() -> (received: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (received, dropped)
    }
}

@MainActor
private final class ReplayProgress { var frames = 0; var failure: String? }

@MainActor
private final class CaptureProgress { var lastFrameAt = ProcessInfo.processInfo.systemUptime; var failure: String? }

/// One constant codec/bitrate segment. All VideoToolbox access is on MainActor;
/// feature extraction and prediction run on a separate bounded worker.
@MainActor
private final class LiveSegment {
    let settings: BenchmarkSettings
    let index: Int
    private let replayProgress = ReplayProgress()
    private let encoder = VideoCodecProbe()
    private let decoder = VideoCodecProbe()
    private let pairs: AsyncStream<EvaluationPair>.Continuation
    private let worker: Task<[Double], any Error>
    private var encodedTask: Task<Void, Never>?
    private var decodedTask: Task<Void, Never>?
    private var references: [Int64: VideoFrame] = [:]
    private var inputCount = 0
    private var encodedCount = 0
    private var decodedCount = 0
    private var evaluationDropped = 0
    private var evicted = 0
    private var unmatched = 0
    private var bytes = 0
    private var encodedWidth: Int?
    private var encodedHeight: Int?
    private var encodedProfile: String?
    private var encodingFailure: String?
    private let referenceWidth: Int
    private let referenceHeight: Int
    private var encodedCodec: UInt32?
    private var firstPTS: Double?
    private var lastPTS: Double?
    private let onDecoded: @MainActor (CMSampleBuffer) -> Void

    init(settings: BenchmarkSettings, index: Int, width: Int, height: Int, fps: Float,
         directory: URL, offline: Bool = false, onDecoded: @escaping @MainActor (CMSampleBuffer) -> Void,
         onScores: @escaping @Sendable ([QualityPoint]) async -> Void) {
        self.referenceWidth = width
        self.referenceHeight = height
        self.settings = settings
        self.index = index
        self.onDecoded = onDecoded
        let (stream, continuation) = AsyncStream<EvaluationPair>.makeStream(bufferingPolicy: .bufferingOldest(16))
        pairs = continuation
        let progress = replayProgress
        worker = Task.detached {
            do {
                let evaluator = try VMAFEvaluator(windowFrames: UInt32(max(2, Int(fps.rounded()))), model: settings.evaluationModel, encoding: VMAFEncoding(width: settings.resolution.dimensions(width: width, height: height).width, height: settings.resolution.dimensions(width: width, height: height).height, bitDepth: settings.profile == .main10 ? 10 : 8))
                var timestamps: [(pts: Double, arrived: Double)] = []
                var published = 0
                func points() -> [QualityPoint] {
                    let now = ProcessInfo.processInfo.systemUptime
                    let result = (published..<evaluator.scores.count).map { position in
                        QualityPoint(segment: index, index: position, pts: timestamps[position].pts,
                            score: evaluator.scores[position], settings: settings,
                            latencyMilliseconds: (now - timestamps[position].arrived) * 1000)
                    }
                    published = evaluator.scores.count
                    return result
                }
                let scaler = try EvaluationScaler()
                for await pair in stream {
                    timestamps.append((pair.pts, pair.arrived))
                    _ = try evaluator.submit(reference: pair.reference, decoded: scaler.match(pair.decoded, to: pair.reference))
                    if offline { await MainActor.run { progress.frames += 1 } }
                    let batch = points()
                    if !batch.isEmpty { await onScores(batch) }
                }
                if !timestamps.isEmpty {
                    try evaluator.finish(output: directory.appendingPathComponent("segment-\(index + 1).json").path)
                    let batch = points()
                    if !batch.isEmpty { await onScores(batch) }
                }
                return evaluator.scores
            } catch {
                await MainActor.run { progress.failure = String(describing: error) }
                throw error
            }
        }
        let outputSize = settings.resolution.dimensions(width: width, height: height)
        encoder.settings = VideoCodecSettings(videoSize: CGSize(width: outputSize.width, height: outputSize.height),
            bitRate: settings.bitrate, profileLevel: settings.profile.level(for: settings.codec), scalingMode: .normal,
            allowFrameReordering: false, expectedFrameRate: Double(fps))
        let encoded = encoder.outputStream
        let decoded = decoder.outputStream
        encoder.startRunning()
        decoder.startRunning()
        encodedTask = Task { @MainActor [weak self] in
            for await sample in encoded {
                guard let self else { return }
                self.encodedCount += 1
                self.bytes += sample.totalSampleSize
                if let format = sample.formatDescription {
                    self.encodedCodec = CMFormatDescriptionGetMediaSubType(format)
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                    self.encodedWidth = Int(dimensions.width); self.encodedHeight = Int(dimensions.height)
                    self.encodedProfile = EncodedProfile.read(format)?.rawValue
                    if Int(dimensions.width) != outputSize.width || Int(dimensions.height) != outputSize.height || self.encodedProfile != settings.profile.rawValue {
                        self.encodingFailure = "The encoder did not produce the requested profile or dimensions."
                    }
                }
                self.decoder.append(sample)
            }
        }
        decodedTask = Task { @MainActor [weak self] in
            for await sample in decoded { self?.receive(sample) }
        }
    }

    private func key(_ sample: CMSampleBuffer) -> Int64 {
        CMTimeConvertScale(sample.presentationTimeStamp, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    func append(_ frame: VideoFrame) {
        if references.count >= 60, let oldest = references.keys.min() {
            references.removeValue(forKey: oldest)
            evicted += 1
        }
        references[key(frame.sample)] = frame
        inputCount += 1
        let pts = frame.sample.presentationTimeStamp.seconds - 1
        if firstPTS == nil { firstPTS = pts }
        lastPTS = pts
        encoder.append(frame.sample)
    }

    func appendForReplay(_ frame: VideoFrame) async throws {
        append(frame)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while inputCount - replayProgress.frames >= 8 {
            try Task.checkCancellation()
            if let failure = replayProgress.failure { throw QualityError(failure) }
            guard ContinuousClock.now < deadline else { throw QualityError("Offline encoder or evaluation timed out.") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func receive(_ sample: CMSampleBuffer) {
        decodedCount += 1
        onDecoded(sample)
        guard let ref = references.removeValue(forKey: key(sample))?.sample.imageBuffer,
              let decoded = sample.imageBuffer else {
            unmatched += 1
            return
        }
        let pair = EvaluationPair(reference: ref, decoded: decoded, pts: sample.presentationTimeStamp.seconds - 1,
            arrived: ProcessInfo.processInfo.systemUptime)
        if case .dropped = pairs.yield(pair) { evaluationDropped += 1 }
    }

    func finish() async throws -> SegmentReport {
        defer { encoder.stopRunning(); decoder.stopRunning(); pairs.finish() }
        try encoder.finish()
        await encodedTask?.value
        try decoder.finish()
        await decodedTask?.value
        pairs.finish()
        let scores = try await worker.value
        if let encodingFailure { throw QualityError(encodingFailure) }
        guard inputCount == 0 || !scores.isEmpty else {
            throw QualityError("Could not decode the encoded video. Check codec support.")
        }
        return SegmentReport(index: index, settings: settings, inputFrames: inputCount,
            encodedFrames: encodedCount, decodedFrames: decodedCount, evaluatedFrames: scores.count,
            evaluationQueueDropped: evaluationDropped, referenceEvictions: evicted,
            unresolvedReferences: references.count, unmatchedDecoded: unmatched, encodedBytes: bytes, encodedCodec: encodedCodec,
            firstPTS: firstPTS, lastPTS: lastPTS,
            meanVMAF: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
            encodedWidth: encodedWidth, encodedHeight: encodedHeight, encodedProfile: encodedProfile,
            referenceWidth: referenceWidth, referenceHeight: referenceHeight,
            evaluationScaling: "VideoToolbox normal scaling; \(settings.evaluationModel.bitDepth)-bit SDR VMAF; \(settings.evaluationModel == .v1 ? "short side 1080" : "source dimensions")",
            evaluationWidth: settings.evaluationModel.dimensions(width: referenceWidth, height: referenceHeight).width,
            evaluationHeight: settings.evaluationModel.dimensions(width: referenceWidth, height: referenceHeight).height,
            evaluationBitDepth: settings.evaluationModel.bitDepth)
    }

    func abort() async {
        encoder.stopRunning()
        decoder.stopRunning()
        await encodedTask?.value
        await decodedTask?.value
        pairs.finish()
        _ = await worker.result
    }
}

@MainActor
package final class LiveBenchmark: ObservableObject {
    @Published package private(set) var isRunning = false
    @Published package private(set) var isApplying = false
    @Published package private(set) var status = AppLanguage.system.text("Select an input to begin.")
    @Published package private(set) var sourceSample: CMSampleBuffer?
    @Published package private(set) var decodedSample: CMSampleBuffer?
    @Published package private(set) var scores: [QualityPoint] = []
    @Published package private(set) var reports: [SegmentReport] = []
    @Published package private(set) var activeSettings: BenchmarkSettings?
    @Published package private(set) var activeSegment = 0
    @Published package private(set) var decodedFrames = 0
    @Published package private(set) var inputFrames = 0
    @Published package private(set) var currentPTS = 0.0
    @Published package private(set) var formatLabel = "SDR"
    @Published package private(set) var resultDirectory: URL?
    @Published package private(set) var errorMessage: String?
    package var language = AppLanguage.system {
        didSet { status = language.format(statusKey, arguments: statusArguments.map { language.text($0) }) }
    }
    private var statusKey = "Select an input to begin."
    private var statusArguments: [String] = []
    private func setStatus(_ key: String, _ arguments: String...) {
        statusKey = key
        statusArguments = arguments
        status = language.format(key, arguments: arguments.map { language.text($0) })
    }
    private var startedAtDate: Date?
    private var pending: BenchmarkSettings?
    private var stopRequested = false
    private var offlineReplay = false
    private var runner: Task<Void, Never>?
    private var segment: LiveSegment?

    package init() {}

    package var currentScores: [QualityPoint] { scores.filter { $0.segment == activeSegment } }
    package var latestScore: Double? { currentScores.last?.score }
    package var meanScore: Double? {
        let values = currentScores
        return values.isEmpty ? nil : values.reduce(0) { $0 + $1.score } / Double(values.count)
    }

    package func start(input: URL, settings: BenchmarkSettings, duration: Double, offline: Bool = false, outputDirectory: URL? = nil) {
        guard !isRunning, settings.isValid, duration.isFinite, duration > 0, duration <= 300 else { return }
        scores = []; reports = []; decodedFrames = 0; inputFrames = 0; currentPTS = 0
        sourceSample = nil; decodedSample = nil; errorMessage = nil; resultDirectory = nil
        startedAtDate = Date(); activeSettings = settings; activeSegment = 0; pending = nil; stopRequested = false
        isApplying = false; isRunning = true; setStatus("Preparing video…")
        offlineReplay = offline
        runner = Task { await run(input: input, initialSettings: settings, duration: duration, offline: offline, outputDirectory: outputDirectory) }
    }

    package func apply(_ settings: BenchmarkSettings) {
        guard isRunning, !stopRequested, !offlineReplay, settings.isValid, settings.evaluationModel == activeSettings?.evaluationModel else { return }
        pending = settings
        isApplying = true
        setStatus("Applying settings…")
    }

    package func stop() {
        guard isRunning else { return }
        stopRequested = true
        setStatus("Finalizing scores…")
    }

    private func newSegment(settings: BenchmarkSettings, width: Int, height: Int, fps: Float, directory: URL, offline: Bool = false) -> LiveSegment {
        LiveSegment(settings: settings, index: activeSegment, width: width, height: height, fps: fps,
            directory: directory, offline: offline, onDecoded: { [weak self] sample in
                self?.decodedSample = sample
                self?.decodedFrames += 1
            }, onScores: { [weak self] batch in
                await MainActor.run { self?.scores.append(contentsOf: batch) }
            })
    }

    private func run(input: URL, initialSettings: BenchmarkSettings, duration: Double, offline: Bool, outputDirectory: URL?) async {
        let mixer = MediaMixer(captureSessionMode: .manual)
        let tap = LiveMixerTap()
        var tapTask: Task<Void, Never>?
        var processed = 0
        var forwardFailure: String?
        var reader: AVAssetReader?
        var startedMixer = false
        defer {
            reader?.cancelReading()
            segment = nil
            runner = nil
            isRunning = false
            isApplying = false
        }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = outputDirectory ?? base.appendingPathComponent("VQMetrix/Results/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resultDirectory = directory
            let asset = AVURLAsset(url: input)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let format = try await track.load(.formatDescriptions).first else { throw QualityError("No video track was found.") }
            let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
            if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
               transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
                throw QualityError("Only SDR video is supported. Choose an SDR input.")
            }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            let width = Int(size.width), height = Int(size.height)
            let fps = try await track.load(.nominalFrameRate)
            guard width >= 64, height >= 64, width <= 1920, height <= 1080,
                  width % 2 == 0, height % 2 == 0, fps > 0, fps <= 60 else {
                throw QualityError("Use even SDR dimensions from 64x64 through 1920x1080, at up to 60 fps.")
            }
            formatLabel = String(format: "%d × %d · %.2f fps · SDR", width, height, fps)
            let source = try AVAssetReader(asset: asset)
            reader = source
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            source.add(output)
            guard source.startReading() else { throw source.error ?? QualityError("Could not read the video.") }
            segment = newSegment(settings: initialSettings, width: width, height: height, fps: fps, directory: directory, offline: offline)
            await mixer.addOutput(tap)
            await mixer.startRunning()
            startedMixer = true
            tapTask = Task { @MainActor [weak self] in
                for await frame in tap.stream {
                    self?.sourceSample = frame.sample
                    if offline {
                        do { try await self?.segment?.appendForReplay(frame) }
                        catch { forwardFailure = String(describing: error); tap.finish(); break }
                    } else { self?.segment?.append(frame) }
                    processed += 1
                }
            }
            let clock = ContinuousClock()
            var origin: CMTime?
            var lastPTS: Double?
            var playbackStart: ContinuousClock.Instant?
            setStatus("Measuring · %@", initialSettings.label)
            while !stopRequested, let sample = output.copyNextSampleBuffer() {
                guard sample.presentationTimeStamp.isValid, sample.presentationTimeStamp.isNumeric else {
                    throw QualityError("Invalid input timestamp.")
                }
                if origin == nil { origin = sample.presentationTimeStamp }
                let elapsed = (sample.presentationTimeStamp - origin!).seconds
                guard elapsed >= 0, lastPTS == nil || elapsed > lastPTS! else {
                    throw QualityError("Input timestamps must increase.")
                }
                if elapsed >= duration { break }
                if let settings = pending {
                    pending = nil
                    if settings != activeSettings {
                        let deadline = clock.now.advanced(by: .seconds(2))
                        while processed + tap.counts().dropped < inputFrames, clock.now < deadline {
                            try await Task.sleep(for: .milliseconds(2))
                        }
                        guard processed + tap.counts().dropped == inputFrames else { throw QualityError("Timed out waiting for mixer output.") }
                        if let segment { reports.append(try await segment.finish()) }
                        activeSegment += 1
                        activeSettings = settings
                        decodedSample = nil
                        segment = newSegment(settings: settings, width: width, height: height, fps: fps, directory: directory)
                        // Do not burst queued source frames after a configuration drain.
                        playbackStart = clock.now.advanced(by: .seconds(-elapsed))
                    }
                    isApplying = pending != nil
                    setStatus("Measuring · %@", activeSettings?.label ?? "")
                }
                if offline {
                    let deadline = clock.now.advanced(by: .seconds(25))
                    while processed < inputFrames {
                        if let forwardFailure { throw QualityError(forwardFailure) }
                        guard clock.now < deadline else { throw QualityError("Offline mixer timed out.") }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                } else {
                    if playbackStart == nil { playbackStart = clock.now }
                    try await clock.sleep(until: playbackStart!.advanced(by: .seconds(elapsed)))
                }
                if stopRequested { break }
                var timing = CMSampleTimingInfo(duration: sample.duration,
                    presentationTimeStamp: CMTime(seconds: elapsed + 1, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
                var retimed: CMSampleBuffer?
                try check(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed), "input timing")
                guard let retimed else { throw QualityError("Could not normalize input timestamps.") }
                await mixer.append(retimed)
                inputFrames += 1
                currentPTS = elapsed
                lastPTS = elapsed
            }
            if source.status == .failed { throw source.error ?? QualityError("Could not read the video.") }
            let deadline = clock.now.advanced(by: .seconds(offline ? 25 : 2))
            while processed + tap.counts().dropped < inputFrames, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            await mixer.removeOutput(tap)
            await mixer.stopRunning()
            startedMixer = false
            tap.continuation.finish()
            await tapTask?.value
            if let forwardFailure { throw QualityError(forwardFailure) }
            if let segment { reports.append(try await segment.finish()) }
            try saveRun(input: input.path, sourceKind: "file", sourceName: input.lastPathComponent,
                mixerDropped: tap.counts().dropped, undelivered: inputFrames - tap.counts().received)
        } catch {
            errorMessage = String(describing: error)
            setStatus("Measurement failed: %@", String(describing: error))
            if startedMixer {
                await mixer.removeOutput(tap)
                await mixer.stopRunning()
            }
            tap.continuation.finish()
            await tapTask?.value
            await segment?.abort()
            try? saveRun(input: input.path, sourceKind: "file", sourceName: input.lastPathComponent,
                mixerDropped: tap.counts().dropped, undelivered: inputFrames - tap.counts().received, failure: String(describing: error))
        }
    }
}

package struct SavedRun: Codable, Sendable {
    package let input: String
    package let model: String
    package let libvmafVersion: String
    package let inputFrames: Int
    package let evaluatedFrames: Int
    package let completeEvaluation: Bool
    package let stoppedByUser: Bool
    package let mixerQueueDropped: Int
    package let mixerUndelivered: Int
    package let segments: [SegmentReport]
    package let scores: [QualityPoint]
    package var sourceKind: String? = nil
    package var sourceName: String? = nil
    package var createdAt: Date? = nil
    package var format: String? = nil
    package var failure: String? = nil
    package var senderPerformance: [SenderPerformance]? = nil
    var bitrateSearch: BitrateSearchReport? = nil

}

package struct CameraInfo: Identifiable, Sendable {
    package let id: String
    package let name: String
}

package struct CameraTimeline {
    private var origin: CMTime?
    private var lastPTS: Double?
    package init() {}
    package mutating func normalize(_ sample: CMSampleBuffer) throws -> (sample: CMSampleBuffer, elapsed: Double) {
        guard sample.presentationTimeStamp.isValid, sample.presentationTimeStamp.isNumeric else {
            throw QualityError("Invalid input timestamp.")
        }
        if origin == nil { origin = sample.presentationTimeStamp }
        let elapsed = (sample.presentationTimeStamp - origin!).seconds
        guard elapsed >= 0, lastPTS == nil || elapsed > lastPTS! else {
            throw QualityError("Input timestamps must increase.")
        }
        var timing = CMSampleTimingInfo(duration: sample.duration,
            presentationTimeStamp: CMTime(seconds: elapsed + 1, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        try check(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output), "camera timing")
        guard let output else { throw QualityError("Could not normalize input timestamps.") }
        lastPTS = elapsed
        return (output, elapsed)
    }
}

extension LiveBenchmark {
    package static func cameras() -> [CameraInfo] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    package func start(cameraID: String, name: String, settings: BenchmarkSettings, duration: Double) {
        guard !isRunning, settings.isValid, duration.isFinite, duration > 0, duration <= 300 else { return }
        scores = []; reports = []; decodedFrames = 0; inputFrames = 0; currentPTS = 0
        sourceSample = nil; decodedSample = nil; errorMessage = nil; resultDirectory = nil
        startedAtDate = Date(); activeSettings = settings; activeSegment = 0; pending = nil; stopRequested = false
        isApplying = false; isRunning = true; setStatus("Requesting camera access…")
        runner = Task { await runCamera(id: cameraID, name: name, settings: settings, duration: duration) }
    }

    private func saveRun(input: String, sourceKind: String, sourceName: String,
                         mixerDropped: Int, undelivered: Int, failure: String? = nil) throws {
        guard let resultDirectory else { return }
        let complete = failure == nil && scores.count == inputFrames
        var summary = SavedRun(input: input, model: (activeSettings?.evaluationModel ?? .v1).rawValue,
            libvmafVersion: String(cString: vmaf_version()), inputFrames: inputFrames,
            evaluatedFrames: scores.count, completeEvaluation: complete, stoppedByUser: stopRequested,
            mixerQueueDropped: mixerDropped, mixerUndelivered: max(0, undelivered), segments: reports, scores: scores)
        summary.sourceKind = sourceKind
        summary.sourceName = sourceName
        summary.createdAt = startedAtDate ?? Date()
        summary.format = formatLabel
        summary.failure = failure
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep Foundation's default date encoding for backward-compatible decoding.
        try encoder.encode(summary).write(to: resultDirectory.appendingPathComponent("live-summary.json"), options: .atomic)
        try encoder.encode(RunMetadata(run: summary)).write(to: resultDirectory.appendingPathComponent("history.json"), options: .atomic)
        if failure == nil {
            if complete { setStatus("Complete · evaluated all %@ frames.", String(inputFrames)) }
            else { setStatus("Complete · evaluated %@/%@ frames (some skipped).", String(scores.count), String(inputFrames)) }
        }
        NotificationCenter.default.post(name: .benchmarkSaved, object: nil)
    }

    private func runCamera(id: String, name: String, settings: BenchmarkSettings, duration: Double) async {
        let mixer = MediaMixer(captureSessionMode: .single)
        let tap = LiveMixerTap()
        var watchdog: Task<Void, Never>?
        var streamFailure: String?
        var lastReceivedAt = ProcessInfo.processInfo.systemUptime
        defer {
            watchdog?.cancel()
            runner = nil
            segment = nil
            isRunning = false
            isApplying = false
        }
        do {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard authorized else { throw QualityError("Camera access is disabled. Allow VQMetrix in System Settings > Privacy & Security > Camera.") }
            if stopRequested { return }
            guard let device = AVCaptureDevice(uniqueID: id), device.isConnected else {
                throw QualityError("The selected camera is unavailable. Refresh the camera list.")
            }
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent("VQMetrix/Results/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resultDirectory = directory
            await mixer.setSessionPreset(.vga640x480)
            await mixer.setVideoOrientation(.landscapeRight)
            try await mixer.attachVideo(device) { unit in try unit.setFrameRate(30) }
            await mixer.addOutput(tap)
            await mixer.startRunning()
            setStatus("Waiting for camera frames…")
            let startedAt = ProcessInfo.processInfo.systemUptime
            watchdog = Task { @MainActor [weak self] in
                var lastCount = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self else { tap.finish(); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let count = tap.counts().received
                    if count != lastCount { lastReceivedAt = now; lastCount = count }
                    if self.stopRequested || now - startedAt >= duration { tap.finish(); return }
                    if now - lastReceivedAt > 8 {
                        streamFailure = "The camera stopped delivering frames. Check its connection and try again."
                        tap.finish()
                        return
                    }
                }
            }
            var timeline = CameraTimeline()
            var dimensions: (width: Int, height: Int)?
            var fps: Float = 30
            for await frame in tap.stream {
                if stopRequested { break }
                let normalized = try timeline.normalize(frame.sample)
                if normalized.elapsed >= duration { break }
                guard let image = normalized.sample.imageBuffer else { continue }
                let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
                guard width >= 64, height >= 64, width <= 1920, height <= 1080, width % 2 == 0, height % 2 == 0 else {
                    throw QualityError("Use even SDR dimensions from 64x64 through 1920x1080, at up to 60 fps.")
                }
                if let dimensions, dimensions.width != width || dimensions.height != height {
                    throw QualityError("The camera format changed. Restart measurement.")
                }
                if dimensions == nil {
                    dimensions = (width, height)
                    let interval = frame.sample.duration.seconds
                    if interval.isFinite, interval > 0 { fps = Float(min(60, max(1, 1 / interval))) }
                    formatLabel = String(format: "%d × %d · %.2f fps · SDR", width, height, fps)
                    segment = newSegment(settings: settings, width: width, height: height, fps: fps, directory: directory)
                    setStatus("Measuring · %@", settings.label)
                }
                if let changed = pending {
                    pending = nil
                    if changed != activeSettings {
                        if let segment { reports.append(try await segment.finish()) }
                        activeSegment += 1
                        activeSettings = changed
                        decodedSample = nil
                        segment = newSegment(settings: changed, width: width, height: height, fps: fps, directory: directory)
                    }
                    isApplying = pending != nil
                    setStatus("Measuring · %@", activeSettings?.label ?? "")
                }
                sourceSample = normalized.sample
                currentPTS = normalized.elapsed
                inputFrames = tap.counts().received
                segment?.append(VideoFrame(sample: normalized.sample))
            }
            watchdog?.cancel()
            tap.finish()
            await mixer.removeOutput(tap)
            await mixer.stopRunning()
            try? await mixer.attachVideo(nil)
            inputFrames = tap.counts().received
            if let segment { reports.append(try await segment.finish()) }
            if let streamFailure { throw QualityError(streamFailure) }
            guard dimensions != nil || stopRequested else {
                throw QualityError("The camera stopped delivering frames. Check its connection and try again.")
            }
            try saveRun(input: "camera:\(id)", sourceKind: "camera", sourceName: name,
                mixerDropped: tap.counts().dropped, undelivered: 0)
        } catch {
            watchdog?.cancel()
            tap.finish()
            await mixer.removeOutput(tap)
            await mixer.stopCapturing()
            await mixer.stopRunning()
            try? await mixer.attachVideo(nil)
            await segment?.abort()
            inputFrames = tap.counts().received
            errorMessage = String(describing: error)
            setStatus("Measurement failed: %@", String(describing: error))
            try? saveRun(input: "camera:\(id)", sourceKind: "camera", sourceName: name,
                mixerDropped: tap.counts().dropped, undelivered: 0, failure: String(describing: error))
        }
    }
}

package extension Notification.Name {
    static let benchmarkSaved = Notification.Name("VQMetrix.benchmarkSaved")
}

extension LiveBenchmark {
    /// Record once, then replay exactly this file for every search candidate.
    /// ProRes is a high-quality acquisition reference, not a raw-camera quality claim.
    package static func recordSearchReference(cameraID: String, duration: Double, output: URL,
        cancelled: @escaping @MainActor () -> Bool, preview: @escaping @MainActor (CMSampleBuffer) -> Void) async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { throw QualityError("Camera access is disabled. Allow VQMetrix in System Settings > Privacy & Security > Camera.") }
        if cancelled() { throw CancellationError() }
        guard let device = AVCaptureDevice(uniqueID: cameraID), device.isConnected else {
            throw QualityError("The selected camera is unavailable. Refresh the camera list.")
        }
        let mixer = MediaMixer(captureSessionMode: .single)
        let tap = LiveMixerTap()
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var watchdog: Task<Void, Never>?
        var timeline = CameraTimeline()
        let progress = CaptureProgress()
        var written = 0
        func stopCapture() async {
            watchdog?.cancel(); tap.finish()
            await mixer.removeOutput(tap); await mixer.stopCapturing(); await mixer.stopRunning()
            try? await mixer.attachVideo(nil)
        }
        do {
            await mixer.setSessionPreset(.vga640x480)
            try await mixer.attachVideo(device) { try $0.setFrameRate(30) }
            await mixer.addOutput(tap); await mixer.startRunning()
            watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    if cancelled() { tap.finish(); return }
                    if ProcessInfo.processInfo.systemUptime - progress.lastFrameAt > 12 {
                        progress.failure = "The camera stopped delivering frames. Check its connection and try again."
                        tap.finish(); return
                    }
                }
            }
            for await frame in tap.stream {
                if cancelled() { throw CancellationError() }
                progress.lastFrameAt = ProcessInfo.processInfo.systemUptime
                let normalized = try timeline.normalize(frame.sample)
                if normalized.elapsed >= duration { break }
                preview(normalized.sample)
                guard let image = normalized.sample.imageBuffer else { continue }
                if writer == nil {
                    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
                    guard width >= 64, height >= 64, width <= 1920, height <= 1080, width % 2 == 0, height % 2 == 0 else {
                        throw QualityError("Use even SDR dimensions from 64x64 through 1920x1080, at up to 60 fps.")
                    }
                    let value = try AVAssetWriter(outputURL: output, fileType: .mov)
                    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: width, AVVideoHeightKey: height]
                    guard value.canApply(outputSettings: settings, forMediaType: .video) else { throw QualityError("Could not prepare the reference sample.") }
                    let sink = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: frame.sample.formatDescription)
                    sink.expectsMediaDataInRealTime = true
                    guard value.canAdd(sink) else { throw QualityError("Could not prepare the reference sample.") }
                    value.add(sink)
                    guard value.startWriting() else { throw value.error ?? QualityError("Could not prepare the reference sample.") }
                    value.startSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
                    writer = value; input = sink
                }
                if let input, input.isReadyForMoreMediaData {
                    guard input.append(normalized.sample) else { throw writer?.error ?? QualityError("Could not prepare the reference sample.") }
                    written += 1
                }
            }
            await stopCapture()
            if cancelled() { throw CancellationError() }
            if let failure = progress.failure { throw QualityError(failure) }
            guard let writer, written > 0 else { throw QualityError("Could not prepare the reference sample.") }
            input?.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? QualityError("Could not prepare the reference sample.") }
        } catch {
            await stopCapture(); writer?.cancelWriting(); throw error
        }
    }

    package func previewReference(_ sample: CMSampleBuffer) { sourceSample = sample; decodedSample = nil }
}
