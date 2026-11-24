import Foundation

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var valid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

public struct GeoPolygon: Codable, Sendable {
    // First ring is exterior; following rings are holes. Rings may be closed or open.
    public let rings: [[GeoPoint]]
    public init(rings: [[GeoPoint]]) { self.rings = rings }
    public func contains(_ point: GeoPoint) -> Bool {
        guard point.valid, let outer = rings.first, GeoMath.inRing(point, ring: outer) else { return false }
        return !rings.dropFirst().contains { GeoMath.inRing(point, ring: $0) }
    }
    public func distanceToBoundaryMeters(_ point: GeoPoint) -> Double {
        rings.flatMap { GeoMath.segments($0) }.map { GeoMath.segmentDistance(point, $0.0, $0.1) }.min() ?? .infinity
    }
}

public enum ZoneKind: String, Codable, Sendable { case huntingGround, protectedArea }
public struct GeoZone: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: ZoneKind
    public let verified: Bool
    public let source: String
    public let polygons: [GeoPolygon]
    /// Original source attributes, preserved without pretending they are legally verified.
    public var attributes: [String: String]? = nil
    public init(id: String, name: String, kind: ZoneKind, verified: Bool, source: String, polygons: [GeoPolygon], attributes: [String: String]? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.verified = verified; self.source = source; self.polygons = polygons; self.attributes = attributes
    }
    public func contains(_ point: GeoPoint) -> Bool { polygons.contains { $0.contains(point) } }
    public func distanceToBoundaryMeters(_ point: GeoPoint) -> Double { polygons.map { $0.distanceToBoundaryMeters(point) }.min() ?? .infinity }
}

public enum GeoMath {
    public static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dp/2), 2) + cos(p1) * cos(p2) * pow(sin(dl/2), 2)
        return 2*r*atan2(sqrt(max(0,h)), sqrt(max(0,1-h)))
    }
    public static func segments(_ ring: [GeoPoint]) -> [(GeoPoint, GeoPoint)] {
        guard ring.count >= 3 else { return [] }
        return (0..<ring.count).map { (ring[$0], ring[($0+1)%ring.count]) }
    }
    // Unwrap longitudes around the query so a polygon spanning the antimeridian works.
    static func unwrap(_ lon: Double, around reference: Double) -> Double {
        var delta = lon-reference
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return reference+delta
    }
    public static func inRing(_ p: GeoPoint, ring: [GeoPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        let x = p.longitude, y = p.latitude
        for (a, b) in segments(ring) {
            let ax = unwrap(a.longitude, around: x), bx = unwrap(b.longitude, around: x)
            let cross = (bx-ax)*(y-a.latitude)-(b.latitude-a.latitude)*(x-ax)
            if abs(cross) < 1e-11 && x >= min(ax,bx)-1e-11 && x <= max(ax,bx)+1e-11 && y >= min(a.latitude,b.latitude)-1e-11 && y <= max(a.latitude,b.latitude)+1e-11 { return true }
            if (a.latitude > y) != (b.latitude > y) && x < (bx-ax)*(y-a.latitude)/(b.latitude-a.latitude)+ax { inside.toggle() }
        }
        return inside
    }
    public static func segmentDistance(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> Double {
        // Local tangent approximation sufficient for short boundary segments; long segments require geodesic subdivision.
        let latScale = 111_195.0, lonScale = latScale * max(0.01,cos(p.latitude * .pi/180))
        let ax = (unwrap(a.longitude, around:p.longitude)-p.longitude)*lonScale
        let ay = (a.latitude-p.latitude)*latScale
        let bx = (unwrap(b.longitude, around:p.longitude)-p.longitude)*lonScale
        let by = (b.latitude-p.latitude)*latScale
        let dx = bx-ax, dy = by-ay
        let t = max(0,min(1,-(ax*dx+ay*dy)/max(1e-15,dx*dx+dy*dy)))
        return hypot(ax+t*dx,ay+t*dy)
    }
}
