import Foundation

package enum ScoreBand: Int, CaseIterable, Sendable {
    case below70, from70, from80, from90, from95

    package init(score: Double) {
        switch score {
        case 95...: self = .from95
        case 90..<95: self = .from90
        case 80..<90: self = .from80
        case 70..<80: self = .from70
        default: self = .below70
        }
    }
    package var label: String {
        switch self {
        case .from95: "95–100"
        case .from90: "90–<95"
        case .from80: "80–<90"
        case .from70: "70–<80"
        case .below70: "<70"
        }
    }
    var lightColor: String { ["#B8243A", "#A94B10", "#8A6400", "#2165C0", "#12805C"][rawValue] }
    var darkColor: String { ["#FF8196", "#FFA45D", "#F2D06B", "#7DB1FF", "#69DBAF"][rawValue] }
}

struct ScoreVertex: Identifiable {
    let id: Int
    let pts: Double
    let score: Double
}
struct ScoreTrace: Identifiable {
    let id: Int
    let segment: Int
    let band: ScoreBand
    var vertices: [ScoreVertex]
}

enum ScoreBandChart {
    static func target(_ value: Double) -> Double { value.isFinite ? min(100, max(0, value)) : 90 }

    /// Intersect the straight line with every band boundary, so a color transition
    /// occurs at the score boundary rather than at the next sampled frame.
    static func traces(_ points: [QualityPoint]) -> [ScoreTrace] {
        var traces: [ScoreTrace] = []
        var previous: QualityPoint?
        for point in points where point.pts.isFinite && point.score.isFinite {
            guard let last = previous, last.segment == point.segment, point.pts > last.pts else {
                traces.append(ScoreTrace(id: traces.count, segment: point.segment, band: ScoreBand(score: point.score),
                    vertices: [ScoreVertex(id: 0, pts: point.pts, score: point.score)]))
                previous = point
                continue
            }
            var stops: [(Double, Double)] = [(last.pts, last.score)]
            let boundaries: [Double] = [70, 80, 90, 95]
            let crossings = boundaries.filter { $0 > min(last.score, point.score) && $0 < max(last.score, point.score) }
                .sorted { last.score < point.score ? $0 < $1 : $0 > $1 }
            for boundary in crossings {
                let fraction = (boundary - last.score) / (point.score - last.score)
                stops.append((last.pts + fraction * (point.pts - last.pts), boundary))
            }
            stops.append((point.pts, point.score))
            for index in 1..<stops.count {
                let start = stops[index - 1], end = stops[index]
                let band = ScoreBand(score: (start.1 + end.1) / 2)
                if let trace = traces.last, trace.segment == point.segment, trace.band == band {
                    traces[traces.count - 1].vertices.append(ScoreVertex(id: trace.vertices.count, pts: end.0, score: end.1))
                } else {
                    traces.append(ScoreTrace(id: traces.count, segment: point.segment, band: band,
                        vertices: [ScoreVertex(id: 0, pts: start.0, score: start.1), ScoreVertex(id: 1, pts: end.0, score: end.1)]))
                }
            }
            previous = point
        }
        return traces
    }
}
