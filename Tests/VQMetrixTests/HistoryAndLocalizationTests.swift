import AVFoundation
import Foundation
import Testing
@testable import VQMetrix

struct HistoryAndLocalizationTests {
    private func run(statistics: EncoderStatistics? = nil) -> SavedRun {
        let settings = BenchmarkSettings(codec: .h264, bitrate: 1_000_000)
        let segment = SegmentReport(index: 0, settings: settings, inputFrames: 2, encodedFrames: 2,
            decodedFrames: 2, evaluatedFrames: 1, evaluationQueueDropped: 1, referenceEvictions: 0,
            unresolvedReferences: 0, unmatchedDecoded: 0, encodedBytes: 1000,
            encodedCodec: kCMVideoCodecType_H264, firstPTS: 0, lastPTS: 0.1, meanVMAF: 90, encoderStatistics: statistics)
        return SavedRun(input: "/video/<source>.mp4", model: "vmaf_v0.6.1", libvmafVersion: "3.2.0",
            inputFrames: 2, evaluatedFrames: 1, completeEvaluation: false, stoppedByUser: true,
            mixerQueueDropped: 0, mixerUndelivered: 0, segments: [segment],
            scores: [QualityPoint(segment: 0, index: 0, pts: 0, score: 90, settings: settings, latencyMilliseconds: 100)])
    }

    @Test func historyPersistsAnnotationsAndExportsEscapedReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("run-1")
        let invalid = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        let measurement = run()
        // Legacy summary without the lightweight index must still appear.
        try encoder.encode(measurement).write(to: directory.appendingPathComponent("live-summary.json"))
        try Data("invalid json".utf8).write(to: invalid.appendingPathComponent("live-summary.json"))
        let store = HistoryStore(root: root)
        let first = try await store.list()
        #expect(first.entries.count == 1)
        #expect(first.unreadable == 1)
        #expect(first.entries.first?.mean == 90)
        #expect(first.entries.first?.complete == false)
        let annotation = RunAnnotation(title: "Trial <script>alert(1)</script>", notes: "A&B\n低ビットレート")
        try await store.saveAnnotation(annotation, for: directory)
        let detail = try await HistoryStore(root: root).detail(directory)
        #expect(detail.annotation.title == annotation.title)
        #expect(detail.annotation.notes == annotation.notes)
        let english = try await store.report(directory, language: .english)
        let japanese = try await store.report(directory, language: .japanese)
        #expect(english.contains("Partial evaluation"))
        #expect(english.contains("&lt;script&gt;"))
        #expect(!english.contains("<script>"))
        #expect(english.contains("A&amp;B"))
        #expect(japanese.contains("一部フレーム未評価"))
        #expect(japanese.contains("区間ごとのエンコード設定"))
        #expect(english.contains("<svg"))
        let targeted = try await store.report(directory, language: .english, targetScore: 92.5)
        #expect(targeted.contains("92.50"))
        #expect(targeted.contains("stroke-dasharray"))
        // New index and legacy summary yield the same result.
        try encoder.encode(RunMetadata(run: measurement)).write(to: directory.appendingPathComponent("history.json"))
        #expect(try await store.list().entries.first?.title == annotation.title)
        try Data("broken cache".utf8).write(to: directory.appendingPathComponent("history.json"))
        #expect(try await store.list().entries.count == 1)
        await #expect(throws: QualityError.self) {
            try await store.saveAnnotation(annotation, for: root.deletingLastPathComponent())
        }
    }

    @Test func encoderStatisticsSurviveHistoryReloadAndReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("statistics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var statistics = EncoderStatistics.empty(backend: "libaom", measurement: "Native encode call")
        statistics.submittedFrameCount = 2
        statistics.recordOutput(bytes: 4321, duration: 0.001)
        statistics.recordOutput(bytes: 1234, duration: 0.003)
        let measurement = run(statistics: statistics)
        try JSONEncoder().encode(measurement).write(to: directory.appendingPathComponent("live-summary.json"))
        try JSONEncoder().encode(RunMetadata(run: measurement)).write(to: directory.appendingPathComponent("history.json"))
        let store = HistoryStore(root: root)
        #expect(try await store.list().entries.count == 1)
        #expect(try await store.detail(directory).run.segments.first?.encoderStatistics == statistics)
        let html = try await store.report(directory, language: .english)
        #expect(html.contains("Encoder statistics") && html.contains("libaom") && html.contains("5555"))
        #expect(html.contains("Native encode call") && html.contains("2.00"))
        #expect(try await store.report(directory, language: .japanese).contains("エンコーダー統計"))
        #expect(try JSONDecoder().decode(SavedRun.self, from: JSONEncoder().encode(run())).segments.first?.encoderStatistics == nil)
    }

    @Test func translationsHaveMatchingKeysAndPlaceholders() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VQMetrix/Resources")
        let english = try PropertyListSerialization.propertyList(from: Data(contentsOf: source.appendingPathComponent("en.lproj/Localizable.strings")), format: nil) as? [String: String]
        let japanese = try PropertyListSerialization.propertyList(from: Data(contentsOf: source.appendingPathComponent("ja.lproj/Localizable.strings")), format: nil) as? [String: String]
        #expect(Set(english?.keys.map { $0 } ?? []) == Set(japanese?.keys.map { $0 } ?? []))
        for (key, value) in english ?? [:] {
            #expect(value.components(separatedBy: "%@").count == japanese?[key]?.components(separatedBy: "%@").count)
        }
        #expect(AppLanguage.japanese.text("Measurement") == "計測")
        #expect(AppLanguage.english.text("Camera") == "Camera")
        #expect(AppLanguage.japanese.text("Camera") == "カメラ")
        #expect(AppLanguage.japanese.text("%@ seconds", "30") == "30 秒")
    }

    @Test func cameraTimelinePreservesIntervalsAndRejectsRepeatedPTS() throws {
        var image: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &image), "test image")
        let pixel = try #require(image)
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format), "format")
        let description = try #require(format)
        func sample(_ time: CMTime) throws -> CMSampleBuffer {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var output: CMSampleBuffer?
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &output), "sample")
            return try #require(output)
        }
        var timeline = CameraTimeline()
        let first = try timeline.normalize(sample(CMTime(value: 300_000, timescale: 30)))
        let second = try timeline.normalize(sample(CMTime(value: 300_001, timescale: 30)))
        #expect(first.sample.presentationTimeStamp.seconds == 1)
        #expect(abs(second.elapsed - 1 / 30.0) < 0.000001)
        #expect(abs(second.sample.presentationTimeStamp.seconds - (1 + 1 / 30.0)) < 0.000001)
        #expect(throws: QualityError.self) { try timeline.normalize(sample(CMTime(value: 300_001, timescale: 30))) }
    }
}
