import Foundation
import Testing
@testable import VQMetrix

@MainActor
struct BitrateSearchTests {
    private func trial(_ rate: Int, mean: Double, confirmation: Bool = false, frames: Int = 10) -> BitrateSearchTrial {
        BitrateSearchTrial(id: 1, bitrate: rate, mean: mean, minimum: mean - 2, actualBitrate: Double(rate),
            frames: frames, wallSeconds: 1, confirmation: confirmation, directory: "trials/1")
    }
    @Test func findsAndConfirmsAnArbitraryTarget() async throws {
        var config = BitrateSearchConfiguration(); config.target = 92.5; config.maximumTrials = 16
        var calls: [(Int, Bool)] = []
        let result = try await BitrateSearchAlgorithm.run(config) { rate, confirming in
            calls.append((rate, confirming))
            return trial(rate, mean: 85 + Double(rate) / 400_000, confirmation: confirming)
        }
        #expect(result.0 == .verified)
        let rate = try #require(result.1)
        #expect(rate >= 3_000_000 && rate <= 3_050_000)
        #expect(calls.last?.1 == true && calls.last?.0 == rate)
        #expect(calls.count <= config.maximumTrials)
    }
    @Test func doesNotRecommendUnreachableOrUnconfirmedCandidates() async throws {
        let config = BitrateSearchConfiguration()
        var calls = 0
        let unreachable = try await BitrateSearchAlgorithm.run(config) { rate, _ in
            calls += 1; return trial(rate, mean: 80)
        }
        #expect(unreachable.0 == .unreachable && unreachable.1 == nil && calls == 2)
        let unstable = try await BitrateSearchAlgorithm.run(config) { rate, confirming in
            trial(rate, mean: confirming ? 89.99 : 95, confirmation: confirming)
        }
        #expect(unstable.0 == .unstable && unstable.1 == nil)
    }
    @Test func preservesBoundsAndRejectsDifferentFrameSets() async throws {
        var config = BitrateSearchConfiguration(); config.maximumTrials = 3
        var calls = 0
        let result = try await BitrateSearchAlgorithm.run(config) { rate, confirming in
            calls += 1; return trial(rate, mean: rate == config.minimumBitrate ? 60 : 95, confirmation: confirming)
        }
        #expect(result.0 == .trialLimitReached && result.1 == config.maximumBitrate && calls == 3)
        calls = 0
        await #expect(throws: QualityError.self) {
            _ = try await BitrateSearchAlgorithm.run(config) { rate, _ in
                calls += 1; return trial(rate, mean: 60, frames: calls == 1 ? 10 : 9)
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await BitrateSearchAlgorithm.run(config) { _, _ in throw CancellationError() }
        }
    }
}
