import AppKit
import SwiftUI
import VQMetrixCore

@MainActor
final class ReceiverModel: ObservableObject {
    @Published var status = "Stopped"
    @Published var isRunning = false
    @Published var token = ""
    @Published var address = ""
    @Published var bonjourActive = false
    @Published var jobs: [UploadJob] = []
    @Published var receivedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    private var generation = UUID()
    @Published var error: String?
    let store = UploadQueue()
    private var server: UploadServer?
    func start(port: UInt16) {
        guard !isRunning else { return }
        do {
            error = nil
            token = String(format: "%04d", Int.random(in: 0...9999))
            let server = try UploadServer(port: port, token: token, store: store)
            self.server = server; address = "http://\(server.hostname):\(port)"
            isRunning = true; status = "Starting"
generation = UUID()
let generation = generation
server.start(progress: { [weak self] received,total in
    Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.receivedBytes = received; self.totalBytes = total
    }
}) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if state == "Listening" || state == "Stopped" { self.status = state }
                    else { self.error = state; self.stop() }
                }
            }
        } catch { self.error = String(describing: error) }
    }
    func stop() {
        bonjourActive = false; generation = UUID(); receivedBytes = 0; totalBytes = 0; server?.stop(); server = nil; isRunning = false; token = ""; status = "Stopped"
    }
    func refresh() async { jobs = await store.list() }
    func openUploads() {
        Task {
            let root = await store.root
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

}

struct ReceiverView: View {
    let language: AppLanguage
    @ObservedObject var receiver: ReceiverModel
    @State private var port = "8787"
    @State private var copied = false
    private var validPort: UInt16? { UInt16(port).flatMap { $0 > 0 ? $0 : nil } }
    private var completed: Int { receiver.jobs.filter { $0.status == "Completed" }.count }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:24) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading, spacing:6) {
                        Text(language.text("Receive from devices")).font(.largeTitle.bold())
                        Text(language.text("Discover this Mac, upload samples, and evaluate automatically.")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(language.text(receiver.status), systemImage:receiver.isRunning ? "network" : "pause.circle")
                        .font(.callout.weight(.medium)).padding(10).background(.quaternary, in:Capsule())
                }
                HStack(spacing:16) {
                    ReceiverMetric(title:language.text("Received packages"), value:String(receiver.jobs.count), icon:"shippingbox")
                    ReceiverMetric(title:language.text("Waiting or evaluating"), value:String(receiver.jobs.filter { ["Queued","Evaluating"].contains($0.status) }.count), icon:"waveform.path.ecg")
                    ReceiverMetric(title:language.text("Completed"), value:String(completed), icon:"checkmark.circle")
                }
                GroupBox {
                    VStack(alignment:.leading, spacing:16) {
                        Label(language.text("Local network receiver"), systemImage:"antenna.radiowaves.left.and.right").font(.headline)
                        Text(language.text("Bonjour lets your devices find this Mac on the same network.")).foregroundStyle(.secondary)
                        HStack {
                            Text(language.text("Port"))
                            TextField("8787", text:$port).frame(width:90).disabled(receiver.isRunning)
                                .accessibilityLabel(language.text("Port"))
                            Spacer()
                            if receiver.isRunning {
                                Button(language.text("Stop receiving")) { receiver.stop() }
                            } else {
                                Button(language.text("Start receiving")) { if let port = validPort { receiver.start(port:port) } }
                                    .buttonStyle(.borderedProminent).disabled(validPort == nil)
                            }
                        }
                        if validPort == nil { Text(language.text("Enter a port from 1 to 65535.")).foregroundStyle(.red) }
                        if !receiver.address.isEmpty {
                            LabeledContent(language.text("Receiver address")) {
                                Text(receiver.address).font(.system(.body, design:.monospaced)).textSelection(.enabled)
                                Button(language.text("Copy address")) { copy(receiver.address) }
                            }
                        }
                        if receiver.isRunning {
                            Label(language.text(receiver.bonjourActive ? "Bonjour discovery is available" : "Waiting for Bonjour advertisement"),systemImage:receiver.bonjourActive ? "checkmark.circle" : "clock").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            VStack(alignment:.leading, spacing:5) {
                                Text(language.text("Connection code")).font(.subheadline.weight(.semibold))
                                Text(receiver.isRunning ? receiver.token : "— — — —")
                                    .font(.system(size:32,weight:.semibold,design:.monospaced)).tracking(8).textSelection(.enabled).lineLimit(1)
                            }
                            Spacer()
                            Button(language.text("Copy code")) { copy(receiver.token); copied = true }.disabled(receiver.token.isEmpty)
                        }
                        Text(language.text("A new 4-digit code is issued each time reception starts. Five incorrect attempts pause access for one minute.")).font(.caption).foregroundStyle(.secondary)
                        if copied { Text(language.text("Code copied. Enter it on your device.")).font(.caption).foregroundStyle(.secondary) }
                        Label(language.text("LAN HTTP sends video and connection codes without encryption. Use a trusted network."), systemImage:"lock.open")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true)
                    }.padding(12)
                }
if receiver.totalBytes > 0 {
    VStack(alignment:.leading,spacing:8) {
        Label(language.text(receiver.receivedBytes == receiver.totalBytes ? "Validating package" : "Receiving package"),systemImage:"arrow.down.circle").font(.headline)
        ProgressView(value:Double(receiver.receivedBytes),total:Double(receiver.totalBytes))
        Text("\(ByteCountFormatter.string(fromByteCount:receiver.receivedBytes,countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:receiver.totalBytes,countStyle:.file))")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }.padding(16)
}
if let error = receiver.error {
                    Label(error, systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                VStack(alignment:.leading, spacing:12) {
                    HStack {
                        Text(language.text("Upload activity")).font(.title2.bold())
                        Spacer()
                        Button(language.text("Open received files")) { receiver.openUploads() }
                    }
                    if receiver.jobs.isEmpty {
                        VStack(spacing:12) {
                            Image(systemName:"tray.and.arrow.down").font(.system(size:32)).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(language.text("No packages received yet")).font(.headline)
                            Text(language.text("Start receiving, then select this Mac on your device.")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth:.infinity).padding(36).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                    } else {
                        ForEach(receiver.jobs) { job in
                            HStack(alignment:.top, spacing:14) {
                                Image(systemName:job.status == "Completed" ? "checkmark.circle" : job.status == "Failed" ? "exclamationmark.triangle" : "clock")
                                    .font(.title2).foregroundStyle(job.status == "Failed" ? Color.red : Color.accentColor).accessibilityHidden(true)
                                VStack(alignment:.leading, spacing:5) {
                                    Text(String(job.id.uuidString.prefix(8))).font(.system(.headline,design:.monospaced))
                                    Text(job.date.formatted(date:.abbreviated,time:.standard)).font(.caption).foregroundStyle(.secondary)
                                    if let detail = job.detail { Text(detail).font(.callout).textSelection(.enabled) }
                                }
                                Spacer()
                                if job.status == "Evaluating" { ProgressView().controlSize(.small) }
                                Text(language.text(job.status)).font(.callout.weight(.medium))
                            }.padding(16).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                    Text(language.text("Completed evaluations appear in History. Stopping reception keeps the evaluation queue running."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth:1100)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await receiver.refresh()
                try? await Task.sleep(for:.seconds(1))
            }
        }
    }
    private func copy(_ text:String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
}

private struct ReceiverMetric: View {
    let title:String; let value:String; let icon:String
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size:32,weight:.semibold,design:.rounded)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
    }
}
