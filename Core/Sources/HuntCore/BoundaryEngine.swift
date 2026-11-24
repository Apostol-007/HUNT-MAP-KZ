import Foundation
public enum BoundaryEvent: Equatable, Sendable {
    case approaching(zoneID: String, meters: Int)
    case uncertain(zoneID: String)
    case entered(zoneID: String)
    case exited(zoneID: String)
}
public struct GPSFix: Sendable {
    public var position: GeoPoint
    public var accuracyMeters: Double
    public var timestamp: Date
    public init(position: GeoPoint, accuracyMeters: Double, timestamp: Date) { self.position = position; self.accuracyMeters = accuracyMeters; self.timestamp = timestamp }
}
public final class BoundaryEngine {
    private var settled: [String: Bool] = [:]
    private var pending: [String: (value: Bool, count: Int)] = [:]
    private var lastAlert: [String: Date] = [:]
    public var requiredFixes = 3
    public var hysteresisMeters = 20.0
    public var accuracyLimit = 75.0
    public var cooldownSeconds = 120.0
    public init() {}
    public func process(_ fix: GPSFix, zones: [GeoZone], now: Date = Date()) -> [BoundaryEvent] {
        guard fix.position.valid, fix.accuracyMeters >= 0, fix.accuracyMeters <= 5000,
              abs(fix.timestamp.timeIntervalSince(now)) <= 30 else { return [] }
        var events: [BoundaryEvent] = []
        for zone in zones {
            let distance = zone.distanceToBoundaryMeters(fix.position)
            let inside = zone.contains(fix.position)
            let prior = settled[zone.id]
            if fix.accuracyMeters > accuracyLimit || distance <= fix.accuracyMeters + hysteresisMeters {
                pending.removeValue(forKey:zone.id)
                if allow("uncertain:\(zone.id)",now:now) { events.append(.uncertain(zoneID: zone.id)) }
                continue
            }
            if prior == nil { settled[zone.id] = inside; continue }
            if prior != inside {
                let prev = pending[zone.id]
                let count = prev?.value == inside ? (prev!.count + 1) : 1
                pending[zone.id] = (inside, count)
                if count >= requiredFixes {
                    settled[zone.id] = inside
                    pending.removeValue(forKey:zone.id)
                    // Always publish confirmed transition, even if proximity warnings are in cooldown.
                    events.append(inside ? .entered(zoneID:zone.id) : .exited(zoneID:zone.id))
                }
            } else { pending.removeValue(forKey:zone.id) }
            if distance <= 500 {
                let threshold = distance <= 100 ? 100 : distance <= 200 ? 200 : 500
                if allow("near:\(zone.id):\(threshold)",now:now) { events.append(.approaching(zoneID:zone.id, meters:threshold)) }
            }
        }
        return events
    }
    private func allow(_ key:String,now:Date) -> Bool {
        if let last = lastAlert[key], now.timeIntervalSince(last) < cooldownSeconds { return false }
        lastAlert[key] = now
        return true
    }
}

/// Bounded FIFO for GPS processing. On overload, the caller must reset its
/// crossing state: fixes separated by a dropped interval are not consecutive.
public struct BoundaryFixQueue: Sendable {
    private var fixes: [GPSFix] = []
    private let capacity: Int
    public init(capacity: Int = 128) { self.capacity = max(1, capacity) }
    @discardableResult public mutating func append(_ fix: GPSFix) -> Bool {
        let overflow = fixes.count >= capacity
        if overflow { fixes.removeAll(keepingCapacity: true) }
        fixes.append(fix)
        return overflow
    }
    public mutating func popFirst() -> GPSFix? {
        guard !fixes.isEmpty else { return nil }
        return fixes.removeFirst()
    }
    public mutating func removeAll() { fixes.removeAll(keepingCapacity: true) }
}
