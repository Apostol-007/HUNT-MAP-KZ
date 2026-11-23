import Foundation

/// Geometry is computed only within cells with valid model data. Geographic coordinates are degrees.
public enum WeatherGeometry {
    public struct Sample: Sendable {
        public let latitude: Double
        public let longitude: Double
        public let value: Double?
        public init(latitude: Double, longitude: Double, value: Double?) {
            self.latitude = latitude; self.longitude = longitude; self.value = value
        }
    }
    public struct Coordinate: Sendable {
        public let latitude: Double
        public let longitude: Double
        public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    }
    public struct Segment: Sendable {
        public let a: Coordinate
        public let b: Coordinate
        public let level: Double
    }
    public struct ShadedCell: Sendable {
        public let corners: [Coordinate]
        public let value: Double
    }
    /// Meteorological directions mean FROM; the arrow must point TO.
    public static func windArrow(latitude: Double, longitude: Double, fromDegrees: Double, speedKmh: Double, lengthDegrees: Double) -> [Segment] {
        guard latitude.isFinite, longitude.isFinite, fromDegrees.isFinite, speedKmh.isFinite,
              (0...360).contains(fromDegrees), speedKmh >= 0, lengthDegrees > 0 else { return [] }
        let to = (fromDegrees + 180) * .pi / 180
        let latRadius = lengthDegrees * 0.5
        let lonRadius = latRadius / max(0.2, cos(latitude * .pi / 180))
        let dy = cos(to) * latRadius
        let dx = sin(to) * lonRadius
        let a = Coordinate(latitude - dy, longitude - dx)
        let tip = Coordinate(latitude + dy, longitude + dx)
        let wing = lengthDegrees * 0.25
        let backwards = to + .pi
        let left = Coordinate(tip.latitude + cos(backwards + 0.6) * wing,
                              tip.longitude + sin(backwards + 0.6) * wing / max(0.2, cos(latitude * .pi / 180)))
        let right = Coordinate(tip.latitude + cos(backwards - 0.6) * wing,
                               tip.longitude + sin(backwards - 0.6) * wing / max(0.2, cos(latitude * .pi / 180)))
        return [Segment(a: a, b: tip, level: speedKmh), Segment(a: tip, b: left, level: speedKmh), Segment(a: tip, b: right, level: speedKmh)]
    }
    /// Bilinear interpolation on a regular 2D grid, returning actual forecast-derived subcells.
    /// A missing corner prevents interpolation of the *entire* source cell.
    public static func shade(samples: [Sample], width: Int, height: Int, subdivisions: Int = 4) -> [ShadedCell] {
        guard width >= 2, height >= 2, width <= 32, height <= 32,
              samples.count == width * height, (1...6).contains(subdivisions) else { return [] }
        var result: [ShadedCell] = []
        for row in 0..<(height - 1) { for col in 0..<(width - 1) {
            let sw = samples[row*width+col], se = samples[row*width+col+1]
            let nw = samples[(row+1)*width+col], ne = samples[(row+1)*width+col+1]
            guard let a = sw.value, let b = se.value, let c = nw.value, let d = ne.value,
                  [a,b,c,d].allSatisfy({ $0.isFinite }), sw.latitude < nw.latitude, sw.longitude < se.longitude else { continue }
            func interpolated(_ u: Double, _ v: Double) -> Double {
                a*(1-u)*(1-v) + b*u*(1-v) + c*(1-u)*v + d*u*v
            }
            func coord(_ u: Double, _ v: Double) -> Coordinate {
                Coordinate(sw.latitude + (nw.latitude-sw.latitude)*v, sw.longitude + (se.longitude-sw.longitude)*u)
            }
            for y in 0..<subdivisions { for x in 0..<subdivisions {
                let u = Double(x)/Double(subdivisions), v = Double(y)/Double(subdivisions)
                let u2 = Double(x+1)/Double(subdivisions), v2 = Double(y+1)/Double(subdivisions)
                result.append(ShadedCell(corners: [coord(u,v),coord(u2,v),coord(u2,v2),coord(u,v2)],
                                         value: interpolated((u+u2)/2, (v+v2)/2)))
            } }
        } }
        return result
    }
    /// Marching squares; ambiguous saddle cases yield two separate segments, never a false crossing.
    public static func isolines(samples: [Sample], width: Int, height: Int, levels: [Double]) -> [Segment] {
        guard width >= 2, height >= 2, samples.count == width*height, levels.count <= 40 else { return [] }
        var output: [Segment] = []
        for row in 0..<(height-1) { for col in 0..<(width-1) {
            let indexes = [row*width+col, row*width+col+1, (row+1)*width+col+1, (row+1)*width+col]
            let corners = indexes.map { samples[$0] }
            guard corners.allSatisfy({ $0.value?.isFinite == true }) else { continue }
            let values = corners.map { $0.value! }
            for level in levels where level.isFinite {
                var crossings: [Coordinate] = []
                for edge in 0..<4 {
                    let next = (edge+1)%4, x = values[edge], y = values[next]
                    guard (x < level && y >= level) || (y < level && x >= level), x != y else { continue }
                    let t = (level-x)/(y-x)
                    crossings.append(Coordinate(corners[edge].latitude + t*(corners[next].latitude-corners[edge].latitude),
                                                corners[edge].longitude + t*(corners[next].longitude-corners[edge].longitude)))
                }
                if crossings.count == 2 { output.append(Segment(a: crossings[0], b: crossings[1], level: level)) }
                if crossings.count == 4 {
                    output.append(Segment(a: crossings[0], b: crossings[1], level: level))
                    output.append(Segment(a: crossings[2], b: crossings[3], level: level))
                }
            }
        } }
        return output
    }
}
