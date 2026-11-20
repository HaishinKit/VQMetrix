import Foundation
import CryptoKit
import ZIPFoundation

struct CaptureManifest: Codable, Sendable {
    struct Reference: Codable, Sendable {
        let file: String; let source: String; let width: Int; let height: Int
        let fpsNumerator: Int; let fpsDenominator: Int; let frameCount: Int
        let pixelFormat: String; let bitDepth: Int; let colorRange: String; let colorMatrix: String
        let frameMap: String
    }
    struct Variant: Codable, Sendable {
        let file: String; let codec: String; let targetBitrate: Int
        let frameCount: Int; let width: Int; let height: Int
    }
    struct Payload: Codable, Sendable { let path: String; let size: Int64; let sha256: String }
    let schema: String; let schemaVersion: Int; let runId: String
    let reference: Reference; let variants: [Variant]; let files: [Payload]
}

struct CaptureFrameMap: Codable {
    let referencePtsUs: [Int64]
    let captureTimestampsNs: [Int64]
    let variants: [String: [Int64]]
}

enum UploadPackage {
    static let maxUpload: Int64 = 512 * 1024 * 1024
    static let maxExtracted: Int64 = 1024 * 1024 * 1024

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validName(_ name: String) -> Bool {
        ["manifest.json", "reference.y4m", "frame-map.json"].contains(name) ||
            name.range(of: #"^(h264|hevc)-[0-9]{1,9}\.mp4$"#, options: .regularExpression) != nil
    }

    static func extract(_ zip: URL, to directory: URL, runID: UUID) throws -> CaptureManifest {
        let archive = try Archive(url: zip, accessMode: .read)
        let entries = Array(archive)
        guard (4...9).contains(entries.count) else { throw QualityError("Invalid package file count") }
        var names = Set<String>()
        var declared: Int64 = 0
        for entry in entries {
            guard entry.type == .file, validName(entry.path), names.insert(entry.path).inserted,
                  entry.uncompressedSize <= UInt64(maxExtracted) else { throw QualityError("Unsafe ZIP entry") }
            declared += Int64(entry.uncompressedSize)
            guard declared <= maxExtracted else { throw QualityError("Extracted package exceeds 1 GiB") }
            if entry.path.hasSuffix(".json"), entry.uncompressedSize > 1_048_576 { throw QualityError("Package metadata is too large") }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var total: Int64 = 0
        for entry in entries {
            let output = directory.appendingPathComponent(entry.path)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            var count: Int64 = 0
            let checksum = try archive.extract(entry, bufferSize: 65536) { data in
                total += Int64(data.count); count += Int64(data.count)
                guard total <= maxExtracted, count <= Int64(entry.uncompressedSize) else { throw QualityError("ZIP size limit exceeded") }
                try handle.write(contentsOf: data)
            }
            guard checksum == entry.checksum, count == Int64(entry.uncompressedSize) else { throw QualityError("ZIP checksum or size mismatch") }
        }
        let manifest = try JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let ref = manifest.reference
        guard manifest.schema == "vqmetrix.capture.v1", manifest.schemaVersion == 1,
              UUID(uuidString: manifest.runId) == runID,
              ref.file == "reference.y4m", ref.frameMap == "frame-map.json",
              ref.pixelFormat == "yuv420p", ref.bitDepth == 8,
              (64...1920).contains(ref.width), (64...1080).contains(ref.height), ref.width % 2 == 0, ref.height % 2 == 0,
              [15,30].contains(ref.fpsNumerator), ref.fpsDenominator == 1,
              (2...300).contains(ref.frameCount), ref.frameCount <= ref.fpsNumerator * 10,
              (1...6).contains(manifest.variants.count) else { throw QualityError("Unsupported capture manifest") }
        let variantNames = manifest.variants.map(\.file)
        guard Set(variantNames).count == variantNames.count else { throw QualityError("Duplicate variants") }
        for variant in manifest.variants {
            guard ["h264","hevc"].contains(variant.codec), (50_000...20_000_000).contains(variant.targetBitrate),
                  variant.file == "\(variant.codec)-\(variant.targetBitrate).mp4",
                  variant.width == ref.width, variant.height == ref.height, variant.frameCount == ref.frameCount else {
                throw QualityError("Variant settings differ from the reference")
            }
        }
        let expected = Set([ref.file,ref.frameMap] + variantNames)
        guard Set(manifest.files.map(\.path)) == expected, manifest.files.count == expected.count,
              names == expected.union(["manifest.json"]) else { throw QualityError("Declared package files do not match ZIP") }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard file.size >= 0, size == Int(file.size), try digest(url) == file.sha256 else { throw QualityError("Payload SHA-256 or size mismatch") }
        }
        let map = try JSONDecoder().decode(CaptureFrameMap.self, from: Data(contentsOf: directory.appendingPathComponent(ref.frameMap)))
        let timestamps = (0..<ref.frameCount).map { Int64($0) * 1_000_000 / Int64(ref.fpsNumerator) }
        guard map.referencePtsUs == timestamps, Set(map.variants.keys) == Set(variantNames),
              map.variants.values.allSatisfy({ $0 == timestamps }),
              map.captureTimestampsNs.isEmpty || (map.captureTimestampsNs.count == ref.frameCount && Swift.zip(map.captureTimestampsNs, map.captureTimestampsNs.dropFirst()).allSatisfy({ $0 < $1 })) else {
            throw QualityError("Invalid frame timestamps")
        }
        return manifest
    }
}
