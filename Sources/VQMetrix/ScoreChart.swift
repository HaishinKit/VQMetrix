import Charts
import SwiftUI

private extension ScoreBand {
    func color(_ scheme: ColorScheme) -> Color {
        let hex = (scheme == .dark ? darkColor : lightColor).dropFirst()
        let rgb = UInt32(hex, radix: 16) ?? 0
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct ScoreChart: View, Equatable {
    let points: [QualityPoint]
    let language: AppLanguage
    var targetScore: Double = 90
    @Environment(\.colorScheme) private var scheme
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.targetScore == rhs.targetScore && lhs.points == rhs.points
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("VMAF timeline")).font(.headline)
                Spacer()
                Text(language.text("Updates about once per second · separate segments per setting")).font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(ScoreBandChart.traces(Array(points.suffix(1800)))) { trace in
                    ForEach(trace.vertices) { vertex in
                        LineMark(x: .value(language.text("Time (seconds)"), vertex.pts), y: .value("VMAF", vertex.score),
                            series: .value(language.text("Segment"), trace.id))
                            .foregroundStyle(trace.band.color(scheme))
                            .interpolationMethod(.linear)
                    }
                }
                RuleMark(y: .value(language.text("Target VMAF"), ScoreBandChart.target(targetScore)))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(language.text("Target %@", String(format: "%.1f", ScoreBandChart.target(targetScore))))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYScale(domain: 0...100)
            .chartXAxisLabel(language.text("Time (seconds)"))
            .chartLegend(.hidden)
            .frame(height: 150)
            .overlay {
                if points.isEmpty { Text(language.text("The chart appears when scores are ready.")).foregroundStyle(.secondary) }
            }
            HStack(spacing: 15) {
                ForEach(ScoreBand.allCases.reversed(), id: \.rawValue) { band in
                    Label(band.label, systemImage: "line.diagonal").foregroundStyle(band.color(scheme))
                }
                Spacer()
                Text(language.text("Score bands are working guidelines.")).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }
}

struct ScoreTargetControl: View {
    let language: AppLanguage
    @AppStorage("vmafTargetScore") private var targetScore = 90.0
    private var value: Binding<Double> {
        Binding(get: { ScoreBandChart.target(targetScore) }, set: { targetScore = ScoreBandChart.target($0) })
    }
    var body: some View {
        HStack {
            Text(language.text("Target VMAF"))
            TextField(language.text("Target VMAF"), value: value, format: .number.precision(.fractionLength(1)))
                .frame(width: 60).monospacedDigit()
            Stepper(language.text("Target VMAF"), value: value, in: 0...100, step: 0.5).labelsHidden()
                .fixedSize().accessibilityLabel(language.text("Target VMAF"))
            Text(language.text("Reference line only; measurements are unchanged."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
