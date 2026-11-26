import Foundation

/// Non-destructive editing of point arrays. Joining never invents a connection.
public enum TrackEdit {
    public static func trim<T>(_ points: [T], start: Int, end: Int) -> [T]? {
        guard start >= 0, end < points.count, start < end else { return nil }
        return Array(points[start...end])
    }

    /// The split point is shared by both pieces so neither loses an original edge.
    public static func split<T>(_ points: [T], at index: Int) -> ([T], [T])? {
        guard index > 0, index < points.count - 1 else { return nil }
        return (Array(points[...index]), Array(points[index...]))
    }

    /// Reject overlapping time ranges rather than rewriting GPS timestamps.
    public static func join<T>(_ first: [T], _ second: [T],
                               timestamp: (T) -> Date, startSegment: (T) -> T) -> [T]? {
        guard first.count >= 2, second.count >= 2,
              let last = first.last, let next = second.first,
              timestamp(last) < timestamp(next),
              zip(first, first.dropFirst()).allSatisfy({ timestamp($0.0) < timestamp($0.1) }),
              zip(second, second.dropFirst()).allSatisfy({ timestamp($0.0) < timestamp($0.1) }) else { return nil }
        return first + [startSegment(next)] + Array(second.dropFirst())
    }
}
