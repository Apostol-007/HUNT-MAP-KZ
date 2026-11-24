import UIKit
import MapLibre
import HuntCore

/// Native labels do not depend on the basemap's sprite or glyph endpoints.
/// Positions are recomputed from the map projection, not from the user's GPS.
final class GroundLabelsOverlay: UIView {
    private struct Entry {
        let id: String
        let name: String
        let point: GeoPoint
    }

    private weak var mapView: MLNMapView?
    private var entries: [Entry] = []
    private var selectedID: String?
    private var contentKey: String?
    private var lastPaint: CFTimeInterval = 0

    init(mapView: MLNMapView, hostView: UIView) {
        self.mapView = mapView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
        translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            topAnchor.constraint(equalTo: hostView.topAnchor),
            bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(zones: [GeoZone], selectedID: String?, key: String) {
        guard contentKey != key else { return }
        contentKey = key
        self.selectedID = selectedID
        entries = zones.compactMap { zone in
            guard let point = Self.anchor(in: zone) else { return nil }
            return Entry(id: zone.id, name: zone.name, point: point)
        }
        isHidden = entries.isEmpty
        setNeedsDisplay()
    }

    // Prefer a point inside the largest polygon, excluding its holes.
    // A bounding-box center alone is often outside a concave territory.
    private static func anchor(in zone: GeoZone) -> GeoPoint? {
        let candidates = zone.polygons.compactMap { polygon -> (GeoPolygon, Double, Double, Double, Double, Double)? in
            guard let ring = polygon.rings.first, ring.count >= 3,
                  let south = ring.map(\.latitude).min(), let north = ring.map(\.latitude).max(),
                  let west = ring.map(\.longitude).min(), let east = ring.map(\.longitude).max(),
                  north > south, east > west else { return nil }
            var signedArea = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                signedArea += (a.longitude - west) * (b.latitude - south) - (b.longitude - west) * (a.latitude - south)
            }
            return (polygon, abs(signedArea), south, north, west, east)
        }.sorted { $0.1 > $1.1 }
        for (polygon, _, south, north, west, east) in candidates {
            let center = GeoPoint((south + north) / 2, (west + east) / 2)
            if polygon.contains(center) { return center }
            // Bounded deterministic search for an interior point.
            for row in 0..<9 {
                for col in 0..<9 {
                    let point = GeoPoint(south + (north - south) * (Double(row) + 0.5) / 9,
                                         west + (east - west) * (Double(col) + 0.5) / 9)
                    if polygon.contains(point) { return point }
                }
            }
        }
        return zone.polygons.first?.rings.first?.first
    }

    func cameraChanged(force: Bool = false) {
        guard !isHidden else { return }
        let now = CACurrentMediaTime()
        if force || now - lastPaint >= 1.0 / 20.0 {
            lastPaint = now
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let mapView, !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let zoom = mapView.zoomLevel
        let visible = bounds.insetBy(dx: 8, dy: 8)
        var occupied: [CGRect] = []
        let ordered = entries.sorted {
            let a = $0.id == selectedID, b = $1.id == selectedID
            if a != b { return a }
            return $0.id < $1.id
        }
        for entry in ordered {
            let selected = entry.id == selectedID
            guard selected || zoom >= 6.5 else { continue }
            let location = CLLocationCoordinate2D(latitude: entry.point.latitude, longitude: entry.point.longitude)
            let point = mapView.convert(location, toPointTo: self)
            guard point.x.isFinite, point.y.isFinite, visible.contains(point) else { continue }
            let font = UIFont.systemFont(ofSize: selected ? 16 : (zoom >= 10 ? 13 : 11), weight: selected ? .bold : .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ]
            let text = NSAttributedString(string: entry.name, attributes: attributes)
            let maxWidth: CGFloat = selected ? 180 : 126
            let measured = text.boundingRect(with: CGSize(width: maxWidth, height: 1000),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let width = min(maxWidth, ceil(measured.width)) + 14
            let height = min(ceil(measured.height), font.lineHeight * 3) + 10
            let box = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            guard visible.contains(box), !occupied.contains(where: { $0.intersects(box.insetBy(dx: -5, dy: -4)) }) else { continue }
            occupied.append(box)
            let background = UIBezierPath(roundedRect: box, cornerRadius: 7)
            UIColor(red: 0.025, green: 0.11, blue: 0.065, alpha: selected ? 0.96 : 0.86).setFill()
            background.fill()
            if selected {
                UIColor(red: 0.48, green: 1, blue: 0.36, alpha: 1).setStroke()
                background.lineWidth = 1.5
                background.stroke()
            }
            text.draw(with: box.insetBy(dx: 7, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
    }
}
