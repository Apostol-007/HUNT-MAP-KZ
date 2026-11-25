import Foundation

public struct TrackReturnTracker {
    public enum Status: String {
        case waiting = "Ожидание точного GPS"
        case following = "Следуйте по записанному пути"
        case approachingDeviation = "Приближение к порогу отклонения"
        case offTrack = "Подтверждено отклонение от пути"
        case arrived = "Исходная точка достигнута"
    }
    public struct Result {
        public let remaining: Double
        public let deviation: Double?
        public let status: Status
        public var arrived: Bool { status == .arrived }
    }
    private let points: [GeoPoint]
    private let cumulative: [Double]
    private var segment = 0
    private var progress: Double = 0
    private var lastTime: Date?
    private var lastPosition: GeoPoint?
    private var outside = 0
    private var arrivals = 0
    private var result: Result
    public init?(points: [GeoPoint]) {
        guard points.count >= 2, points.allSatisfy({ $0.valid }) else { return nil }
        var distances = [0.0]
        for i in 1..<points.count {
            distances.append(distances[i-1] + GeoMath.meters(points[i-1], points[i]))
        }
        guard let total = distances.last, total.isFinite, total >= 15 else { return nil }
        self.points = points
        cumulative = distances
        result = Result(remaining: total, deviation: nil, status: .waiting)
    }
    public mutating func update(position: GeoPoint, accuracy: Double, timestamp: Date) -> Result {
        guard position.valid, accuracy.isFinite, accuracy >= 0, accuracy <= 50,
              lastTime.map({ timestamp > $0 }) ?? true else { return result }
        let elapsed = lastTime.map { timestamp.timeIntervalSince($0) } ?? 0
        let observed = lastPosition.map { GeoMath.meters($0, position) } ?? 0
        lastTime = timestamp
        lastPosition = position
        let total = cumulative.last ?? 0
        // Limit forward matching by physical movement, not a fixed count of vertices.
        // An unobserved gap cannot silently advance progress around a crossing.
        let budget = elapsed > 0 && elapsed <= 30 ? min(observed + 15, elapsed * 4 + 15) : 15
        let limit = min(total, progress + budget)
        var bestDistance = Double.infinity
        var bestProgress = progress
        var bestSegment = segment
        var i = segment
        while i < points.count - 1 {
            if cumulative[i] > limit { break }
            let length = cumulative[i+1] - cumulative[i]
            let projected = project(position, onto: points[i], points[i+1])
            let fractionLimit = length > 0 ? max(0, min(1, (limit-cumulative[i])/length)) : 0
            let fraction = min(projected, fractionLimit)
            let candidate = interpolate(points[i], points[i+1], fraction)
            let distance = GeoMath.meters(position, candidate)
            let along = cumulative[i] + length * fraction
            if distance < bestDistance {
                bestDistance = distance
                bestProgress = along
                bestSegment = i
            }
            i += 1
        }
        if bestDistance <= max(15, accuracy) && bestProgress >= progress {
            progress = bestProgress
            segment = bestSegment
        }
        let certainDistance = max(0, bestDistance - accuracy)
        if certainDistance > 50 { outside += 1 } else { outside = 0 }
        let nearEnd = total - progress <= 15
        let endDistance = GeoMath.meters(position, points[points.count-1])
        if nearEnd && accuracy <= 10 && endDistance <= 15 { arrivals += 1 } else { arrivals = 0 }
        let status: Status = arrivals >= 3 ? .arrived : outside >= 3 ? .offTrack : certainDistance > 30 ? .approachingDeviation : .following
        result = Result(remaining: max(0,total-progress), deviation: bestDistance.isFinite ? bestDistance : nil, status: status)
        return result
    }
    private func project(_ p: GeoPoint, onto a: GeoPoint, _ b: GeoPoint) -> Double {
        let k = cos(a.latitude * .pi / 180)
        let dx = (b.longitude-a.longitude)*k, dy = b.latitude-a.latitude
        let px = (p.longitude-a.longitude)*k, py = p.latitude-a.latitude
        let denominator = dx*dx+dy*dy
        return denominator > 0 ? max(0,min(1,(px*dx+py*dy)/denominator)) : 0
    }
    private func interpolate(_ a: GeoPoint,_ b: GeoPoint,_ f: Double) -> GeoPoint {
        GeoPoint(a.latitude+(b.latitude-a.latitude)*f,a.longitude+(b.longitude-a.longitude)*f)
    }
}
