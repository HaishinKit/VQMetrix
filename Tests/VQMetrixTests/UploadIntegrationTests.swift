@preconcurrency import AVFoundation
import Foundation
import Testing
import ZIPFoundation
@testable import VQMetrixCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true"))
struct UploadIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VQMETRIX_BONJOUR_PROBE"] == "1"))
    func bonjourDeviceProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = UploadQueue(root:root)
        let server = try UploadServer(port:18787,token:"0042",store:store)
        server.start(advertisement: { active in print("Bonjour registered: \(active)") }) { state in print("Probe: \(state)") }
        defer { server.stop(); try? FileManager.default.removeItem(at:root) }
        try await Task.sleep(for:.seconds(60))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VQMETRIX_UPLOAD_FIXTURE"] != nil))
    func actualAndroidProducerArchive() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VQMETRIX_UPLOAD_FIXTURE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let archive = try Archive(url:source,accessMode:.read)
        let entry = try #require(archive["manifest.json"])
        var metadata = Data()
        _ = try archive.extract(entry) { chunk in
            guard metadata.count + chunk.count < 1_048_576 else { throw QualityError("Fixture metadata too large") }
            metadata.append(chunk)
        }
        let incoming = try JSONDecoder().decode(CaptureManifest.self,from:metadata)
        let payload = root.appendingPathComponent("payload")
        let manifest = try UploadPackage.extract(source,to:payload,runID:try #require(UUID(uuidString:incoming.runId)))
        let output = root.appendingPathComponent("results")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try await UploadEvaluation.evaluate(manifest:manifest,payload:payload,output:output)
        let saved = try JSONDecoder().decode(SavedRun.self,from:Data(contentsOf:output.appendingPathComponent("live-summary.json")))
        #expect(saved.completeEvaluation)
        #expect(saved.segments.count == manifest.variants.count)
        #expect(saved.evaluatedFrames == manifest.reference.frameCount * manifest.variants.count)
    }
    @Test func httpUploadEvaluatesAndSavesHistoryWithIdempotency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let mp4 = root.appendingPathComponent("h264-300000.mp4")
        let writer = try AVAssetWriter(outputURL:mp4,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:nil)
        writer.add(input)
        #expect(writer.startWriting()); writer.startSession(atSourceTime:.zero)
        for frame in 0..<15 {
            let deadline = ContinuousClock.now.advanced(by:.seconds(5))
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { throw QualityError("Fixture encoder timeout") }
                try await Task.sleep(for:.milliseconds(10))
            }
            var pixel:CVPixelBuffer?
            try check(CVPixelBufferCreate(nil,64,64,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel),"Fixture pixels")
            let image = try #require(pixel)
            CVPixelBufferLockBaseAddress(image,[])
            memset(CVPixelBufferGetBaseAddressOfPlane(image,0),16,CVPixelBufferGetBytesPerRowOfPlane(image,0)*64)
            memset(CVPixelBufferGetBaseAddressOfPlane(image,1),128,CVPixelBufferGetBytesPerRowOfPlane(image,1)*32)
            CVPixelBufferUnlockBaseAddress(image,[])
            #expect(adaptor.append(image,withPresentationTime:CMTime(value:Int64(frame*1_000_000/15),timescale:1_000_000)))
        }
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
        var raw = Data("YUV4MPEG2 W64 H64 F15:1 Ip A1:1 C420jpeg XCOLORRANGE=LIMITED\n".utf8)
        for _ in 0..<15 { raw.append(Data("FRAME\n".utf8)); raw.append(Data(repeating:16,count:4096)); raw.append(Data(repeating:128,count:2048)) }
        let reference = root.appendingPathComponent("reference.y4m"); try raw.write(to:reference)
        let pts = (0..<15).map { Int64($0)*1_000_000/15 }
        let map = root.appendingPathComponent("frame-map.json")
        try JSONSerialization.data(withJSONObject:["referencePtsUs":pts,"captureTimestampsNs":[],"variants":[mp4.lastPathComponent:pts]]).write(to:map)
        let id = UUID()
        let files = try [reference,map,mp4].map { CaptureManifest.Payload(path:$0.lastPathComponent,size:Int64(try Data(contentsOf:$0).count),sha256:try UploadPackage.digest($0)) }
        var frameTimes: [EncodingPerformance.FrameTiming] = []
        for frame: Int in 0..<15 {
            let pts: Int64 = Int64(frame) * Int64(1_000_000) / Int64(15)
            let queued: Double = Double(frame) * 5.0
            let returned: Double = queued + 4.0
            let timing = EncodingPerformance.FrameTiming(ptsUs:pts,inputElapsedMs:queued,outputElapsedMs:returned,latencyMs:4.0)
            frameTimes.append(timing)
        }
        let resourceSamples: [EncodingPerformance.ResourceSample] = [
            .init(elapsedMs:0,appCpuTimeMs:0,memoryBytes:1048576,thermalState:"nominal",nativeThermalStatus:0),
            .init(elapsedMs:100,appCpuTimeMs:20,memoryBytes:2097152,thermalState:"fair",nativeThermalStatus:1)
        ]
        let performance = EncodingPerformance(schemaVersion:1,platform:"android",mode:"offlineReplay",wallTimeMs:100,
            firstOutputMs:4,frameCount:15,throughputFps:150,videoDurationMs:1000,realtimeSpeed:10,
            meanLatencyMs:4,p95LatencyMs:4,appCpuTimeMs:20,appCpuCores:0.2,memoryKind:"pss",sampledPeakMemoryBytes:2097152,
            sampleIntervalMs:250,samples:resourceSamples,frameTimings:frameTimes)
        let manifest = CaptureManifest(schema:"vqmetrix.capture.v1",schemaVersion:1,runId:id.uuidString,
            reference:.init(file:"reference.y4m",source:"test-pattern-v1",width:64,height:64,fpsNumerator:15,fpsDenominator:1,frameCount:15,pixelFormat:"yuv420p",bitDepth:8,colorRange:"limited",colorMatrix:"bt709",frameMap:"frame-map.json"),
            variants:[.init(file:mp4.lastPathComponent,codec:"h264",targetBitrate:300000,frameCount:15,width:64,height:64,performance:performance)],files:files)
        let manifestURL = root.appendingPathComponent("manifest.json"); try JSONEncoder().encode(manifest).write(to:manifestURL)
        let zip = root.appendingPathComponent("batch.zip")
        do {
            let archive = try Archive(url:zip,accessMode:.create)
            for file in [reference,map,mp4,manifestURL] { try archive.addEntry(with:file.lastPathComponent,fileURL:file,compressionMethod:.deflate) }
        }
        let results = root.appendingPathComponent("Results")
        let store = UploadQueue(root:root.appendingPathComponent("Uploads"),results:results)
        let port = UInt16.random(in:20000...50000)
        let server = try UploadServer(port:port,token:"secret",store:store)
        server.start { _ in }; defer { server.stop() }
        try await Task.sleep(for:.milliseconds(300))
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/api/v1/runs")!)
        request.httpMethod = "POST"; request.setValue("Bearer secret",forHTTPHeaderField:"Authorization")
        request.setValue("application/zip",forHTTPHeaderField:"Content-Type"); request.setValue("1",forHTTPHeaderField:"X-VQMetrix-Protocol")
        request.setValue(id.uuidString,forHTTPHeaderField:"Idempotency-Key")
        let zipData = try Data(contentsOf:zip)
        let (body,response) = try await URLSession.shared.upload(for:request,from:zipData)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        let accepted = try #require(try JSONSerialization.jsonObject(with:body) as? [String:String])
        #expect(accepted["jobId"] == id.uuidString.lowercased())
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        var job:UploadJob?
        repeat {
            job = await store.list().first
            if ["Completed","Failed"].contains(job?.status ?? "") { break }
            try await Task.sleep(for:.milliseconds(50))
        } while ContinuousClock.now < deadline
        #expect(job?.status == "Completed", "\(job?.detail ?? "Evaluation timed out")")
        let history = HistoryStore(root:results)
        let entries = try await history.list().entries
        #expect(entries.count == 1)
        let detail = try await history.detail(try #require(entries.first).directory)
        #expect(detail.run.evaluatedFrames == 15)
        #expect(detail.run.completeEvaluation)
        #expect(detail.run.senderPerformance?.first?.metrics.p95LatencyMs == 4)
        let report = try await history.report(try #require(entries.first).directory,language:.english)
        #expect(report.contains("Sender performance"))
        #expect(report.contains("p95"))
        #expect((detail.run.segments.first?.meanVMAF ?? 0) > 95)
        let (_,retry) = try await URLSession.shared.upload(for:request,from:zipData)
        #expect((retry as? HTTPURLResponse)?.statusCode == 202)
        #expect(await store.list().count == 1)
        let (_,conflict) = try await URLSession.shared.upload(for:request,from:Data([1,2,3]))
        #expect((conflict as? HTTPURLResponse)?.statusCode == 409)
        let restored = UploadQueue(root:root.appendingPathComponent("Uploads"),results:results)
        #expect(await restored.list().first?.status == "Completed")
        request.setValue("Bearer wrong",forHTTPHeaderField:"Authorization")
        let (_,unauthorized) = try await URLSession.shared.upload(for:request,from:zipData)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
    }
}
