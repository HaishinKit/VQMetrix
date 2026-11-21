import Foundation
import Testing
@testable import VQMetrix

struct RealtimeStatisticsTests {
    @Test func fpsDecaysDuringStallsAndLatencyCountsAreSeparateFromDrops() throws {
        let tracker = RealtimeTracker(fps: 30, offline: false)
        for index in 0..<30 {
            let time = Double(index) / 30
            tracker.input(arrived: time)
            tracker.output(at: time + 0.005, arrived: time)
        }
        let healthy = tracker.snapshot(at: 1, queued: 0, dropped: 0, recentInputs: 30)
        #expect(healthy.inputFPS == 30 && healthy.outputFPS == 30 && healthy.decodedFrames == 30)
        #expect(healthy.framesOverInterval == 0 && healthy.pendingFrames == 0)
        #expect(abs(healthy.meanLatencyMilliseconds - 5) < 0.001)
        tracker.input(arrived: 1.1)
        tracker.output(at: 1.3, arrived: 1.1)
        tracker.input(arrived: 1.31)
        let slow = tracker.snapshot(at: 1.4, queued: 3, dropped: 2)
        #expect(slow.framesOverInterval == 1 && slow.mixerDroppedFrames == 2)
        #expect(abs(slow.maximumLatencyMilliseconds - 200) < 0.001)
        #expect(slow.pendingFrames == 4 && slow.maximumPendingFrames == 4)
        let stalled = tracker.snapshot(at: 3, queued: 3, dropped: 2)
        #expect(stalled.outputFPS == 0)
        #expect(try JSONDecoder().decode(RealtimeStatistics.self, from: JSONEncoder().encode(stalled)) == stalled)
    }
    @Test func offlineThroughputIsLabeledAndLegacySegmentsStayReadable() {
        let tracker = RealtimeTracker(fps: 30, offline: true)
        tracker.input(arrived: 0); tracker.output(at: 0.01, arrived: 0)
        let result = tracker.snapshot(at: 0.01, queued: 0, dropped: 0)
        #expect(result.mode == "offlineReplay" && result.averageOutputFPS == 100)
    }
}
