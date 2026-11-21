import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @AppStorage("vmafTargetScore") private var targetScore = 90.0
    let language: AppLanguage
    @State private var entries: [HistoryEntry] = []
    @State private var selection: URL?
    @State private var detail: HistoryDetail?
    @State private var loadedDirectory: URL?
    @State private var savedAnnotation = RunAnnotation()
    @State private var title = ""
    @State private var notes = ""
    @State private var search = ""
    @State private var statusKey = ""
    @State private var statusArguments: [String] = []
    private var status: String { language.format(statusKey, arguments: statusArguments) }
    private func showStatus(_ key: String, _ arguments: String...) {
        statusKey = key; statusArguments = arguments
    }
    @State private var unreadable = 0
    @State private var isLoading = false

    private var filtered: [HistoryEntry] {
        entries.filter { search.isEmpty || "\($0.title) \($0.source) \($0.settings) \($0.model) \($0.annotation.notes)".localizedCaseInsensitiveContains(search) }
    }
    private var draft: RunAnnotation { RunAnnotation(title: title, notes: notes) }

    private func refresh() async {
        do {
            let result = try await HistoryStore.shared.list()
            entries = result.entries
            unreadable = result.unreadable
            if selection == nil { selection = entries.first?.id }
        } catch { showStatus("Operation failed: %@", String(describing: error)) }
    }

    private func saveDraft() async throws {
        guard let loadedDirectory, draft.title != savedAnnotation.title || draft.notes != savedAnnotation.notes else { return }
        let value = draft
        try await HistoryStore.shared.saveAnnotation(value, for: loadedDirectory)
        savedAnnotation = value
    }

    private func load(_ directory: URL?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await saveDraft()
            guard let directory else { detail = nil; loadedDirectory = nil; return }
            let value = try await HistoryStore.shared.detail(directory)
            guard !Task.isCancelled, selection == directory else { return }
            detail = value
            loadedDirectory = directory
            savedAnnotation = value.annotation
            title = value.annotation.title
            notes = value.annotation.notes
            showStatus("")
        } catch { showStatus("Operation failed: %@", String(describing: error)) }
    }

    private func export() {
        guard let selection else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.title = language.text("Export report…")
        panel.prompt = language.text("Save")
        panel.nameFieldStringValue = "VQMetrix-\(selection.lastPathComponent.prefix(8)).html"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        Task {
            do {
                try await saveDraft()
                let report = try await HistoryStore.shared.report(selection, language: language, targetScore: targetScore)
                try report.write(to: output, atomically: true, encoding: .utf8)
                showStatus("Report exported.")
                await refresh()
            } catch { showStatus("Operation failed: %@", String(describing: error)) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("History")).font(.title.bold())
                    Text(language.text("View saved results, annotate trials, and export reports.")).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(language.text("Search history"), text: $search).frame(width: 220)
                Button(language.text("Refresh")) { Task { await refresh() } }
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.headline).lineLimit(1)
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(entry.settings).font(.caption).lineLimit(2)
                            Text(entry.model).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(entry.mean.map { String(format: "VMAF %.2f", $0) } ?? "VMAF —")
                                Spacer()
                                Image(systemName: entry.complete ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(entry.complete ? .green : .orange)
                            }.font(.caption)
                        }.padding(.vertical, 6).tag(entry.id)
                    }
                }.listStyle(.sidebar).frame(minWidth: 240, idealWidth: 290, maxWidth: 370)
                ScrollView {
                    if let detail {
                        details(detail.run)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                            Text(language.text(entries.isEmpty ? "No measurements yet" : "Select a measurement")).font(.title2)
                            Text(language.text("Saved runs will appear here.")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 400)
                    }
                }.frame(minWidth: 550)
            }
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if unreadable > 0 { Text(language.text("Unreadable runs: %@", String(unreadable))).font(.caption) }
            }
        }.padding(22).frame(minWidth: 960, minHeight: 780)
        .task { await refresh() }
        .task(id: selection) { await load(selection) }
        .onReceive(NotificationCenter.default.publisher(for: .benchmarkSaved)) { _ in Task { await refresh() } }
        .onDisappear { Task { try? await saveDraft() } }
    }

    private func details(_ run: SavedRun) -> some View {
        let values = run.scores.map(\.score)
        let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField(language.text("Report title"), text: $title).font(.title2.bold())
                Button(language.text("Export report…"), action: export).disabled(isLoading)
            }
            Text(run.sourceName ?? URL(fileURLWithPath: run.input).lastPathComponent).foregroundStyle(.secondary)
            if let format = run.format { Text(format).font(.caption).foregroundStyle(.secondary) }
            Label(language.text(run.completeEvaluation ? "Complete evaluation" : "Partial evaluation"),
                systemImage: run.completeEvaluation ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(run.completeEvaluation ? .green : .orange)
            if let failure = run.failure { Text(language.text(failure)).foregroundStyle(.red) }
            HStack(spacing: 25) {
                statistic("Mean VMAF", mean.map { String(format: "%.2f", $0) } ?? "—")
                statistic("Minimum VMAF", values.min().map { String(format: "%.2f", $0) } ?? "—")
                statistic("Evaluated frames", "\(run.evaluatedFrames) / \(run.inputFrames)")
            }
            if let search = run.bitrateSearch { BitrateSearchResultView(report: search, language: language) }
            else { ScoreTargetControl(language: language) }
            ScoreChart(points: run.scores, language: language, targetScore: run.bitrateSearch?.configuration.target ?? targetScore).equatable()
            Text(language.text("Encoding settings by segment")).font(.headline)
            ForEach(run.segments, id: \.index) { segment in
                let label = run.sourceKind == "upload" && segment.encodedProfile == nil ? segment.settings.bitrateLabel : segment.settings.label
                HStack {
                    Text("\(segment.index + 1). \(label)")
                    Spacer()
                    Text(segment.meanVMAF.map { String(format: "VMAF %.2f", $0) } ?? "VMAF —")
                    Text("\(segment.evaluatedFrames)/\(segment.inputFrames)").foregroundStyle(.secondary)
                }.font(.callout)
                if let width = segment.encodedWidth, let height = segment.encodedHeight,
                   let referenceWidth = segment.referenceWidth, let referenceHeight = segment.referenceHeight {
                    Text(language.text("Output %@ × %@ · VMAF at %@ × %@", String(width), String(height), String(segment.evaluationWidth ?? referenceWidth), String(segment.evaluationHeight ?? referenceHeight)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
if let performance = run.senderPerformance, !performance.isEmpty {
    SenderPerformanceView(items:performance,language:language)
} else if run.sourceKind == "upload" {
    Text(language.text("Sender did not include performance measurements.")).font(.caption).foregroundStyle(.secondary)
}
Divider()
Text(language.text("Notes")).font(.headline)
            TextEditor(text: $notes).font(.body).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Text("\(run.model) · libvmaf \(run.libvmafVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(language.text("Save notes")) {
                    Task {
                        do { try await saveDraft(); showStatus("Notes saved."); await refresh() }
                        catch { showStatus("Operation failed: %@", String(describing: error)) }
                    }
                }.disabled(isLoading)
            }
            Text(language.text("Scores describe evaluated frames only. Missing frames and temporal gaps affect interpretation."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    private func statistic(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(language.text(key)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit())
        }
    }
}
