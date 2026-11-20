import Foundation
import Testing
@testable import VQMetrix

struct ScoreBandsTests {
    private func point(_ time: Double, _ score: Double, segment: Int = 0) -> QualityPoint {
        QualityPoint(segment: segment, index: Int(time * 100), pts: time, score: score,
            settings: BenchmarkSettings(codec: .h264, bitrate: 1_000_000), latencyMilliseconds: 0)
    }
    @Test func bandBoundariesAndArbitraryTargets() {
        #expect(ScoreBand(score: 95) == .from95)
        #expect(ScoreBand(score: 94.99) == .from90)
        #expect(ScoreBand(score: 90) == .from90)
        #expect(ScoreBand(score: 80) == .from80)
        #expect(ScoreBand(score: 70) == .from70)
        #expect(ScoreBand(score: 69.99) == .below70)
        #expect(ScoreBandChart.target(92.5) == 92.5)
        #expect(ScoreBandChart.target(.nan) == 90)
        #expect(ScoreBandChart.target(101) == 100)
    }
    @Test func linesIntersectEveryBandWithoutJoiningSettings() {
        let points = [point(0, 60), point(4, 100), point(5, 85, segment: 1)]
        let traces = ScoreBandChart.traces(points)
        #expect(traces.count == 6)
        #expect(traces[0].vertices.last?.pts == 1)
        #expect(traces[1].vertices.first?.score == 70)
        #expect(traces[3].vertices.last?.score == 95)
        #expect(traces[4].vertices.last?.score == 100)
        #expect(traces[5].segment == 1 && traces[5].vertices.count == 1)
        #expect(points.count == 3 && points[0].score == 60)
        let descending = ScoreBandChart.traces([point(0, 100), point(4, 60)])
        #expect(descending.count == 5)
        #expect(descending.last?.band == .below70)
    }
}
