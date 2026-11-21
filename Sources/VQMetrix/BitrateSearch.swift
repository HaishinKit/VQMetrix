@preconcurrency import AVFoundation
import Combine
import CryptoKit
import Foundation

struct BitrateSearchConfiguration: Codable, Sendable {
    var target = 90.0
    var minimumBitrate = 200_000
    var maximumBitrate = 10_000_000
    var precision = 50_000
    var sampleSeconds = 5.0
    var maximumTrials = 10
    var isValid: Bool {
        target.isFinite && (0...100).contains(target) && minimumBitrate > 0 && maximumBitrate <= 100_000_000 &&
        minimumBitrate < maximumBitrate && precision >= 1_000 && precision <= maximumBitrate - minimumBitrate &&
        sampleSeconds.isFinite && sampleSeconds > 0 && sampleSeconds <= 30 && (3...16).contains(maximumTrials)
    }
}

struct BitrateSearchTrial: Codable, Identifiable, Sendable {
    let id: Int
    let bitrate: Int
    let mean: Double
    let minimum: Double
    let actualBitrate: Double?
    let frames: Int
    let wallSeconds: Double
    let confirmation: Bool
    let directory: String
}

enum BitrateSearchStatus: String, Codable, Sendable {
    case verified, lowerBoundReached, trialLimitReached, unreachable, unstable, cancelled, failed
    var message: String {
        switch self {
        case .verified: "Verified bitrate estimate"
        case .lowerBoundReached: "The minimum bitrate already meets the target."
        case .trialLimitReached: "Verified candidate; the search limit was reached."
        case .unreachable: "The target was not reached within the bitrate range."
        case .unstable: "The candidate did not meet the target on confirmation."
        case .cancelled: "Bitrate search cancelled."
        case .failed: "Bitrate search failed."
        }
    }
}

struct BitrateSearchReport: Codable, Sendable {
    let configuration: BitrateSearchConfiguration
    let settings: BenchmarkSettings
    let referenceSHA256: String
    let trials: [BitrateSearchTrial]
    let status: BitrateSearchStatus
    let recommendedBitrate: Int?
    let lowerFailingBitrate: Int?
    let note: String?
}

/// Finds the lowest observed passing candidate in a bounded bracket. VMAF is not
/// assumed to be strictly monotonic; every observation is retained and the chosen
/// candidate must independently pass once more before it is recommended.
@MainActor
enum BitrateSearchAlgorithm {
    static func run(_ config: BitrateSearchConfiguration,
                    measure: (Int, Bool) async throws -> BitrateSearchTrial) async throws -> (BitrateSearchStatus, Int?, Int?) {
        guard config.isValid else { throw QualityError("Invalid bitrate search settings.") }
        var observations: [BitrateSearchTrial] = []
        func evaluate(_ bitrate: Int, _ confirmation: Bool = false) async throws -> BitrateSearchTrial {
            let trial = try await measure(bitrate, confirmation)
            guard trial.bitrate == bitrate, trial.mean.isFinite, trial.minimum.isFinite, trial.frames > 0,
                  observations.first.map({ $0.frames == trial.frames }) ?? true else {
                throw QualityError("Search trials must evaluate the same complete reference frames.")
            }
            observations.append(trial)
            return trial
        }
        let low = try await evaluate(config.minimumBitrate)
        if low.mean >= config.target {
            let confirmation = try await evaluate(low.bitrate, true)
            return confirmation.mean >= config.target ? (.lowerBoundReached, low.bitrate, nil) : (.unstable, nil, nil)
        }
        let high = try await evaluate(config.maximumBitrate)
        guard high.mean >= config.target else { return (.unreachable, nil, high.bitrate) }
        var lower = low.bitrate, upper = high.bitrate
        while upper - lower > config.precision && observations.count < config.maximumTrials - 1 {
            let midpoint = lower + (upper - lower) / 2
            let candidate = config.minimumBitrate + (midpoint - config.minimumBitrate) / config.precision * config.precision
            guard candidate > lower && candidate < upper else { break }
            let trial = try await evaluate(candidate)
            if trial.mean >= config.target { upper = candidate } else { lower = candidate }
        }
        let best = observations.filter { $0.mean >= config.target }.map(\.bitrate).min() ?? upper
        let confirmation = try await evaluate(best, true)
        guard confirmation.mean >= config.target else { return (.unstable, nil, lower) }
        return (upper - lower <= config.precision ? .verified : .trialLimitReached, best, lower)
    }
}

