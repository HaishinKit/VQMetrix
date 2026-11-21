@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import VQMetrix

@Suite(.serialized)
@MainActor
struct LiveBenchmarkTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
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
        engine.start(input: url, settings: BenchmarkSettings(codec: .h264, bitrate: 1_000_000, evaluationModel: .legacy), duration: 8)
        try await wait { engine.decodedFrames >= 5 || !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.isRunning)
        let hevc = BenchmarkSettings(codec: .hevc, bitrate: 600_000, profile: .main10, resolution: .p360, evaluationModel: .legacy)
        engine.apply(hevc)
        try await wait { (engine.activeSettings == hevc && engine.decodedFrames >= 15) || !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.sourceSample != nil)
        #expect(engine.decodedSample != nil)
        let lowerRate = BenchmarkSettings(codec: .hevc, bitrate: 200_000, evaluationModel: .legacy)
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
                let settings = BenchmarkSettings(codec: codec, bitrate: 800_000, profile: profile, resolution: .p180, evaluationModel: .legacy)
                engine.start(input: url, settings: settings, duration: 0.8)
                try await wait { !engine.isRunning }
                #expect(engine.errorMessage == nil, "\(codec.rawValue) \(profile.rawValue): \(engine.errorMessage ?? "")")
                let report = try #require(engine.reports.first)
                #expect(report.encodedWidth == 320 && report.encodedHeight == 180)
                #expect(report.referenceWidth == 640 && report.referenceHeight == 360)
                #expect(report.encodedProfile == profile.rawValue)
                #expect(report.encodedCodec == codec.codecType)
                #expect(report.evaluatedFrames > 0)
                let statistics = try #require(report.encoderStatistics)
                #expect(statistics.outputPacketCount == UInt64(report.encodedFrames))
                #expect(statistics.encodedByteCount == UInt64(report.encodedBytes))
                #expect(statistics.timedFrameCount > 0 && statistics.totalEncodingDuration > 0)
                #expect(engine.encoderStatistics == statistics)
                let realtime = try #require(report.realtimeStatistics)
                #expect(realtime.mode == "live" && realtime.timedFrames == report.decodedFrames)
                #expect(realtime.maximumLatencyMilliseconds >= realtime.meanLatencyMilliseconds)
                #expect(realtime.pendingFrames == 0)
                #expect(engine.realtimeStatistics == realtime)
                #expect(engine.scores.allSatisfy { $0.score.isFinite })
                if let output = engine.resultDirectory { try? FileManager.default.removeItem(at: output) }
            }
        }
    }

    @Test(arguments: VMAFModel.allCases) func offlineReplayAndSearchPreserveAllFrames(model: VMAFModel) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("search.mp4")
        try await fixture(input)
        let engine = LiveBenchmark()
        engine.start(input: input, settings: BenchmarkSettings(codec: .h264, bitrate: 500_000, evaluationModel: model), duration: 0.4,
            offline: true, outputDirectory: directory.appendingPathComponent("trial"))
        try await wait { !engine.isRunning }
        #expect(engine.errorMessage == nil)
        #expect(engine.inputFrames == 4 && engine.scores.count == 4)
        let search = BitrateSearch()
        var configuration = BitrateSearchConfiguration()
        configuration.target = 0; configuration.sampleSeconds = 0.4
        search.start(input: input, settings: BenchmarkSettings(codec: .h264, bitrate: 500_000, evaluationModel: model), configuration: configuration, engine: engine)
        try await wait { !search.isRunning }
        let report = try #require(search.report)
        #expect(report.status == .lowerBoundReached && report.recommendedBitrate == configuration.minimumBitrate)
        #expect(report.trials.count == 2 && report.trials.allSatisfy { $0.frames == 4 })
        #expect(report.trials.last?.confirmation == true)
        let output = try #require(search.resultDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let saved = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: output.appendingPathComponent("live-summary.json")))
        #expect(saved.completeEvaluation && saved.bitrateSearch?.referenceSHA256.count == 64)
        #expect(saved.model == model.rawValue)
        #expect(saved.segments.first?.evaluationBitDepth == model.bitDepth)
        #expect(saved.bitrateSearch?.settings.evaluationModel == model)
        #expect(saved.bitrateSearch?.settings.bitrate == configuration.minimumBitrate)
        let html = ReportRenderer.html(run: saved, annotation: RunAnnotation(), date: Date(), id: "search", language: .english, targetScore: 99)
        #expect(html.contains("Confirmation") && html.contains("Target mean VMAF: 0.000"))
        #expect(!html.contains("Target VMAF: 99.00"))
        let cancelled = BitrateSearch()
        cancelled.start(input: input, settings: BenchmarkSettings(codec: .h264, bitrate: 500_000, evaluationModel: model), configuration: configuration, engine: engine)
        cancelled.cancel()
        try await wait { !cancelled.isRunning }
        #expect(cancelled.report?.status == .cancelled && cancelled.report?.recommendedBitrate == nil)
        if let cancelledOutput = cancelled.resultDirectory {
            defer { try? FileManager.default.removeItem(at: cancelledOutput) }
            let stopped = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: cancelledOutput.appendingPathComponent("live-summary.json")))
            #expect(stopped.stoppedByUser && !stopped.completeEvaluation)
        }
    }

    @Test(arguments: [BenchmarkCodec.vp8, .vp9, .av1]) func softwareSearchSavesStatistics(codec: BenchmarkCodec) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("software-search.mp4")
        try await fixture(input)
        let engine = LiveBenchmark()
        let search = BitrateSearch()
        var configuration = BitrateSearchConfiguration()
        configuration.target = 0; configuration.sampleSeconds = 0.4
        search.start(input: input, settings: .init(codec: codec, bitrate: 500_000, resolution: .p180, evaluationModel: .legacy), configuration: configuration, engine: engine)
        try await wait { !search.isRunning }
        let report = try #require(search.report)
        #expect(report.status == .lowerBoundReached)
        let output = try #require(search.resultDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let saved = try await HistoryStore(root: output.deletingLastPathComponent()).detail(output).run
        #expect(saved.completeEvaluation && saved.inputFrames == 4 && saved.evaluatedFrames == 4)
        let statistics = try #require(saved.segments.first?.encoderStatistics)
        #expect(statistics.submittedFrameCount == 4 && statistics.outputPacketCount == 4)
        #expect(statistics.encodedByteCount > 0 && statistics.totalEncodingDuration > 0)
        #expect(saved.segments.first?.unmatchedDecoded == 0)
        #expect(saved.segments.first?.realtimeStatistics?.mode == "offlineReplay")
        #expect(saved.segments.first?.realtimeStatistics?.pendingFrames == 0)
        #expect(ReportRenderer.html(run: saved, annotation: .init(), date: Date(), id: "test", language: .english).contains("Encoder statistics"))
    }

}
