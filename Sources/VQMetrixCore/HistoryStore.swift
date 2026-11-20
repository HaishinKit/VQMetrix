import Foundation

package struct RunAnnotation: Codable, Sendable {
    package var title = ""
    package var notes = ""
    package init(title: String = "", notes: String = "") { self.title = title; self.notes = notes }
}

struct RunMetadata: Codable, Sendable {
    let input: String
    let model: String
    let inputFrames: Int
    let evaluatedFrames: Int
    let completeEvaluation: Bool
    let stoppedByUser: Bool
    let segments: [SegmentReport]
    let sourceKind: String?
    let sourceName: String?
    let createdAt: Date?
    let failure: String?

    init(run: SavedRun) {
        input = run.input; model = run.model; inputFrames = run.inputFrames
        evaluatedFrames = run.evaluatedFrames; completeEvaluation = run.completeEvaluation
        stoppedByUser = run.stoppedByUser; segments = run.segments
        sourceKind = run.sourceKind; sourceName = run.sourceName; createdAt = run.createdAt; failure = run.failure
    }
}

package struct HistoryEntry: Identifiable, Sendable {
    package let directory: URL
    package let date: Date
    package let source: String
    package let sourceKind: String
    package let inputFrames: Int
    package let evaluatedFrames: Int
    package let complete: Bool
    package let settings: String
    package let mean: Double?
    package let failure: String?
    package let annotation: RunAnnotation
    package var id: URL { directory }
    package var title: String { annotation.title.isEmpty ? source : annotation.title }
}

package struct HistoryDetail: Sendable {
    package let run: SavedRun
    package let annotation: RunAnnotation
}

package actor HistoryStore {
    package static let shared = HistoryStore()
    private let root: URL
    package init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VQMetrix/Results", isDirectory: true)
    }

    package func list() throws -> (entries: [HistoryEntry], unreadable: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])
        var entries: [HistoryEntry] = []
        var unreadable = 0
        for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let index = directory.appendingPathComponent("history.json")
            let summary = directory.appendingPathComponent("live-summary.json")
            guard FileManager.default.fileExists(atPath: summary.path) else { continue }
            do {
                let metadata: RunMetadata
                if let cached = try? JSONDecoder().decode(RunMetadata.self, from: Data(contentsOf: index)) {
                    metadata = cached
                } else {
                    metadata = try JSONDecoder().decode(RunMetadata.self, from: Data(contentsOf: summary))
                }
                let annotation = (try? readAnnotation(directory)) ?? RunAnnotation()
                let weighted = metadata.segments.compactMap { segment -> (Double, Int)? in
                    guard let mean = segment.meanVMAF, mean.isFinite, segment.evaluatedFrames > 0 else { return nil }
                    return (mean, segment.evaluatedFrames)
                }
                let count = weighted.reduce(0) { $0 + $1.1 }
                let mean = count == 0 ? nil : weighted.reduce(0.0) { $0 + $1.0 * Double($1.1) } / Double(count)
                let date = metadata.createdAt ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let name = metadata.sourceName ?? URL(fileURLWithPath: metadata.input).lastPathComponent
                var labels: [String] = []
                for segment in metadata.segments where !labels.contains(segment.settings.label) { labels.append(segment.settings.label) }
                entries.append(HistoryEntry(directory: directory, date: date, source: name,
                    sourceKind: metadata.sourceKind ?? "file", inputFrames: metadata.inputFrames,
                    evaluatedFrames: metadata.evaluatedFrames, complete: metadata.completeEvaluation,
                    settings: labels.joined(separator: " → "), mean: mean, failure: metadata.failure, annotation: annotation))
            } catch { unreadable += 1 }
        }
        return (entries.sorted { $0.date > $1.date }, unreadable)
    }

    package func detail(_ directory: URL) throws -> HistoryDetail {
        try validate(directory)
        let run = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: directory.appendingPathComponent("live-summary.json")))
        return HistoryDetail(run: run, annotation: (try? readAnnotation(directory)) ?? RunAnnotation())
    }

    package func saveAnnotation(_ annotation: RunAnnotation, for directory: URL) throws {
        try validate(directory)
        let data = try JSONEncoder().encode(annotation)
        try data.write(to: directory.appendingPathComponent("annotation.json"), options: .atomic)
    }

    private func readAnnotation(_ directory: URL) throws -> RunAnnotation {
        try JSONDecoder().decode(RunAnnotation.self, from: Data(contentsOf: directory.appendingPathComponent("annotation.json")))
    }

    private func validate(_ directory: URL) throws {
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw QualityError("Invalid history directory")
        }
    }

    package func report(_ directory: URL, language: AppLanguage) throws -> String {
        let detail = try detail(directory)
        return ReportRenderer.html(run: detail.run, annotation: detail.annotation,
            date: detail.run.createdAt ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
            id: directory.lastPathComponent, language: language)
    }
}

