import Foundation

/// Rendering-only reduction. Never use the reduced points for recording, distance, or export.
public enum TrackRendering {
    /// Preserves endpoints and prominent bends; output size is bounded for long tracks.
    public static func simplified(_ points: [GeoPoint], toleranceMeters: Double = 4, maxPoints: Int = 2500) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        let tolerance = max(0, toleranceMeters)
        let cap = max(2, maxPoints)
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maximum = tolerance
            var chosen: Int? = nil
            for index in (start + 1)..<end {
                let distance = GeoMath.segmentDistance(points[index], points[start], points[end])
                if distance > maximum { maximum = distance; chosen = index }
            }
            if let chosen {
                keep[chosen] = true
                stack.append((start, chosen)); stack.append((chosen, end))
            }
        }
        let reduced = points.indices.filter { keep[$0] }.map { points[$0] }
        guard reduced.count > cap else { return reduced }
        // Retain both endpoints even when applying the emergency rendering cap.
        return (0..<cap).map { reduced[$0 * (reduced.count - 1) / (cap - 1)] }
    }
}
