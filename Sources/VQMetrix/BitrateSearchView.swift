import SwiftUI

struct BitrateSearchControls: View {
    @ObservedObject var search: BitrateSearch
    let language: AppLanguage
    let canStart: Bool
    let measurementRunning: Bool
    let isCamera: Bool
    let start: (BitrateSearchConfiguration) -> Void
    let useEstimate: (Int) -> Void
    @AppStorage("vmafTargetScore") private var target = 90.0
    @State private var expanded = false
    @State private var minimumMbps = 0.2
    @State private var maximumMbps = 10.0
    @State private var precisionKbps = 50.0
    @State private var seconds = 5
    @State private var maximumTrials = 10

    private var configuration: BitrateSearchConfiguration? {
        guard minimumMbps.isFinite, maximumMbps.isFinite, precisionKbps.isFinite,
              minimumMbps > 0, maximumMbps <= 100, minimumMbps < maximumMbps,
              precisionKbps >= 1, precisionKbps <= 100_000 else { return nil }
        let value = BitrateSearchConfiguration(target: target, minimumBitrate: Int((minimumMbps * 1_000_000).rounded()),
            maximumBitrate: Int((maximumMbps * 1_000_000).rounded()), precision: Int((precisionKbps * 1_000).rounded()),
            sampleSeconds: Double(seconds), maximumTrials: maximumTrials)
        return value.isValid ? value : nil
    }
    var body: some View {
        GroupBox {
            DisclosureGroup(language.text("Estimate bitrate for target VMAF"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("Find a bitrate that meets the sample's mean VMAF target. Codec, profile, and resolution stay fixed."))
                        .font(.callout).foregroundStyle(.secondary)
                    ScoreTargetControl(language: language, isSearch: true).disabled(search.isRunning)
                    HStack(spacing: 16) {
                        numberField("Minimum Mbps", value: $minimumMbps)
                        numberField("Maximum Mbps", value: $maximumMbps)
                        numberField("Precision kbps", value: $precisionKbps)
                    }.disabled(search.isRunning)
                    HStack(spacing: 24) {
                        Stepper(language.text("Sample: %@ seconds", String(seconds)), value: $seconds, in: 1...(isCamera ? 10 : 30))
                        Stepper(language.text("Maximum trials: %@", String(maximumTrials)), value: $maximumTrials, in: 3...16)
                    }.disabled(search.isRunning)
                    Text(language.text(isCamera
                        ? "A fixed ProRes camera sample is recorded once and reused. The reference is retained with the results."
                        : "The beginning of the video is saved as a fixed sample and reused for every candidate."))
                        .font(.caption).foregroundStyle(.secondary)
                    if search.isRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(language.text(search.phase))
                            if let rate = search.currentBitrate { Text(String(format: "%.3f Mbps", Double(rate) / 1_000_000)).monospacedDigit() }
                            Spacer()
                            Text(language.text("Completed trials: %@", String(search.trials.count)))
                            Button(language.text("Cancel search"), action: search.cancel)
                        }
                    } else {
                        HStack {
                            Button(language.text("Estimate bitrate")) { if let configuration { start(configuration) } }
                                .buttonStyle(.borderedProminent).disabled(!canStart || measurementRunning || configuration == nil)
                            if configuration == nil { Text(language.text("Check the target, bitrate range, and precision.")).foregroundStyle(.secondary) }
                            else if !canStart { Text(language.text("Choose a video file or camera above.")).foregroundStyle(.secondary) }
                            Spacer()
                            if let bitrate = search.report?.recommendedBitrate {
                                Button(language.text("Use estimate")) { useEstimate(bitrate) }
                            }
                        }
                    }
                    if let report = search.report { BitrateSearchResultView(report: report, language: language) }
                    else if !search.trials.isEmpty { BitrateSearchTrialsView(trials: search.trials, target: target, language: language) }
                }.padding(.top, 10)
            }
        }
        .onChange(of: search.isRunning) { if $0 { expanded = true } }
        .onChange(of: isCamera) { if $0 { seconds = min(10, seconds) } }
    }
    private func numberField(_ key: String, value: Binding<Double>) -> some View {
        HStack {
            Text(language.text(key))
            TextField(language.text(key), value: value, format: .number).frame(width: 75)
        }
    }
}

struct BitrateSearchResultView: View {
    let report: BitrateSearchReport
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text(report.status.message)).font(.headline)
            if let bitrate = report.recommendedBitrate {
                Text(language.text("Estimated bitrate: %@ Mbps", String(format: "%.3f", Double(bitrate) / 1_000_000)))
                    .font(.title2).monospacedDigit()
            }
            Text(report.settings.evaluationModel.label).font(.callout)
            Text(language.text("Target mean VMAF: %@", String(format: "%.2f", report.configuration.target)))
            if let note = report.note { Text(language.text(note)).foregroundStyle(.red) }
            Text(language.text("Results apply only to this sample. A confirmed estimate does not guarantee a global minimum or live-network suitability."))
                .font(.caption).foregroundStyle(.secondary)
            BitrateSearchTrialsView(trials: report.trials, target: report.configuration.target, language: language)
        }
    }
}

private struct BitrateSearchTrialsView: View {
    let trials: [BitrateSearchTrial]
    let target: Double
    let language: AppLanguage
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
            GridRow {
                Text(language.text("Trial")); Text("Mbps"); Text(language.text("Mean VMAF")); Text(language.text("Minimum VMAF")); Text(language.text("Result"))
            }.font(.caption.bold())
            ForEach(trials) { trial in
                GridRow {
                    Text(trial.confirmation ? language.text("Confirmation") : String(trial.id))
                    Text(String(format: "%.3f", Double(trial.bitrate) / 1_000_000))
                    Text(String(format: "%.2f", trial.mean)); Text(String(format: "%.2f", trial.minimum))
                    Label(language.text(trial.mean >= target ? "Target met" : "Below target"),
                        systemImage: trial.mean >= target ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(trial.mean >= target ? Color.green : Color.orange)
                }.font(.callout).monospacedDigit()
            }
        }
    }
}