package enum ReportRenderer {
    package static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func html(run: SavedRun, annotation: RunAnnotation, date: Date, id: String, language: AppLanguage) -> String {
        func t(_ key: String) -> String { escape(language.text(key)) }
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "—" }
            return value.formatted(.number.precision(.fractionLength(2)).locale(language.locale))
        }
        let title = annotation.title.isEmpty ? language.text("Video quality report") : annotation.title
        let scores = run.scores.filter { $0.score.isFinite && $0.pts.isFinite }
        let mean = scores.isEmpty ? nil : scores.reduce(0) { $0 + $1.score } / Double(scores.count)
        let minimum = scores.map(\.score).min()
        let first = scores.map(\.pts).min() ?? 0
        let last = max(first + 1, scores.map(\.pts).max() ?? 1)
        let colors = ["#0077cc", "#087f5b", "#9c36b5", "#e67700", "#c2255c"]
        let paths = run.segments.map { segment in
            let points = scores.filter { $0.segment == segment.index }.map { point in
                String(format: "%.2f,%.2f", 45 + (point.pts - first) / (last - first) * 810, 220 - min(100, max(0, point.score)) * 2)
            }.joined(separator: " ")
            return "<polyline fill=\"none\" stroke=\"\(colors[((segment.index % colors.count) + colors.count) % colors.count])\" stroke-width=\"2\" points=\"\(points)\"/>"
        }.joined()
        let grid = [0, 25, 50, 75, 100].map { value in
            "<line x1=\"45\" x2=\"855\" y1=\"\(220 - value * 2)\" y2=\"\(220 - value * 2)\" stroke=\"#e2e8f0\"/><text x=\"34\" y=\"\(224 - value * 2)\" text-anchor=\"end\">\(value)</text>"
        }.joined()
        let rows = run.segments.map { segment in
            "<tr><td>\(segment.index + 1)</td><td>\(escape(segment.settings.codec.rawValue))</td><td>\(number(Double(segment.settings.bitrate) / 1_000_000)) Mbps</td><td>\(number(segment.meanVMAF))</td><td>\(segment.evaluatedFrames) / \(segment.inputFrames)</td><td>\(max(0, segment.inputFrames - segment.evaluatedFrames))</td></tr>"
        }.joined()
        let notes = annotation.notes.isEmpty ? "" : "<h2>\(t("Notes"))</h2><div class=\"notes\">\(escape(annotation.notes))</div>"
        let failure = run.failure.map { "<p class=\"warning\">\(escape(language.text($0)))</p>" } ?? ""
        let dateText = date.formatted(.dateTime.year().month().day().hour().minute().second().locale(language.locale))
        return """
        <!doctype html><html lang="\(language.code)"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title)) — VQMetrix</title><style>
        body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#172033;background:#f6f8fb;margin:0}main{max-width:960px;margin:32px auto;padding:32px;background:white;border-radius:16px}h1{font-size:30px;margin:0}h2{font-size:19px;margin-top:30px}.brand{color:#087fcb;font-weight:700}.meta{color:#526078;overflow-wrap:anywhere}.metrics{display:flex;gap:32px;flex-wrap:wrap;margin:24px 0}.metric strong{display:block;font-size:28px}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:9px;border-bottom:1px solid #e2e8f0}th{background:#f1f5f9}.warning{background:#fff4db;padding:14px;border-radius:8px}.notes{white-space:pre-wrap;overflow-wrap:anywhere}svg{width:100%;height:auto}svg text{font:12px sans-serif;fill:#526078}@media print{body{background:white}main{margin:0;padding:12px}table,svg,.metrics{break-inside:avoid}}
        </style><main><div class="brand">VQMetrix</div><h1>\(escape(title))</h1>
        <p class="meta">\(t("Date")): \(escape(dateText))<br>\(t("Source")): \(escape(run.sourceName ?? run.input))<br>\(escape(run.format ?? ""))<br>\(t("Model")): \(escape(run.model)) · libvmaf \(escape(run.libvmafVersion))</p>
        <p class="\(run.completeEvaluation ? "meta" : "warning")">\(t(run.completeEvaluation ? "Complete evaluation" : "Partial evaluation"))\(run.stoppedByUser ? " · " + t("Stopped by user") : "")</p>\(failure)
        <div class="metrics"><div class="metric">\(t("Mean VMAF"))<strong>\(number(mean))</strong></div><div class="metric">\(t("Minimum VMAF"))<strong>\(number(minimum))</strong></div><div class="metric">\(t("Evaluated frames"))<strong>\(run.evaluatedFrames) / \(run.inputFrames)</strong></div><div class="metric">\(t("Skipped frames"))<strong>\(max(0, run.inputFrames - run.evaluatedFrames))</strong></div></div>
        <h2>\(t("VMAF timeline"))</h2><svg viewBox="0 0 900 260" role="img" aria-label="\(t("VMAF timeline"))">\(grid)\(paths)<text x="45" y="244">\(number(first))</text><text x="855" y="244" text-anchor="end">\(number(last))</text></svg><p class="meta">\(t("Time (seconds)"))</p>
        <h2>\(t("Encoding settings by segment"))</h2><table><thead><tr><th>\(t("Segment"))</th><th>\(t("Codec"))</th><th>\(t("Target bitrate"))</th><th>\(t("Mean VMAF"))</th><th>\(t("Evaluated frames"))</th><th>\(t("Skipped frames"))</th></tr></thead><tbody>\(rows)</tbody></table>
        \(notes)<p class="warning">\(t("Scores describe evaluated frames only. Missing frames and temporal gaps affect interpretation."))</p><p class="meta">\(t("Encoding and decoding run on this device. Network delivery is excluded. Skipped evaluation frames are recorded."))</p><p class="meta">\(t("Run ID")): \(escape(id))</p></main></html>
        """
    }
}
