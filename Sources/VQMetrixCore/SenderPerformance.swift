import Foundation

package struct EncodingPerformance: Codable, Sendable {
    package struct ResourceSample: Codable, Sendable {
        package let elapsedMs: Double
        package let appCpuTimeMs: Double?
        package let memoryBytes: Int64?
        package let thermalState: String
        package let nativeThermalStatus: Int?
    }
    package struct FrameTiming: Codable, Sendable {
        package let ptsUs: Int64
        package let inputElapsedMs: Double
        package let outputElapsedMs: Double
        package let latencyMs: Double
    }
    package let schemaVersion: Int
    package let platform: String
    package let mode: String
    package let wallTimeMs: Double
    package let firstOutputMs: Double?
    package let frameCount: Int
    package let throughputFps: Double
    package let videoDurationMs: Double
    package let realtimeSpeed: Double
    package let meanLatencyMs: Double?
    package let p95LatencyMs: Double?
    package let appCpuTimeMs: Double?
    package let appCpuCores: Double?
    package let memoryKind: String?
    package let sampledPeakMemoryBytes: Int64?
    package let sampleIntervalMs: Int?
    package let samples: [ResourceSample]?
    package let frameTimings: [FrameTiming]?

    func validate(frames: Int, fps: Int) throws {
        let values = [wallTimeMs,throughputFps,videoDurationMs,realtimeSpeed] +
            [firstOutputMs,meanLatencyMs,p95LatencyMs,appCpuTimeMs,appCpuCores].compactMap { $0 }
        guard schemaVersion == 1, ["android","ios","macos"].contains(platform), ["offlineReplay","live"].contains(mode),
              frameCount == frames, values.allSatisfy({ $0.isFinite && $0 >= 0 }), wallTimeMs > 0, throughputFps > 0, realtimeSpeed > 0,
              abs(throughputFps - Double(frames)*1000/wallTimeMs) < 0.01,
              abs(realtimeSpeed - videoDurationMs/wallTimeMs) < 0.01,
              firstOutputMs.map({ $0 <= wallTimeMs + 1 }) != false,
              abs(videoDurationMs - Double(frames)*1000/Double(fps)) < 2,
              (samples?.count ?? 0) <= 1000, sampledPeakMemoryBytes.map({ $0 >= 0 }) != false else {
            throw QualityError("Invalid sender performance summary")
        }
        for sample in samples ?? [] {
            guard sample.elapsedMs.isFinite, sample.elapsedMs >= 0, sample.elapsedMs <= wallTimeMs + 1,
                  sample.appCpuTimeMs.map({ $0.isFinite && $0 >= 0 }) != false,
                  sample.memoryBytes.map({ $0 >= 0 }) != false,
                  ["nominal","fair","serious","critical","unknown"].contains(sample.thermalState) else { throw QualityError("Invalid resource sample") }
        }
        if let timings = frameTimings {
            guard timings.count == frames else { throw QualityError("Performance frame count mismatch") }
            for (index, timing) in timings.enumerated() {
                guard timing.ptsUs == Int64(index)*1_000_000/Int64(fps),
                      [timing.inputElapsedMs,timing.outputElapsedMs,timing.latencyMs].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      timing.outputElapsedMs >= timing.inputElapsedMs, timing.outputElapsedMs <= wallTimeMs + 1,
                      abs(timing.latencyMs - (timing.outputElapsedMs - timing.inputElapsedMs)) < 0.01 else { throw QualityError("Invalid frame performance timing") }
            }
        }
    }
    package var thermalSummary: String {
        var changes: [String] = []
        for sample in samples ?? [] where changes.last != sample.thermalState { changes.append(sample.thermalState) }
        return changes.isEmpty ? "—" : changes.joined(separator: " → ")
    }
}

package struct SenderPerformance: Codable, Sendable {
    package let file: String
    package let settings: BenchmarkSettings
    package let metrics: EncodingPerformance
    package var codecName: String? = nil
    package var hardwareAccelerated: Bool? = nil
    package var actualBitrate: Double? = nil
}

extension SenderPerformance {
    static func html(_ items: [SenderPerformance], language: AppLanguage) -> String {
        guard !items.isEmpty else { return "" }
        func t(_ key:String) -> String { ReportRenderer.escape(language.text(key)) }
        func number(_ value:Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(2)).locale(language.locale)) } ?? "—" }
        let rows = items.map { item in
            let m = item.metrics
            return "<tr><td>\(ReportRenderer.escape(item.settings.label))<br>\(ReportRenderer.escape(item.codecName ?? ""))</td><td>\(number(m.wallTimeMs))</td><td>\(number(m.throughputFps))</td><td>\(number(m.p95LatencyMs))</td><td>\(number(m.appCpuCores))</td><td>\(number(m.sampledPeakMemoryBytes.map{Double($0)/1_048_576}))</td><td>\(ReportRenderer.escape(m.thermalSummary))</td></tr>"
        }.joined()
        let charts = items.map { item in
            let values = item.metrics.frameTimings ?? []
            guard !values.isEmpty else { return "" }
            let maximum = max(1, values.map(\.latencyMs).max() ?? 1)
            let duration = max(1, Double(values.last?.ptsUs ?? 1)/1_000_000)
            let path = values.map { String(format:"%.2f,%.2f",45+Double($0.ptsUs)/1_000_000/duration*810,180-$0.latencyMs/maximum*150) }.joined(separator:" ")
            return "<h3>\(ReportRenderer.escape(item.settings.label)) · \(t("Input-to-output latency"))</h3><svg viewBox=\"0 0 900 220\" role=\"img\" aria-label=\"\(t("Input-to-output latency"))\"><polyline fill=\"none\" stroke=\"#0077cc\" stroke-width=\"2\" points=\"\(path)\"/><text x=\"5\" y=\"25\">\(number(maximum)) ms</text><text x=\"45\" y=\"205\">0 s</text><text x=\"850\" y=\"205\" text-anchor=\"end\">\(number(duration)) s</text></svg>"
        }.joined()
        return "<h2>\(t("Sender performance"))</h2><p class=\"warning\">\(t("Offline replay speed is not a guarantee of live performance. CPU and memory cover the whole app, including capture and instrumentation."))</p><table><thead><tr><th>\(t("Settings"))</th><th>\(t("Encoding time")) (ms)</th><th>fps</th><th>p95 (ms)</th><th>\(t("App CPU (cores)"))</th><th>\(t("Sampled peak memory")) (MiB)</th><th>\(t("Thermal state"))</th></tr></thead><tbody>\(rows)</tbody></table>\(charts)"
    }
}
