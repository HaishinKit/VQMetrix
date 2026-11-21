import SwiftUI

struct EncoderStatisticsView: View {
    let statistics: EncoderStatistics
    let language: AppLanguage
    private func milliseconds(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.text("Encoder statistics")).font(.headline)
                    Spacer()
                    Text(statistics.backend).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading, spacing: 12) {
                    metric("Last encode", milliseconds(statistics.lastEncodingDuration))
                    metric("Mean encode", milliseconds(statistics.averageEncodingDuration))
                    metric("Maximum encode", milliseconds(statistics.maximumEncodingDuration))
                    metric("Total encode", String(format: "%.2f s", statistics.totalEncodingDuration))
                    metric("Submitted / packets", "\(statistics.submittedFrameCount) / \(statistics.outputPacketCount)")
                    metric("Encoded payload", ByteCountFormatter.string(fromByteCount: Int64(clamping: statistics.encodedByteCount), countStyle: .file))
                }
                Text(language.text(statistics.measurement == "Native encode call" ? "Native encode time excludes conversion and copying; it is not CPU utilization." : "Submission-to-output time includes asynchronous encoder queues; it is not native encode time or CPU utilization."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(4)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(language.text(label)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).textSelection(.enabled)
        }
    }
}
