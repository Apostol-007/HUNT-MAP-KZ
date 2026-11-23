import Foundation

/// Geographic WGS84 grid for selecting published map/routing packs.
/// Each cell is a selection area, not an image tile and not a generated MBTiles file.
struct OfflineGridCell: Hashable, Identifiable {
    let x: Int
    let y: Int
    let step: Double

    var id: String { "\(x)_\(y)" }
    var bounds: [Double] {
        [Double(x) * step, Double(y) * step,
         Double(x + 1) * step, Double(y + 1) * step]
    }

    init?(latitude: Double, longitude: Double, step: Double) {
        guard (0.01...1).contains(step), latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        self.step = step
        self.x = Int(floor(min(longitude, 179.999999) / step))
        self.y = Int(floor(min(latitude, 89.999999) / step))
    }

    init?(id: String, step: Double) {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]),
              (0.01...1).contains(step),
              Double(x) * step >= -180, Double(x + 1) * step <= 180.000001,
              Double(y) * step >= -90, Double(y + 1) * step <= 90.000001
        else { return nil }
        self.x = x; self.y = y; self.step = step
    }

    func intersects(_ other: [Double]) -> Bool {
        guard other.count == 4, other.allSatisfy({ $0.isFinite }),
              other[0] <= other[2], other[1] <= other[3] else { return false }
        let b = bounds
        return b[0] < other[2] && b[2] > other[0] &&
               b[1] < other[3] && b[3] > other[1]
    }
}
