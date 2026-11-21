import Foundation
import VideoToolbox

package enum BenchmarkCodec: String, CaseIterable, Codable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"

    package var profiles: [BenchmarkProfile] {
        self == .h264 ? [.baseline, .main, .high] : [.main, .main10]
    }
}

package enum BenchmarkProfile: String, CaseIterable, Codable, Sendable {
    case baseline = "Baseline", main = "Main", high = "High", main10 = "Main 10"

    func level(for codec: BenchmarkCodec) -> String {
        switch (codec, self) {
        case (.h264, .baseline): kVTProfileLevel_H264_Baseline_AutoLevel as String
        case (.h264, .high): kVTProfileLevel_H264_High_AutoLevel as String
        case (.hevc, .main10): kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case (.hevc, _): kVTProfileLevel_HEVC_Main_AutoLevel as String
        default: kVTProfileLevel_H264_Main_AutoLevel as String
        }
    }
}

package enum BenchmarkResolution: String, CaseIterable, Codable, Sendable {
    case source = "Source", p1080 = "1080p", p720 = "720p", p540 = "540p"
    case p480 = "480p", p360 = "360p", p180 = "180p"

    package func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard self != .source, width > 0, height > 0 else { return (width, height) }
        let bounds: (Double, Double)
        switch self {
        case .p1080: bounds = (1920, 1080)
        case .p720: bounds = (1280, 720)
        case .p540: bounds = (960, 540)
        case .p480: bounds = (854, 480)
        case .p360: bounds = (640, 360)
        case .p180: bounds = (320, 180)
        case .source: return (width, height)
        }
        let scale = min(bounds.0 / Double(width), bounds.1 / Double(height))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

package struct BenchmarkSettings: Equatable, Codable, Sendable {
    package var codec: BenchmarkCodec
    package var bitrate: Int
    package var profile: BenchmarkProfile
    package var resolution: BenchmarkResolution
    package var evaluationModel: VMAFModel

    package init(codec: BenchmarkCodec, bitrate: Int, profile: BenchmarkProfile = .main, resolution: BenchmarkResolution = .source, evaluationModel: VMAFModel = .v1) {
        self.codec = codec; self.bitrate = bitrate; self.profile = profile; self.resolution = resolution; self.evaluationModel = evaluationModel
    }
    private enum CodingKeys: String, CodingKey { case codec, bitrate, profile, resolution, evaluationModel }
    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codec = try values.decode(BenchmarkCodec.self, forKey: .codec)
        bitrate = try values.decode(Int.self, forKey: .bitrate)
        // Existing histories used Main profile and the source dimensions.
        profile = try values.decodeIfPresent(BenchmarkProfile.self, forKey: .profile) ?? .main
        resolution = try values.decodeIfPresent(BenchmarkResolution.self, forKey: .resolution) ?? .source
        evaluationModel = try values.decodeIfPresent(VMAFModel.self, forKey: .evaluationModel) ?? .legacy
    }
    package var bitrateLabel: String { String(format: "%@ · %.2f Mbps", codec.rawValue, Double(bitrate) / 1_000_000) }
    package var label: String {
        String(format: "%@ %@ · %.2f Mbps · %@", codec.rawValue, profile.rawValue, Double(bitrate) / 1_000_000, resolution.rawValue)
    }
    package var isValid: Bool { bitrate > 0 && bitrate <= 100_000_000 && codec.profiles.contains(profile) }
}
