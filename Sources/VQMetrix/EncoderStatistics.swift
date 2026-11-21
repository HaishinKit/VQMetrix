import Foundation

/// Persisted independently of the codec module so older histories remain readable.
package struct EncoderStatistics: Codable, Sendable, Equatable {
    package var backend: String
    package var measurement: String
    package var submittedFrameCount: UInt64
    package var outputPacketCount: UInt64
    package var encodedByteCount: UInt64
    package var timedFrameCount: UInt64
    package var lastEncodingDuration: Double
    package var totalEncodingDuration: Double
    package var maximumEncodingDuration: Double
    package var averageEncodingDuration: Double { timedFrameCount == 0 ? 0 : totalEncodingDuration / Double(timedFrameCount) }
    package static func empty(backend: String, measurement: String) -> Self {
        .init(backend: backend, measurement: measurement, submittedFrameCount: 0, outputPacketCount: 0,
              encodedByteCount: 0, timedFrameCount: 0, lastEncodingDuration: 0, totalEncodingDuration: 0, maximumEncodingDuration: 0)
    }
    mutating func recordOutput(bytes: Int, duration: Double?) {
        outputPacketCount += 1; encodedByteCount += UInt64(bytes)
        if let duration {
            timedFrameCount += 1; lastEncodingDuration = duration
            totalEncodingDuration += duration; maximumEncodingDuration = max(maximumEncodingDuration, duration)
        }
    }
}
