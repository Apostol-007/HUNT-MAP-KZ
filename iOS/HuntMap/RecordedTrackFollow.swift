import Foundation
import HuntCore

enum RecordedRouteDirection: String, CaseIterable {
    case forward = "От начала"
    case backward = "От конца"
}

/// Recorded GPS geometry is replayed exactly as captured, without inventing road segments.
/// Stored tracks are not automatically treated as safe or legally traversable routes.
struct RecordedTrackFollow {
    let trackID: UUID
    let direction: RecordedRouteDirection
    let points: [GeoPoint]
    let remainingFrom: [Double]

    init?(track: Track, direction: RecordedRouteDirection) {
        let original = track.fixes.map(\.point).filter(\.valid)
        guard original.count >= 2 else { return nil }
        self.trackID = track.id
        self.direction = direction
        self.points = direction == .forward ? original : Array(original.reversed())
        var remaining = [Double](repeating: 0, count: points.count)
        for i in stride(from: points.count - 2, through: 0, by: -1) {
            remaining[i] = remaining[i + 1] + GeoMath.meters(points[i], points[i + 1])
        }
        self.remainingFrom = remaining
    }

    /// Find a nearby point in a forward-only corridor; avoid snapping progress
    /// to a later crossing where the trail loops back over itself.
    func progress(from gps: GeoPoint, after currentIndex: Int) -> (index: Int, deviation: Double, remaining: Double) {
        guard gps.valid else {
            let i = max(0, min(currentIndex, points.count - 1))
            return (i, .infinity, remainingFrom[i])
        }
        let lower = max(0, min(currentIndex, points.count - 1))
        let upper = min(points.count - 1, lower + 150)
        var closest = lower
        var distance = Double.infinity
        for i in lower...upper {
            let candidate = i < points.count - 1
                ? GeoMath.segmentDistance(gps, points[i], points[i + 1])
                : GeoMath.meters(gps, points[i])
            if candidate < distance { distance = candidate; closest = i }
        }
        return (closest, distance, remainingFrom[closest])
    }
}
