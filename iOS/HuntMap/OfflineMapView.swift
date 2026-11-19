import SwiftUI
import MapLibre
import HuntCore

/// MapLibre receives only a locally generated, source-free style and file-backed MBTiles.
/// No HTTP style, glyph, sprite or tile endpoint is configured by this view.
struct OfflineMapView: UIViewRepresentable {
    let zones: [GeoZone]
    let position: GeoPoint?
    let travelHeading: Double?
    let markers: [Marker]
    let track: Track?
    let centerRequest: Int
    let mapStyle: String
    let tileFiles: [URL]
    let tileRevision: Int
    let offlineOSMLines: [OSMOfflineLine]
    let offlineOSMRevision: Int
    let downloadGridVisible: Bool
    let downloadedRegions: [OSMDownloadedRegion]
    let online: Bool
    var onMarkerSelect: (UUID) -> Void
    var onMarkerMove: (UUID, GeoPoint) -> Void
    @Binding var selectedZone: GeoZone?
    var onMapTap: (GeoPoint) -> Void

    private var safeOnlineStyle: String {
        ["liberty", "bright", "positron"].contains(mapStyle) ? mapStyle : "liberty"
    }

    func makeCoordinator() -> Coordinator { Coordinator(selectedZone: $selectedZone, onMapTap: onMapTap, onMarkerSelect: onMarkerSelect, onMarkerMove: onMarkerMove) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = online ? URL(string: "https://tiles.openfreemap.org/styles/liberty".replacingOccurrences(of: "liberty", with: safeOnlineStyle))! : OfflineMapStyle.url
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        context.coordinator.zones = zones
        context.coordinator.markers = markers
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMarkerDrag(_:)))
        hold.minimumPressDuration = 0.45
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)
        context.coordinator.map = view
        view.setCenter(CLLocationCoordinate2D(latitude: 43.24, longitude: 76.91), zoomLevel: 11, animated: false)
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        let requestedOnline = online
        let wantedStyle = requestedOnline ? URL(string: "https://tiles.openfreemap.org/styles/liberty".replacingOccurrences(of: "liberty", with: safeOnlineStyle))! : OfflineMapStyle.url
        if view.styleURL != wantedStyle { view.styleURL = wantedStyle }
        if context.coordinator.lastCenterRequest != centerRequest {
            context.coordinator.lastCenterRequest = centerRequest
            if let target = position ?? markers.first(where: { $0.kind == "Машина" })?.coordinate ?? markers.first?.coordinate {
                view.setCenter(CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude), animated: true)
            }
        }
        context.coordinator.zones = zones
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMarkerSelect = onMarkerSelect
        context.coordinator.onMarkerMove = onMarkerMove
        context.coordinator.markers = markers
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        context.coordinator.updateOSMLines(view: view, lines: offlineOSMLines, revision: offlineOSMRevision)
        context.coordinator.updateDownloadGrid(view: view, visible: downloadGridVisible, regions: downloadedRegions, revision: offlineOSMRevision)
        context.coordinator.updateAnnotations(view: view, zones: zones, markers: markers, position: position, heading: travelHeading, track: track)

    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var selectedZone: Binding<GeoZone?>
        var onMapTap: (GeoPoint) -> Void
        var onMarkerSelect: (UUID) -> Void
        var onMarkerMove: (UUID, GeoPoint) -> Void
        var markers: [Marker] = []
        private var draggedMarkerID: UUID?
        weak var map: MLNMapView?
        var zones: [GeoZone] = []
        var lastCenterRequest = 0
        init(selectedZone: Binding<GeoZone?>, onMapTap: @escaping (GeoPoint) -> Void, onMarkerSelect: @escaping (UUID) -> Void, onMarkerMove: @escaping (UUID, GeoPoint) -> Void) {
            self.selectedZone = selectedZone
            self.onMapTap = onMapTap
            self.onMarkerSelect = onMarkerSelect
            self.onMarkerMove = onMarkerMove
        }
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            let position = GeoPoint(coordinate.latitude, coordinate.longitude)
            if let nearest = nearestMarker(to: recognizer.location(in: map), on: map) {
                onMarkerSelect(nearest.id)
                return
            }
            // Find the smallest enclosing boundary for overlapping territories.
            let matching = zones.filter { $0.contains(position) }
            if let zone = matching.first { selectedZone.wrappedValue = zone }
            else { onMapTap(position) }
        }

        private func nearestMarker(to location: CGPoint, on map: MLNMapView) -> Marker? {
            markers.min(by: {
                let a = map.convert(CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude), toPointTo: map)
                let b = map.convert(CLLocationCoordinate2D(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude), toPointTo: map)
                return hypot(a.x - location.x, a.y - location.y) < hypot(b.x - location.x, b.y - location.y)
            }).flatMap { marker in
                let p = map.convert(CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude), toPointTo: map)
                return hypot(p.x - location.x, p.y - location.y) < 36 ? marker : nil
            }
        }

        @objc func handleMarkerDrag(_ gesture: UILongPressGestureRecognizer) {
            guard let map else { return }
            switch gesture.state {
            case .began:
                draggedMarkerID = nearestMarker(to: gesture.location(in: map), on: map)?.id
            case .ended:
                if let id = draggedMarkerID {
                    let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
                    onMarkerMove(id, GeoPoint(c.latitude, c.longitude))
                }
                draggedMarkerID = nil
            case .cancelled, .failed:
                draggedMarkerID = nil
            default: break
            }
        }

        // A fixed Web Mercator tile grid (z=13). Coverage is computed from the
        // actual saved OSM extraction circles, never inferred from the basemap.
        private var gridShapes: [MLNAnnotation] = []
        private var gridVisible = false
        private var gridRegions: [OSMDownloadedRegion] = []
        private var gridRevision = -1
        private var lastGridBounds: String = ""
        private let gridZoom = 13

        func updateDownloadGrid(view: MLNMapView, visible: Bool, regions: [OSMDownloadedRegion], revision: Int) {
            let changed = gridVisible != visible || gridRevision != revision
            gridVisible = visible
            gridRegions = regions
            gridRevision = revision
            if changed { lastGridBounds = "" }
            rebuildDownloadGrid(view: view)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            rebuildDownloadGrid(view: mapView)

        }

        private func rebuildDownloadGrid(view: MLNMapView) {
            guard gridVisible else {
                if !gridShapes.isEmpty { view.removeAnnotations(gridShapes); gridShapes = [] }
                lastGridBounds = ""
                return
            }
            let bounds = view.visibleCoordinateBounds
            let n = Double(1 << gridZoom)
            func tileX(_ lon: Double) -> Int {
                Int(floor((min(179.999999, max(-180, lon)) + 180) / 360 * n))
            }
            func tileY(_ lat: Double) -> Int {
                let rad = min(85.0511, max(-85.0511, lat)) * .pi / 180
                return Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n))
            }
            let west = max(0, min(Int(n)-1, tileX(bounds.sw.longitude)))
            let east = max(0, min(Int(n)-1, tileX(bounds.ne.longitude)))
            let north = max(0, min(Int(n)-1, tileY(bounds.ne.latitude)))
            let south = max(0, min(Int(n)-1, tileY(bounds.sw.latitude)))
            let signature = "\(west):\(east):\(north):\(south):\(gridRevision)"
            guard signature != lastGridBounds else { return }
            lastGridBounds = signature
            if !gridShapes.isEmpty { view.removeAnnotations(gridShapes); gridShapes = [] }
            guard east >= west, south >= north, (east-west+1)*(south-north+1) <= 350 else { return }
            func longitude(_ x: Int) -> Double { Double(x) / n * 360 - 180 }
            func latitude(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi }
            var shapes: [MLNAnnotation] = []
            for y in north...south {
                for x in west...east {
                    let top = latitude(y), bottom = latitude(y+1)
                    let left = longitude(x), right = longitude(x+1)
                    let midLat = (top + bottom) / 2, midLon = (left + right) / 2
                    let covered = gridRegions.contains { region in
                        let latMeters = (midLat-region.latitude) * 111_195
                        let lonMeters = (midLon-region.longitude) * 111_195 * cos(midLat * .pi / 180)
                        return latMeters*latMeters + lonMeters*lonMeters <= Double(region.radiusMeters*region.radiusMeters)
                    }
                    var coords = [CLLocationCoordinate2D(latitude: top, longitude: left),
                                  CLLocationCoordinate2D(latitude: top, longitude: right),
                                  CLLocationCoordinate2D(latitude: bottom, longitude: right),
                                  CLLocationCoordinate2D(latitude: bottom, longitude: left),
                                  CLLocationCoordinate2D(latitude: top, longitude: left)]
                    let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                    line.title = covered ? "GRID_DOWNLOADED" : "GRID_MISSING"
                    shapes.append(line)
                }
            }
            gridShapes = shapes
            if !shapes.isEmpty { view.addAnnotations(shapes) }
        }

        private var osmRevision = -1
        private var osmShapes: [MLNAnnotation] = []
        func updateOSMLines(view: MLNMapView, lines: [OSMOfflineLine], revision: Int) {
            guard revision != osmRevision else { return }
            if !osmShapes.isEmpty { view.removeAnnotations(osmShapes) }
            var updated: [MLNAnnotation] = []
            for line in lines.prefix(4_000) {
                guard line.points.count >= 2 else { continue }
                var coords = TrackRendering.simplified(line.points, toleranceMeters: 2, maxPoints: 1200)
                    .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                guard coords.count >= 2 else { continue }
                let polyline = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                polyline.title = "OSM: \(line.kind)"
                updated.append(polyline)
            }
            osmShapes = updated
            osmRevision = revision
            if !updated.isEmpty { view.addAnnotations(updated) }
        }

        private var lastRevision = -1
        private var lastStyle: MLNStyle?
        private var latestFiles: [URL] = []
        private var staticShapes: [MLNAnnotation] = []
        private var gpsShape: MLNPointAnnotation?
        private var staticSignature: String?
        private var centeredOnGPS = false

        func apply(view: MLNMapView, files: [URL], revision: Int) {
            latestFiles = files
            if revision != lastRevision || lastStyle !== view.style {
                lastRevision = revision
                if let style = view.style { configure(style: style, files: files); lastStyle = style }
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            configure(style: style, files: latestFiles)
            lastStyle = style
            // A style switch can invalidate cached annotation images. Reinsert the
            // marker annotations and force their symbols to be requested again.
            let markerAnnotations = staticShapes.compactMap { $0 as? MLNPointAnnotation }
            if !markerAnnotations.isEmpty {
                mapView.removeAnnotations(markerAnnotations)
                mapView.addAnnotations(markerAnnotations)
            }
            if let gpsShape {
                mapView.removeAnnotation(gpsShape)
                mapView.addAnnotation(gpsShape)
            }

        }

        private func configure(style: MLNStyle, files: [URL]) {
            // Remove only layers created here; preserve any other application layers.
            for index in 0..<max(files.count, 32) {
                let id = "hunt-raster-\(index)"
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            for (index, file) in files.enumerated() {
                guard file.isFileURL, file.pathExtension.lowercased() == "mbtiles",
                      FileManager.default.fileExists(atPath: file.path) else { continue }
                let id = "hunt-raster-\(index)"
                // MapLibre Native's local MBTiles protocol reads directly from SQLite on disk.
                guard let url = URL(string: "mbtiles://\(file.path)") else { continue }
                let source = MLNRasterTileSource(identifier: id, configurationURL: url, tileSize: 256)
                style.addSource(source)
                style.addLayer(MLNRasterStyleLayer(identifier: id, source: source))
            }
        }

        func updateAnnotations(view: MLNMapView, zones: [GeoZone], markers: [Marker], position: GeoPoint?, heading: Double?, track: Track?) {
            // GPS updates must not rebuild routes, markers and boundaries.
            // The signature uses stable identifiers and a compact content fingerprint.
            let signature = staticContentSignature(zones: zones, markers: markers, track: track)
            if signature != staticSignature {
                if !staticShapes.isEmpty { view.removeAnnotations(staticShapes) }
                var updated: [MLNAnnotation] = []
            for zone in zones {
                for polygon in zone.polygons {
                    for ring in polygon.rings where ring.count >= 3 {
                        var coordinates = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                        line.title = zone.verified ? "Граница: \(zone.name)" : "НЕ ПРОВЕРЕНО: \(zone.name)"
                        updated.append(line)
                    }
                }
            }
            if let track, track.fixes.count > 1 {
                var segment: [CLLocationCoordinate2D] = []
                func appendSegment() {
                    guard segment.count > 1 else { return }
                    var coordinates = TrackRendering.simplified(segment.map { GeoPoint($0.latitude, $0.longitude) }, toleranceMeters: 3, maxPoints: 2500)
                        .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                    line.title = "Записанный маршрут"
                    updated.append(line)
                }
                for fix in track.fixes {
                    if fix.startsNewSegment == true { appendSegment(); segment.removeAll() }
                    segment.append(CLLocationCoordinate2D(latitude: fix.point.latitude, longitude: fix.point.longitude))
                }
                appendSegment()
            }
            // Native MapLibre annotations survive zoom changes and stay interactive.
            for marker in markers {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
                annotation.title = "HUNT_MARKER_\(marker.id.uuidString)"
                updated.append(annotation)
            }
                staticShapes = updated
                staticSignature = signature
                if !updated.isEmpty { view.addAnnotations(updated) }
            }
            let title = "HUNT_GPS_ARROW_\(Int((heading ?? 0).rounded()))"
            if let position {
                let coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                if let gpsShape {
                    let old = gpsShape.coordinate
                    if old.latitude != coordinate.latitude || old.longitude != coordinate.longitude || gpsShape.title != title {
                        view.removeAnnotation(gpsShape)
                        gpsShape.coordinate = coordinate
                        gpsShape.title = title
                        view.addAnnotation(gpsShape)
                    }
                } else {
                    let gps = MLNPointAnnotation()
                    gps.title = title
                    gps.coordinate = coordinate
                    gpsShape = gps
                    view.addAnnotation(gps)
                }
                if !centeredOnGPS { view.setCenter(coordinate, animated: false); centeredOnGPS = true }
            } else if let gpsShape {
                view.removeAnnotation(gpsShape)
                self.gpsShape = nil
            }
        }

        private func staticContentSignature(zones: [GeoZone], markers: [Marker], track: Track?) -> String {
            // Hash the data relevant to drawing, rather than comparing only array counts.
            var hasher = Hasher()
            hasher.combine(zones.count)
            for zone in zones {
                hasher.combine(zone.name)
                hasher.combine(zone.verified)
                for polygon in zone.polygons {
                    for ring in polygon.rings {
                        hasher.combine(ring.count)
                        for point in ring { hasher.combine(point.latitude); hasher.combine(point.longitude) }
                    }
                }
            }
            hasher.combine(markers.count)
            for marker in markers {
                hasher.combine(marker.id)
                hasher.combine(marker.title)
                hasher.combine(marker.symbol)
                hasher.combine(marker.colorHex)
                hasher.combine(marker.coordinate.latitude)
                hasher.combine(marker.coordinate.longitude)
            }
            if let track {
                hasher.combine(track.fixes.count)
                // The active track is append-only during recording. Include the last fix
                // so adding a point invalidates only the route drawing.
                if let last = track.fixes.last {
                    hasher.combine(last.point.latitude)
                    hasher.combine(last.point.longitude)
                    hasher.combine(last.startsNewSegment)
                }
                if let first = track.fixes.first {
                    hasher.combine(first.point.latitude)
                    hasher.combine(first.point.longitude)
                }
            }
            return String(hasher.finalize())
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let title = annotation.title ?? nil,
                  title.hasPrefix("HUNT_MARKER_"),
                  let id = UUID(uuidString: String(title.dropFirst("HUNT_MARKER_".count))) else { return }
            onMarkerSelect(id)
        }

        // Directional position symbol. Course is supplied by Core Location when moving;
        // the arrow is not falsely rotated from compass noise while stationary.
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let title = annotation.title ?? nil else { return nil }
            if title.hasPrefix("HUNT_MARKER_"), let id = UUID(uuidString: String(title.dropFirst("HUNT_MARKER_".count))),
               let marker = markers.first(where: { $0.id == id }) {
                let symbol = marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind)
                let hex = marker.colorHex ?? "#FF9F0A"
                let key = "marker-\(id.uuidString)-\(symbol)-\(hex)"
                if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: key) { return existing }
                let size = CGSize(width: 48, height: 48)
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    let rect = CGRect(x: 4, y: 4, width: 40, height: 40)
                    UIColor.white.setFill()
                    UIBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill()
                    UIColor(hex: hex).setFill()
                    UIBezierPath(ovalIn: rect).fill()
                    let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
                    if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                        glyph.draw(in: CGRect(x: 13, y: 13, width: 22, height: 22))
                    }
                }
                return MLNAnnotationImage(image: image, reuseIdentifier: key)
            }
            guard title.hasPrefix("HUNT_GPS_ARROW_") else { return nil }
            let heading = Double(title.replacingOccurrences(of: "HUNT_GPS_ARROW_", with: "")) ?? 0
            let bucket = Int((heading / 5).rounded()) * 5
            let key = "hunt-position-arrow-\(bucket)"
            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: key) { return existing }
            let size = CGSize(width: 44, height: 44)
            let image = UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                cg.translateBy(x: 22, y: 22)
                cg.rotate(by: CGFloat(bucket) * .pi / 180)
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 0, y: -19))
                arrow.addLine(to: CGPoint(x: 13, y: 14))
                arrow.addLine(to: CGPoint(x: 0, y: 8))
                arrow.addLine(to: CGPoint(x: -13, y: 14))
                arrow.close()
                UIColor.white.setStroke(); arrow.lineWidth = 4; arrow.lineJoinStyle = .round; arrow.stroke()
                UIColor.systemBlue.setFill(); arrow.fill()
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: key)
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat { 0.95 }
        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation.title == "GRID_DOWNLOADED" { return UIColor.systemGreen.withAlphaComponent(0.85) }
            if annotation.title == "GRID_MISSING" { return UIColor.lightGray.withAlphaComponent(0.55) }
            if annotation.title == "Записанный маршрут" { return .systemGreen }
            return annotation.title?.hasPrefix("НЕ ПРОВЕРЕНО") == true ? .systemYellow : .systemOrange
        }
        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            annotation.title?.hasPrefix("GRID_") == true ? 1.2 : (annotation.title == "Записанный маршрут" ? 4 : 3)
        }
    }
}

private enum OfflineMapStyle {
    static let url: URL = {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("hunt-map-offline-v1.style.json")
        // Explicitly empty sources means rendering a blank map when no offline package is present.
        // Never substitute an internet basemap.
        let json = """
        {"version":8,"name":"HUNT MAP KZ strict offline","sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#102332"}}]}
        """
        do { try Data(json.utf8).write(to: destination, options: [.atomic]) }
        catch { assertionFailure("Could not create offline style: \(error)") }
        return destination
    }()
}