@MainActor
final class BitrateSearch: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var trials: [BitrateSearchTrial] = []
    @Published private(set) var report: BitrateSearchReport?
    @Published private(set) var resultDirectory: URL?
    @Published private(set) var currentBitrate: Int?
    @Published private(set) var isConfirming = false
    @Published private(set) var phase = ""
    private var cancelRequested = false
    private var activeEngine: LiveBenchmark?
    private var exporter: AVAssetExportSession?
    private var task: Task<Void, Never>?

    func clear() { guard !isRunning else { return }; report = nil; trials = []; resultDirectory = nil }
    func cancel() { cancelRequested = true; activeEngine?.stop(); exporter?.cancelExport() }

    func start(input: URL?, camera: CameraInfo? = nil, settings: BenchmarkSettings, configuration: BitrateSearchConfiguration, engine: LiveBenchmark) {
        guard !isRunning, !engine.isRunning, settings.isValid, configuration.isValid, input != nil || camera != nil, camera == nil || configuration.sampleSeconds <= 10 else { return }
        clear(); cancelRequested = false; isRunning = true; phase = "Preparing a fixed reference sample…"
        activeEngine = engine
        task = Task { await run(input: input, camera: camera, settings: settings, configuration: configuration, engine: engine) }
    }

    private func run(input: URL?, camera: CameraInfo?, settings: BenchmarkSettings, configuration: BitrateSearchConfiguration, engine: LiveBenchmark) async {
        defer { isRunning = false; currentBitrate = nil; isConfirming = false; activeEngine = nil; exporter = nil; task = nil }
        var directory: URL?
        var referenceHash = ""
        var runs: [Int: SavedRun] = [:]
        var status = BitrateSearchStatus.failed
        var recommended: Int?, lower: Int?, failure: String?
        let createdAt = Date()
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VQMetrix/Results/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = root; resultDirectory = root
            let reference = root.appendingPathComponent("reference.mov")
            if cancelRequested { throw CancellationError() }
            if let input {
                let asset = AVURLAsset(url: input)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0, let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw QualityError("Could not prepare the reference sample.")
                }
                exporter = export
                export.outputURL = reference; export.outputFileType = .mov
                export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(configuration.sampleSeconds, duration), preferredTimescale: 600))
                await export.export()
                if cancelRequested { throw CancellationError() }
                guard export.status == .completed else { throw export.error ?? QualityError("Could not prepare the reference sample.") }
                exporter = nil
            } else if let camera {
                phase = "Recording a fixed camera sample…"
                try await LiveBenchmark.recordSearchReference(cameraID: camera.id, duration: configuration.sampleSeconds, output: reference,
                    cancelled: { self.cancelRequested }, preview: { engine.previewReference($0) })
            }
            referenceHash = try Self.hash(reference)
            let outcome = try await BitrateSearchAlgorithm.run(configuration) { bitrate, confirmation in
                if self.cancelRequested { throw CancellationError() }
                self.currentBitrate = bitrate; self.isConfirming = confirmation
                self.phase = confirmation ? "Confirming the candidate…" : "Measuring bitrate candidates…"
                let index = self.trials.count + 1
                let relative = "trials/\(index)"
                let trialDirectory = root.appendingPathComponent(relative, isDirectory: true)
                var candidate = settings; candidate.bitrate = bitrate
                let started = ProcessInfo.processInfo.systemUptime
                engine.start(input: reference, settings: candidate, duration: configuration.sampleSeconds, offline: true, outputDirectory: trialDirectory)
                while engine.isRunning {
                    if self.cancelRequested { engine.stop() }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if self.cancelRequested { throw CancellationError() }
                if let error = engine.errorMessage { throw QualityError(error) }
                let run = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: trialDirectory.appendingPathComponent("live-summary.json")))
                guard run.completeEvaluation, !run.stoppedByUser, run.inputFrames > 0, run.inputFrames == run.evaluatedFrames,
                      run.mixerQueueDropped == 0, run.mixerUndelivered == 0, run.segments.count == 1,
                      let mean = run.segments[0].meanVMAF, let minimum = run.scores.map(\.score).min() else {
                    throw QualityError("Search trials must evaluate the same complete reference frames.")
                }
                let segment = run.segments[0]
                guard segment.encodedFrames == run.inputFrames, segment.decodedFrames == run.inputFrames,
                      segment.evaluationQueueDropped == 0, segment.referenceEvictions == 0,
                      segment.unresolvedReferences == 0, segment.unmatchedDecoded == 0 else {
                    throw QualityError("Search trials must evaluate the same complete reference frames.")
                }
                let fps = (try await AVURLAsset(url: reference).loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 0
                let interval = (segment.lastPTS ?? 0) - (segment.firstPTS ?? 0) + (fps > 0 ? 1 / Double(fps) : 0)
                let actual = interval > 0 ? Double(segment.encodedBytes) * 8 / interval : nil
                let trial = BitrateSearchTrial(id: index, bitrate: bitrate, mean: mean, minimum: minimum, actualBitrate: actual,
                    frames: run.inputFrames, wallSeconds: ProcessInfo.processInfo.systemUptime - started, confirmation: confirmation, directory: relative)
                self.trials.append(trial); runs[index] = run
                return trial
            }
            (status, recommended, lower) = outcome
        } catch {
            status = cancelRequested || error is CancellationError ? .cancelled : .failed
            failure = status == .failed ? String(describing: error) : nil
        }
        var resultSettings = settings; resultSettings.bitrate = recommended ?? trials.last?.bitrate ?? settings.bitrate
        let result = BitrateSearchReport(configuration: configuration, settings: resultSettings, referenceSHA256: referenceHash,
            trials: trials, status: status, recommendedBitrate: recommended, lowerFailingBitrate: lower, note: failure)
        report = result; phase = status.message
        guard let directory else { return }
        do {
            let selected = recommended.flatMap { bitrate in trials.last(where: { $0.bitrate == bitrate && $0.confirmation }) }
            let representative = selected.flatMap { runs[$0.id] } ?? trials.last.flatMap { runs[$0.id] }
            var saved = SavedRun(input: input?.path ?? "camera:\(camera?.id ?? "")", model: settings.evaluationModel.rawValue,
                libvmafVersion: representative?.libvmafVersion ?? "", inputFrames: representative?.inputFrames ?? 0,
                evaluatedFrames: representative?.evaluatedFrames ?? 0, completeEvaluation: recommended != nil,
                stoppedByUser: status == .cancelled, mixerQueueDropped: representative?.mixerQueueDropped ?? 0,
                mixerUndelivered: representative?.mixerUndelivered ?? 0, segments: representative?.segments ?? [], scores: representative?.scores ?? [])
            saved.sourceKind = "bitrate-search"; saved.sourceName = "VMAF \(configuration.target) · \(input?.lastPathComponent ?? camera?.name ?? "Camera")"
            saved.createdAt = createdAt; saved.format = representative?.format; saved.failure = failure; saved.bitrateSearch = result
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: directory.appendingPathComponent("live-summary.json"), options: .atomic)
            try encoder.encode(RunMetadata(run: saved)).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
            NotificationCenter.default.post(name: .benchmarkSaved, object: nil)
        } catch {
            phase = "Could not save bitrate search results."
            report = BitrateSearchReport(configuration: configuration, settings: resultSettings, referenceSHA256: referenceHash,
                trials: trials, status: .failed, recommendedBitrate: nil, lowerFailingBitrate: lower, note: phase)
        }
    }

    private static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension BitrateSearchReport {
    func html(language: AppLanguage) -> String {
        func t(_ key: String) -> String { ReportRenderer.escape(language.text(key)) }
        func n(_ value: Double) -> String { String(format: "%.3f", value) }
        let rows = trials.map { trial in
            "<tr><td>\(trial.confirmation ? t("Confirmation") : String(trial.id))</td><td>\(n(Double(trial.bitrate) / 1_000_000))</td><td>\(trial.actualBitrate.map { n($0 / 1_000_000) } ?? "—")</td><td>\(n(trial.mean))</td><td>\(n(trial.minimum))</td><td>\(trial.frames)</td><td>\(t(trial.mean >= configuration.target ? "Target met" : "Below target"))</td></tr>"
        }.joined()
        return """
        <h2>\(t("Estimate bitrate for target VMAF"))</h2><p><strong>\(t(status.message))</strong></p>
        <p>\(t("Target mean VMAF")): \(n(configuration.target))<br>\(t("Estimated bitrate")): \(recommendedBitrate.map { n(Double($0) / 1_000_000) + " Mbps" } ?? "—")<br>\(t("Codec")): \(ReportRenderer.escape(settings.codec.rawValue + " / " + settings.profile.rawValue + " / " + settings.resolution.rawValue))<br>\(t("Target bitrate")): \(n(Double(configuration.minimumBitrate) / 1_000_000))–\(n(Double(configuration.maximumBitrate) / 1_000_000)) Mbps · \(t("Precision kbps")): \(configuration.precision / 1_000)<br>\(t("Maximum trials")): \(configuration.maximumTrials)</p>
        <p class="meta">\(t("Results apply only to this sample. A confirmed estimate does not guarantee a global minimum or live-network suitability."))</p>
        \(note.map { "<p class=\"warning\">" + t($0) + "</p>" } ?? "")
        <table><thead><tr><th>\(t("Trial"))</th><th>\(t("Target bitrate")) (Mbps)</th><th>\(t("Actual bitrate")) (Mbps)</th><th>\(t("Mean VMAF"))</th><th>\(t("Minimum VMAF"))</th><th>\(t("Evaluated frames"))</th><th>\(t("Result"))</th></tr></thead><tbody>\(rows)</tbody></table>
        <p class="meta">Reference SHA-256: \(ReportRenderer.escape(referenceSHA256))</p>
        """
    }
}
