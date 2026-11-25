import Foundation

public enum GroundGeometryValidation {
    public enum Failure: LocalizedError {
        case empty, invalidRing, intersection, outside
        public var errorDescription: String? {
            switch self {
            case .empty: return "Добавьте хотя бы один полигон"
            case .invalidRing: return "Контур должен содержать минимум три различные вершины без самопересечений"
            case .intersection: return "Контуры пересекаются или касаются"
            case .outside: return "Внутренний контур должен полностью находиться внутри внешнего"
            }
        }
    }
    public static func validate(_ polygons: [[[GeoPoint]]]) throws {
        guard !polygons.isEmpty else { throw Failure.empty }
        for rings in polygons {
            guard let outer = rings.first else { throw Failure.empty }
            for ring in rings {
                guard FieldMeasurements.area(ring) != nil else { throw Failure.invalidRing }
            }
            for (i, hole) in rings.dropFirst().enumerated() {
                guard hole.allSatisfy({ GeoMath.inRing($0, ring: outer) }),
                      !intersects(outer,hole) else { throw Failure.outside }
                for other in rings.dropFirst().prefix(i) {
                    if intersects(hole,other) || GeoMath.inRing(hole[0],ring:other) || GeoMath.inRing(other[0],ring:hole) {
                        throw Failure.intersection
                    }
                }
            }
        }
        for i in polygons.indices {
            let a = polygons[i]
            for b in polygons.dropFirst(i+1) {
                for ar in a {
                    for br in b where intersects(ar,br) { throw Failure.intersection }
                }
                let pa=GeoPolygon(rings:a), pb=GeoPolygon(rings:b)
                if pa.contains(b[0][0]) || pb.contains(a[0][0]) { throw Failure.intersection }
            }
        }
    }
    private static func intersects(_ a:[GeoPoint],_ b:[GeoPoint])->Bool {
        func cross(_ p:GeoPoint,_ q:GeoPoint,_ r:GeoPoint)->Double {
            (q.longitude-p.longitude)*(r.latitude-p.latitude)-(q.latitude-p.latitude)*(r.longitude-p.longitude)
        }
        func on(_ p:GeoPoint,_ q:GeoPoint,_ r:GeoPoint)->Bool {
            abs(cross(p,q,r)) <= 1e-12 &&
            r.longitude >= min(p.longitude,q.longitude)-1e-10 && r.longitude <= max(p.longitude,q.longitude)+1e-10 &&
            r.latitude >= min(p.latitude,q.latitude)-1e-10 && r.latitude <= max(p.latitude,q.latitude)+1e-10
        }
        for (p,q) in GeoMath.segments(a) {
            for (r,s) in GeoMath.segments(b) {
                let x=cross(p,q,r), y=cross(p,q,s), z=cross(r,s,p), w=cross(r,s,q)
                if ((x>0 && y<0 || x<0 && y>0) && (z>0 && w<0 || z<0 && w>0)) ||
                    on(p,q,r) || on(p,q,s) || on(r,s,p) || on(r,s,q) { return true }
            }
        }
        return false
    }
}
