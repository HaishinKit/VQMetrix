import Charts
import SwiftUI

struct SenderPerformanceView: View {
    let items: [SenderPerformance]
    let language: AppLanguage
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(language.text("Sender performance")).font(.headline)
            Text(language.text("Offline replay speed is not a guarantee of live performance. CPU and memory cover the whole app, including capture and instrumentation."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()),id:\.offset) { _, item in
                performance(item)
            }
        }
    }
    private func number(_ value:Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(2)).locale(language.locale)) } ?? "—" }
    private func metric(_ title:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(language.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func performance(_ item:SenderPerformance) -> some View {
        let m = item.metrics
        return GroupBox {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(item.settings.bitrateLabel).font(.subheadline.bold())
                    Spacer()
                    Text(language.text(m.mode == "offlineReplay" ? "Offline replay" : "Live encoding")).font(.caption).foregroundStyle(.secondary)
                }
if let name = item.codecName {
    HStack {
        Text(name).font(.caption.monospaced()).textSelection(.enabled)
        if let hardware = item.hardwareAccelerated {
            Label(language.text(hardware ? "Hardware encoder" : "Software encoder"),systemImage:"cpu").font(.caption)
        }
    }.foregroundStyle(.secondary)
}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:130),alignment:.leading)],alignment:.leading,spacing:12) {
                    metric("Encoding time",number(m.wallTimeMs) + " ms")
                    metric("Processing speed",number(m.throughputFps) + " fps")
                    metric("Input-to-output p95",number(m.p95LatencyMs) + " ms")
                    metric("Realtime speed",number(m.realtimeSpeed) + "×")
                    metric("App CPU (cores)",number(m.appCpuCores))
                    metric("Actual bitrate",number(item.actualBitrate.map { $0/1_000_000 }) + " Mbps")
                    metric("Sampled peak memory",number(m.sampledPeakMemoryBytes.map{Double($0)/1_048_576}) + " MiB · " + (m.memoryKind ?? "—"))
                }
                Text(language.text("Thermal state") + ": " + m.thermalSummary.components(separatedBy:" → ").map{language.text($0)}.joined(separator:" → "))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(language.text("Performance timeline")) {
                    VStack(alignment:.leading,spacing:12) {
                        if let timings = m.frameTimings, !timings.isEmpty {
                            Text(language.text("Input-to-output latency")).font(.caption)
                            Chart {
                                ForEach(Array(timings.enumerated()),id:\.offset) { _, timing in
                                    LineMark(x:.value(language.text("Time (seconds)"),Double(timing.ptsUs)/1_000_000),y:.value("ms",timing.latencyMs))
                                }
                            }.frame(height:120).chartXAxisLabel(language.text("Time (seconds)"))
                        }
                        if let samples = m.samples, !samples.isEmpty {
                            Text(language.text("App memory")).font(.caption)
                            Chart {
                                ForEach(Array(samples.enumerated()),id:\.offset) { _, sample in
                                    if let memory = sample.memoryBytes {
                                        LineMark(x:.value("s",sample.elapsedMs/1000),y:.value("MiB",Double(memory)/1_048_576))
                                    }
                                }
                            }.frame(height:110).chartXAxisLabel(language.text("Measurement time (seconds)"))
                            Text(language.text("App CPU (cores)")).font(.caption)
                            Chart {
                                ForEach(cpuPoints(samples),id:\.time) { point in
                                    LineMark(x:.value("s",point.time),y:.value(language.text("App CPU (cores)"),point.cores))
                                }
                            }.frame(height:110).chartXAxisLabel(language.text("Measurement time (seconds)"))
                        }
                        Text(language.text("Thermal states are OS-reported categories, not temperatures or cross-device equivalents."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top,10)
                }
            }.padding(8)
        }
    }
    private struct CPUPoint { let time:Double; let cores:Double }
    private func cpuPoints(_ samples:[EncodingPerformance.ResourceSample]) -> [CPUPoint] {
        zip(samples,samples.dropFirst()).compactMap { before,after in
            guard let a=before.appCpuTimeMs,let b=after.appCpuTimeMs, after.elapsedMs > before.elapsedMs else { return nil }
            return CPUPoint(time:after.elapsedMs/1000,cores:max(0,b-a)/(after.elapsedMs-before.elapsedMs))
        }
    }
}
