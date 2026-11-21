import AppKit
@preconcurrency import AVFoundation
import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class PreviewSurface: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); videoLayer.frame = bounds }

    func display(_ sample: CMSampleBuffer) {
        guard let image = sample.imageBuffer, let format = sample.formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var immediate: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &immediate) == noErr,
              let immediate else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(immediate, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if videoLayer.status == .failed { videoLayer.flush() }
        if videoLayer.isReadyForMoreMediaData { videoLayer.enqueue(immediate) }
    }
}

private struct VideoPreview: NSViewRepresentable {
    let sample: CMSampleBuffer?
    final class Coordinator { var lastPTS: CMTime? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(frame: .zero) }
    func updateNSView(_ view: PreviewSurface, context: Context) {
        guard let sample else {
            if context.coordinator.lastPTS != nil { view.videoLayer.flushAndRemoveImage() }
            context.coordinator.lastPTS = nil
            return
        }
        guard context.coordinator.lastPTS != sample.presentationTimeStamp else { return }
        context.coordinator.lastPTS = sample.presentationTimeStamp
        view.display(sample)
    }
}

private struct PreviewPanel: View {
    let title: String
    let subtitle: String
    let sample: CMSampleBuffer?
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Color.black
                VideoPreview(sample: sample)
                if sample == nil {
                    Label(language.text("Waiting for video"), systemImage: "video").foregroundStyle(.gray)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum InputKind: String { case file, camera }

struct BenchmarkView: View {
    @AppStorage("vmafTargetScore") private var targetScore = 90.0
    @AppStorage("vmafEvaluationModel") private var evaluationModel = VMAFModel.v1
    let language: AppLanguage
    @State private var inputKind = InputKind.file
    @State private var cameras: [CameraInfo] = []
    @State private var cameraID = ""
    @StateObject private var engine = LiveBenchmark()
    @StateObject private var search = BitrateSearch()
    @State private var input: URL?
    @State private var duration = 30
    @State private var bitrateMbps = 2.0
    @State private var codec = BenchmarkCodec.h264
    @State private var profile = BenchmarkProfile.main
    @State private var resolution = BenchmarkResolution.source

    private var settings: BenchmarkSettings? {
        guard bitrateMbps.isFinite, bitrateMbps > 0, bitrateMbps <= 100 else { return nil }
        return BenchmarkSettings(codec: codec, bitrate: Int(bitrateMbps * 1_000_000), profile: profile, resolution: resolution, evaluationModel: evaluationModel)
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = language.text("Choose a video file")
        panel.prompt = language.text("Open")
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { input = panel.url }
    }

    private func refreshCameras() {
        cameras = LiveBenchmark.cameras()
        if !cameras.contains(where: { $0.id == cameraID }) { cameraID = cameras.first?.id ?? "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("Measurement")).font(.largeTitle.bold())
                    Text(language.text("Measure video quality as you watch.")).foregroundStyle(.secondary)
                }
                Spacer()
                Text(engine.formatLabel).font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker(language.text("Input"), selection: $inputKind) {
                            Text(language.text("Video file")).tag(InputKind.file)
                            Text(language.text("Camera")).tag(InputKind.camera)
                        }.pickerStyle(.segmented).frame(width: 220).disabled(engine.isRunning)
                        if inputKind == .file {
                            Text(input?.lastPathComponent ?? language.text("Choose a video file"))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(language.text("Choose video…"), action: chooseVideo).disabled(engine.isRunning)
                        } else {
                            if cameras.isEmpty {
                                Text(language.text("No cameras found")).foregroundStyle(.secondary)
                            } else {
                                Picker(language.text("Camera"), selection: $cameraID) {
                                    ForEach(cameras) { Text($0.name).tag($0.id) }
                                }.labelsHidden().frame(maxWidth: 360).disabled(engine.isRunning)
                            }
                            Spacer()
                            Button(language.text("Refresh"), action: refreshCameras).disabled(engine.isRunning)
                        }
                    }
                    Divider()
                    HStack(spacing: 18) {
                        Picker(language.text("Codec"), selection: $codec) {
                            ForEach(BenchmarkCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 180).disabled(engine.isApplying)
                        HStack(spacing: 6) {
                            Text(language.text("Bitrate"))
                            TextField("Mbps", value: $bitrateMbps, format: .number).frame(width: 65)
                                .accessibilityLabel(language.text("Bitrate Mbps"))
                            Text("Mbps").foregroundStyle(.secondary)
                        }.disabled(engine.isApplying)
                        if engine.isRunning {
                            Button(language.text(engine.isApplying ? "Applying…" : "Apply changes")) {
                                if let settings { engine.apply(settings) }
                            }.disabled(settings == nil || settings == engine.activeSettings || engine.isApplying)
                        }
                        Spacer()
                        Stepper(language.text("%@ seconds", String(duration)), value: $duration, in: 1...300)
                            .frame(width: 125).disabled(engine.isRunning)
                    }
                    HStack(spacing: 18) {
                        Picker(language.text("Profile"), selection: $profile) {
                            ForEach(codec.profiles, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 200)
                        Picker(language.text("Output resolution"), selection: $resolution) {
                            ForEach(BenchmarkResolution.allCases, id: \.self) {
                                Text(language.text($0.rawValue)).tag($0)
                            }
                        }.frame(width: 230)
                        Text(language.text(evaluationModel == .v1 ? "VMAF v1: short side 1080, 10-bit evaluation." : "Fits the source aspect ratio. VMAF is evaluated at source size."))
                            .font(.caption).foregroundStyle(.secondary)
                    } .disabled(engine.isApplying)
                    VMAFModelPicker(language: language).disabled(engine.isRunning)
                }.padding(8)
            }
            .disabled(search.isRunning)
            BitrateSearchControls(search: search, language: language,
                canStart: inputKind == .file ? input != nil : cameras.contains(where: { $0.id == cameraID }),
                measurementRunning: engine.isRunning, isCamera: inputKind == .camera,
                start: { configuration in
                    let fixed = BenchmarkSettings(codec: codec, bitrate: 1_000_000, profile: profile, resolution: resolution, evaluationModel: evaluationModel)
                    search.start(input: inputKind == .file ? input : nil,
                        camera: inputKind == .camera ? cameras.first(where: { $0.id == cameraID }) : nil,
                        settings: fixed, configuration: configuration, engine: engine)
                }, useEstimate: { bitrate in
                    if let fixed = search.report?.settings { codec = fixed.codec; profile = fixed.profile; resolution = fixed.resolution; evaluationModel = fixed.evaluationModel }
                    bitrateMbps = Double(bitrate) / 1_000_000
                })
            HStack(spacing: 18) {
                PreviewPanel(title: language.text("MediaMixer output"), subtitle: language.text("Uncompressed reference"), sample: engine.sourceSample, language: language)
                PreviewPanel(title: language.text("Encoded output"), subtitle: engine.activeSettings?.label ?? language.text("After encoding and decoding"), sample: engine.decodedSample, language: language)
            }
            HStack(spacing: 20) {
                Metric(title: language.text("Latest VMAF"), value: engine.latestScore.map { String(format: "%.2f", $0) } ?? "—")
                Metric(title: language.text("Current segment mean"), value: engine.meanScore.map { String(format: "%.2f", $0) } ?? "—")
                Metric(title: language.text("Evaluated / decoded frames"), value: "\(engine.scores.count) / \(engine.decodedFrames)")
                Metric(title: language.text("Elapsed time"), value: language.text("%@ s", String(format: "%.1f", engine.currentPTS)))
            }.padding(.vertical, 4)
            ScoreTargetControl(language: language).disabled(search.isRunning)
            ScoreChart(points: engine.scores, language: language, targetScore: targetScore).equatable()
            Divider()
            HStack(spacing: 12) {
                if engine.isRunning || search.isRunning { ProgressView().controlSize(.small) }
                Text(search.isRunning ? language.text(search.phase) : engine.status).font(.callout).lineLimit(2)
                Spacer()
                Button(language.text("Show results")) {
                    if let directory = search.resultDirectory ?? engine.resultDirectory { NSWorkspace.shared.open(directory) }
                }.disabled((search.resultDirectory ?? engine.resultDirectory) == nil || engine.isRunning || search.isRunning)
                if engine.isRunning || search.isRunning {
                    Button(language.text("Stop")) { if search.isRunning { search.cancel() } else { engine.stop() } }
                } else {
                    Button(language.text("Start measurement")) {
                        search.clear()
                        if let settings {
                            if inputKind == .file, let input { engine.start(input: input, settings: settings, duration: Double(duration)) }
                            else if let camera = cameras.first(where: { $0.id == cameraID }) {
                                engine.start(cameraID: camera.id, name: camera.name, settings: settings, duration: Double(duration))
                            }
                        }
                    }.buttonStyle(.borderedProminent).disabled(settings == nil || (inputKind == .file ? input == nil : cameraID.isEmpty))
                }
            }
            Text(language.text("Encoding and decoding run on this device. Network delivery is excluded. Skipped evaluation frames are recorded."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 850, minHeight: 780)
        .onDisappear { search.cancel(); engine.stop() }
        .onAppear { engine.language = language; refreshCameras() }
        .onChange(of: language) { engine.language = $0 }
        .onChange(of: codec) { if !$0.profiles.contains(profile) { profile = .main } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in search.cancel(); engine.stop() }
    }
}

@main
struct VQMetrixApp: App {
    @StateObject private var updates = AppUpdates()
    @AppStorage("appLanguage") private var language = AppLanguage.system
    var body: some Scene {
        WindowGroup("VQMetrix") { WorkspaceView() }
            .defaultSize(width: 1240, height: 880)
            .commands {
                CommandGroup(after: .appInfo) {
                    UpdateCommands(updates: updates, language: language)
                }
                CommandGroup(replacing: .help) {
                    Button(language.text("VMAF score guide")) { NSWorkspace.shared.open(DocumentationLinks.scores(language)) }
                }
            }
    }
}

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case measurement = "Measurement", receive = "Receive", history = "History"
    var id:String { rawValue }
    var icon:String {
        switch self { case .measurement:"waveform.path.ecg"; case .receive:"tray.and.arrow.down"; case .history:"clock.arrow.circlepath" }
    }
}

private struct WorkspaceView: View {
    @AppStorage("appLanguage") private var language = AppLanguage.system
    @State private var page: WorkspacePage? = .measurement
    @StateObject private var receiver = ReceiverModel()
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:16) {
                HStack(spacing:10) {
                    Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:38,height:38).accessibilityHidden(true)
                    VStack(alignment:.leading) {
                        Text("VQMetrix").font(.headline)
                        Text(language.text("Video quality workspace")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal,16).padding(.top,16)
                List(WorkspacePage.allCases,selection:$page) { item in
                    Label(language.text(item.rawValue),systemImage:item.icon).padding(.vertical,6).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment:.leading,spacing:12) {
                    Label(language.text(receiver.status),systemImage:receiver.isRunning ? "network" : "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Link(destination:DocumentationLinks.scores(language)) {
                        Label(language.text("VMAF score guide"),systemImage:"questionmark.circle")
                    }.font(.callout)
                    Picker(language.text("Language"),selection:$language) {
                        Text(language.text("System")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("日本語").tag(AppLanguage.japanese)
                    }.labelsHidden().accessibilityLabel(language.text("Language"))
                }.padding(16)
            }.navigationSplitViewColumnWidth(min:180,ideal:210,max:260)
        } detail: {
            ZStack {
                ScrollView { BenchmarkView(language:language) }.opacity(page == .measurement ? 1:0)
                    .allowsHitTesting(page == .measurement).accessibilityHidden(page != .measurement)
                ReceiverView(language:language,receiver:receiver).opacity(page == .receive ? 1:0)
                    .allowsHitTesting(page == .receive).accessibilityHidden(page != .receive)
                HistoryView(language:language).opacity(page == .history ? 1:0)
                    .allowsHitTesting(page == .history).accessibilityHidden(page != .history)
            }
        }
        .environment(\.locale,language.locale)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in receiver.stop() }
    }
}
