import Foundation
import Testing
import ZIPFoundation
@testable import VQMetrixCore

struct UploadTests {
    static func headers(token:String = "secret", length:String = "100", extra:String = "") -> Data {
        Data("POST /api/v1/runs HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(length)\r\nContent-Type: application/zip\r\nX-VQMetrix-Protocol: 1\r\nIdempotency-Key: 12345678-1234-1234-1234-123456789abc\r\n\(extra)".utf8)
    }
    @Test func authenticatesAndBoundsUploadsBeforeReadingBody() throws {
        #expect(try UploadRequest.parse(Self.headers(), token:"secret").length == 100)
        #expect(throws: (any Error).self) { try UploadRequest.parse(Self.headers(token:"wrong"),token:"secret") }
        #expect(throws: (any Error).self) { try UploadRequest.parse(Self.headers(length:"536870913"),token:"secret") }
        #expect(throws: (any Error).self) { try UploadRequest.parse(Self.headers(extra:"Transfer-Encoding: chunked\r\n"),token:"secret") }
        #expect(throws: (any Error).self) { try UploadRequest.parse(Self.headers(extra:"Content-Length: 12\r\n"),token:"secret") }
        #expect(throws: (any Error).self) { try UploadRequest.parse(Self.headers(length:"-1"),token:"secret") }
    }
@Test func fourDigitCodesAreRateLimitedAcrossConnections() throws {
    var limiter = UploadAuthLimiter()
    let start = Date(timeIntervalSince1970: 1000)
    #expect(try limiter.parse(Self.headers(token:"0042"),token:"0042",now:start).length == 100)
    for _ in 0..<5 {
        #expect(throws: (any Error).self) { try limiter.parse(Self.headers(token:"0000"),token:"0042",now:start) }
    }
    do {
        _ = try limiter.parse(Self.headers(token:"0042"),token:"0042",now:start.addingTimeInterval(59))
        Issue.record("Expected a global cooldown")
    } catch { #expect((error as? UploadHTTPError)?.code == 429) }
    #expect(try limiter.parse(Self.headers(token:"0042"),token:"0042",now:start.addingTimeInterval(61)).length == 100)
}
@Test func rejectsInvalidSenderPerformance() throws {
    let metadata: [String:Any] = ["schemaVersion":1,"platform":"android","mode":"offlineReplay","wallTimeMs":0,"frameCount":15,"throughputFps":150,"videoDurationMs":1000,"realtimeSpeed":10]
    let value = try JSONDecoder().decode(EncodingPerformance.self,from:JSONSerialization.data(withJSONObject:metadata))
    #expect(throws: (any Error).self) { try value.validate(frames:15,fps:15) }
}
    @Test func rejectsZipTraversalAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for name in ["../escape", "/absolute", "nested/file", "reference.y4m/"] { #expect(!UploadPackage.validName(name)) }
        let url = root.appendingPathComponent("invalid.zip")
        let archive = try Archive(url:url,accessMode:.create)
        for name in ["manifest.json","reference.y4m","frame-map.json","../escape"] {
            try archive.addEntry(with:name,type:.file,uncompressedSize:Int64(1),provider:{ _,_ in Data([1]) })
        }
        #expect(throws: (any Error).self) { try UploadPackage.extract(url,to:root.appendingPathComponent("payload"),runID:UUID()) }
#expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("escape").path))
let symlinkURL = root.appendingPathComponent("symlink.zip")
do {
    let links = try Archive(url:symlinkURL,accessMode:.create)
    for name in ["manifest.json","reference.y4m","frame-map.json","h264-300000.mp4"] {
        try links.addEntry(with:name,type:name == "reference.y4m" ? .symlink : .file,uncompressedSize:Int64(1),provider:{ _,_ in Data([120]) })
    }
}
#expect(throws: (any Error).self) { try UploadPackage.extract(symlinkURL,to:root.appendingPathComponent("links"),runID:UUID()) }
    }
}
