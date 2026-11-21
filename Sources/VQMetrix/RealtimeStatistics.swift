import Foundation

package struct RealtimeStatistics: Codable, Sendable, Equatable {
    package let mode: String
    package let expectedFPS: Double
    package let inputFPS: Double
    package let outputFPS: Double
    package let averageOutputFPS: Double
    package let decodedFrames: Int
    package let timedFrames: Int
    package let meanLatencyMilliseconds: Double
    package let maximumLatencyMilliseconds: Double
    package let framesOverInterval: Int
    package let pendingFrames: Int
    package let maximumPendingFrames: Int
    package let mixerDroppedFrames: Int
}

/// Monotonic arrival-to-decoded timing, confined to the segment's main actor.
final class RealtimeTracker {
    let fps: Double
    let offline: Bool
    private var started: Double?
    private var inputs = 0
    private var outputs = 0
    private var timed = 0
    private var totalLatency = 0.0
    private var maximumLatency = 0.0
    private var overInterval = 0
    private var maximumPending = 0
    private var recentOutputs: [Double] = []
    init(fps: Double, offline: Bool) { self.fps = fps; self.offline = offline }
    func input(arrived: Double) {
        if started == nil { started = arrived }
        inputs += 1
        maximumPending = max(maximumPending, inputs - outputs)
    }
    func output(at now: Double, arrived: Double?) {
        outputs += 1
        recentOutputs.append(now)
        if let arrived {
            let latency = max(0, now - arrived)
            timed += 1; totalLatency += latency; maximumLatency = max(maximumLatency, latency)
            if latency > 1 / fps { overInterval += 1 }
        }
    }
    func snapshot(at now: Double, queued: Int, dropped: Int, recentInputs: Int = 0) -> RealtimeStatistics {
        recentOutputs.removeAll { $0 < now - 1 }
        let duration = max(0.000001, now - (started ?? now) + (offline ? 0 : 1 / fps))
        let pending = max(0, inputs - outputs) + queued
        maximumPending = max(maximumPending, pending)
        return .init(mode: offline ? "offlineReplay" : "live", expectedFPS: fps,
            inputFPS: Double(recentInputs) / min(1, duration), outputFPS: Double(recentOutputs.count) / min(1, duration), averageOutputFPS: Double(outputs) / duration,
            decodedFrames: outputs, timedFrames: timed, meanLatencyMilliseconds: timed == 0 ? 0 : totalLatency * 1000 / Double(timed),
            maximumLatencyMilliseconds: maximumLatency * 1000, framesOverInterval: overInterval,
            pendingFrames: pending, maximumPendingFrames: maximumPending, mixerDroppedFrames: dropped)
    }
}
