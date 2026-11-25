import Foundation

public enum FieldMeasurements {
    public static func distance(_ points: [GeoPoint]) -> Double {
        guard points.allSatisfy({ $0.valid }) else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + GeoMath.meters($1.0, $1.1) }
    }
    public static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double? {
        guard a.valid, b.valid, GeoMath.meters(a,b) > 0.01 else { return nil }
        let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180
        let d = (b.longitude-a.longitude) * .pi / 180
        let angle = atan2(sin(d)*cos(q), cos(p)*sin(q)-sin(p)*cos(q)*cos(d)) * 180 / .pi
        return (angle + 360).truncatingRemainder(dividingBy: 360)
    }
    // Spherical polygon area, with local self-intersection validation for field-scale polygons.
    public static func area(_ points: [GeoPoint]) -> Double? {
        guard points.count >= 3, points.allSatisfy({ $0.valid }) else { return nil }
        let n = points.count
        let origin = points[0]
        guard points.allSatisfy({ abs($0.longitude-origin.longitude) < 10 && GeoMath.meters(origin,$0) < 200_000 }) else { return nil }
        func cross(_ a: GeoPoint,_ b: GeoPoint,_ c: GeoPoint) -> Double {
            (b.longitude-a.longitude)*(c.latitude-a.latitude)-(b.latitude-a.latitude)*(c.longitude-a.longitude)
        }
        func onSegment(_ a: GeoPoint,_ b: GeoPoint,_ c: GeoPoint) -> Bool {
            abs(cross(a,b,c)) < 1e-12 && c.longitude >= min(a.longitude,b.longitude)-1e-10 && c.longitude <= max(a.longitude,b.longitude)+1e-10 && c.latitude >= min(a.latitude,b.latitude)-1e-10 && c.latitude <= max(a.latitude,b.latitude)+1e-10
        }
        for i in 0..<n {
            let a = points[i], b = points[(i+1)%n]
            if GeoMath.meters(a,b) < 0.01 { return nil }
            for j in (i+1)..<n {
                if j == i+1 || (i == 0 && j == n-1) { continue }
                let c=points[j], d=points[(j+1)%n]
                let p=cross(a,b,c), q=cross(a,b,d), r=cross(c,d,a), s=cross(c,d,b)
                if ((p>0 && q<0 || p<0 && q>0) && (r>0 && s<0 || r<0 && s>0)) ||
                    onSegment(a,b,c) || onSegment(a,b,d) || onSegment(c,d,a) || onSegment(c,d,b) { return nil }
            }
        }
        var sum=0.0
        for i in 0..<n {
            let a=points[i], b=points[(i+1)%n]
            let dl=(b.longitude-a.longitude) * .pi/180
            sum += dl * (sin(a.latitude * .pi/180)+sin(b.latitude * .pi/180))
        }
        let result=abs(sum)*6371008.8*6371008.8/2
        return result > 0.01 ? result : nil
    }
}
