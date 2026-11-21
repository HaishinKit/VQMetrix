import Foundation
import Testing
@testable import VQMetrix

struct BenchmarkSettingsTests {
    @Test func oldHistoriesKeepTheirOriginalSettings() throws {
        let old = Data(#"{"codec":"H.264","bitrate":1000000}"#.utf8)
        let settings = try JSONDecoder().decode(BenchmarkSettings.self, from: old)
        #expect(settings.evaluationModel == .legacy)
        #expect(settings.profile == .main)
        #expect(settings.resolution == .source)
        #expect(settings.isValid)
        let newer = BenchmarkSettings(codec: .hevc, bitrate: 800_000, profile: .main10, resolution: .p720)
        #expect(try JSONDecoder().decode(BenchmarkSettings.self, from: JSONEncoder().encode(newer)) == newer)
        #expect(!BenchmarkSettings(codec: .hevc, bitrate: 1_000_000, profile: .high).isValid)
    }

    @Test func resolutionPreservesAspectRatioAndEvenDimensions() {
        let wide = BenchmarkResolution.p720.dimensions(width: 1920, height: 1080)
        #expect(wide.width == 1280 && wide.height == 720)
        let classic = BenchmarkResolution.p720.dimensions(width: 640, height: 480)
        #expect(classic.width == 960 && classic.height == 720)
        let source = BenchmarkResolution.source.dimensions(width: 640, height: 480)
        #expect(source.width == 640 && source.height == 480)
        let rounded = BenchmarkResolution.p480.dimensions(width: 1920, height: 1080)
        #expect(rounded.width % 2 == 0 && rounded.height % 2 == 0)
        #expect(rounded.width <= 854 && rounded.height <= 480)
    }
}
