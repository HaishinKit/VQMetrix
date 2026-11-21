import SwiftUI

struct RealtimeStatisticsView: View {
    let statistics: RealtimeStatistics
    let language: AppLanguage
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.text("Frame delivery")).font(.headline)
                    Spacer()
                    Text(language.text(statistics.mode == "live" ? "Live measurement" : "Offline throughput")).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 12) {
                    metric("Expected / output FPS", String(format: "%.1f / %.1f", statistics.expectedFPS, statistics.outputFPS))
                    metric("Mixer input FPS", String(format: "%.1f", statistics.inputFPS))
                    metric("Mean output FPS", String(format: "%.1f", statistics.averageOutputFPS))
                    metric("Mean decode latency", String(format: "%.2f ms", statistics.meanLatencyMilliseconds))
                    metric("Maximum decode latency", String(format: "%.2f ms", statistics.maximumLatencyMilliseconds))
                    metric("Frames over one interval", "\(statistics.framesOverInterval) / \(statistics.timedFrames)")
                    metric("Pending / peak frames", "\(statistics.pendingFrames) / \(statistics.maximumPendingFrames)")
                    metric("Mixer dropped frames", String(statistics.mixerDroppedFrames))
                }
                Text(language.text("Output FPS uses the last second. Latency includes conversion, queues, encoding and decoding. Exceeding one frame interval does not itself mean a dropped frame."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(4)
        }
    }
    private func metric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(language.text(key)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).textSelection(.enabled)
        }
    }
}
