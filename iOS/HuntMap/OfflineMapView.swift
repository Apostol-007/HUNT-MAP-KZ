import SwiftUI
import MapLibre
import HuntCore

/// MapLibre receives only a locally generated, source-free style and file-backed MBTiles.
/// No HTTP style, glyph, sprite or tile endpoint is configured by this view.
struct OfflineMapView: UIViewRepresentable {
    @AppStorage("hunt.map.style") private var mapStyle = MapBasemap.bright.rawValue
    private var selectedStyle: URL {
        (MapBasemap(rawValue: mapStyle) ?? .bright).styleURL(apiKey: MapTilerConfiguration.apiKey) ?? MapBasemap.bright.styleURL(apiKey: "")!
    }

    let zones: [GeoZone]
    let position: GeoPoint?
    let markers: [Marker]
    let track: Track?
    let tileFiles: [URL]
    let tileRevision: Int
    let online: Bool
    @Binding var selectedZone: GeoZone?
    let weatherGrid: ForecastGrid?
    let weatherLayer: WeatherMapLayer

    func makeCoordinator() -> Coordinator { Coordinator(selectedZone: $selectedZone) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = online ? selectedStyle : OfflineMapStyle.url
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        context.coordinator.zones = zones
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.map = view
        view.setCenter(CLLocationCoordinate2D(latitude: 43.24, longitude: 76.91), zoomLevel: 11, animated: false)
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        let requestedOnline = online
        let targetStyle = requestedOnline ? selectedStyle : OfflineMapStyle.url
        if view.styleURL != targetStyle {
            view.styleURL = targetStyle
        }
        context.coordinator.zones = zones
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        // Diagnostic-only window geometry check. Read after UIKit finishes layout.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            let mapFrame = view.convert(view.bounds, to: window)
            let windowFrame = window.bounds
            let matches = abs(mapFrame.minX - windowFrame.minX) <= 1 &&
                          abs(mapFrame.minY - windowFrame.minY) <= 1 &&
                          abs(mapFrame.width - windowFrame.width) <= 1 &&
                          abs(mapFrame.height - windowFrame.height) <= 1
            UserDefaults.standard.set("\(Int(mapFrame.minX)),\(Int(mapFrame.minY)),\(Int(mapFrame.width))x\(Int(mapFrame.height))", forKey: "hunt.diag.mapFrame")
            UserDefaults.standard.set(matches, forKey: "hunt.diag.fullscreenMap")
        }
        context.coordinator.updateAnnotations(view: view, zones: zones, markers: markers, position: position, track: track,
                                              weatherGrid: weatherGrid, weatherLayer: weatherLayer)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var selectedZone: Binding<GeoZone?>
        weak var map: MLNMapView?
        var zones: [GeoZone] = []
        init(selectedZone: Binding<GeoZone?>) { self.selectedZone = selectedZone }
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            let position = GeoPoint(coordinate.latitude, coordinate.longitude)
            // Find the smallest enclosing boundary for overlapping territories.
            let matching = zones.filter { $0.contains(position) }
            if let zone = matching.first { selectedZone.wrappedValue = zone }
        }

        private var lastRevision = -1
        private var lastStyle: MLNStyle?
        private var latestFiles: [URL] = []
        private var shapes: [MLNAnnotation] = []
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
        }

        private func configure(style: MLNStyle, files: [URL]) {
            // Localize visible vector labels on every style load or style change.
            // Source data can omit name:ru; retain its original value rather than hide it.
            RussianMapLabels.apply(to: style)
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

        func updateAnnotations(view: MLNMapView, zones: [GeoZone], markers: [Marker], position: GeoPoint?, track: Track?,
                               weatherGrid: ForecastGrid?, weatherLayer: WeatherMapLayer) {
            if !shapes.isEmpty { view.removeAnnotations(shapes) }
            var updated: [MLNAnnotation] = []
            if weatherLayer != .none, let weatherGrid, weatherGrid.validated() {
                let w = weatherGrid.gridWidth, h = weatherGrid.gridHeight
                let samples = weatherGrid.points.map { point in
                    let value: Double?
                    switch weatherLayer {
                    case .wind: value = point.windSpeed
                    case .pressure: value = point.pressure
                    case .precipitation: value = point.precipitation
                    case .none: value = nil
                    }
                    return WeatherGeometry.Sample(latitude: point.latitude, longitude: point.longitude, value: value)
                }
                // Bilinearly interpolated subcells, only inside verified 4-corner model cells.
                let subdivisions = weatherLayer == .precipitation ? 4 : 3
                for cell in WeatherGeometry.shade(samples: samples, width: w, height: h, subdivisions: subdivisions) {
                    var coords = cell.corners.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let polygon = MLNPolygon(coordinates: &coords, count: UInt(coords.count))
                    polygon.title = "WX|\(weatherLayer.rawValue)|\(cell.value)"
                    updated.append(polygon)
                }
                if weatherLayer == .pressure {
                    let values = samples.compactMap { $0.value }
                    if let low = values.min(), let high = values.max() {
                        let first = Int(ceil(low / 5) * 5), last = Int(floor(high / 5) * 5)
                        if first <= last {
                            let levels = stride(from: first, through: last, by: 5).map(Double.init)
                            for segment in WeatherGeometry.isolines(samples: samples, width: w, height: h, levels: levels) {
                                var coords = [segment.a, segment.b].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                                let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                                line.title = "WX-ISOBAR|\(Int(segment.level))"
                                updated.append(line)
                            }
                        }
                    }
                } else if weatherLayer == .wind {
                    let spacing = min((weatherGrid.bounds.north-weatherGrid.bounds.south)/Double(max(1,h-1)),
                                      (weatherGrid.bounds.east-weatherGrid.bounds.west)/Double(max(1,w-1)))
                    for point in weatherGrid.points {
                        guard let angle = point.direction, let speed = point.windSpeed else { continue }
                        let segments = WeatherGeometry.windArrow(latitude: point.latitude, longitude: point.longitude,
                                                                fromDegrees: angle, speedKmh: speed, lengthDegrees: spacing * 0.30)
                        for segment in segments {
                            var coords = [segment.a, segment.b].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                            let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                            line.title = "WX-WIND|\(segment.level)"
                            updated.append(line)
                        }
                    }
                }
            }
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
                var coordinates = track.fixes.map { CLLocationCoordinate2D(latitude: $0.point.latitude, longitude: $0.point.longitude) }
                let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                line.title = "Записанный маршрут"
                updated.append(line)
            }
            for marker in markers {
                let point = MLNPointAnnotation()
                point.title = marker.title
                point.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
                updated.append(point)
            }
            if let position {
                let gps = MLNPointAnnotation()
                gps.title = "GPS · текущая позиция"
                gps.coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                updated.append(gps)
                if !centeredOnGPS { view.setCenter(gps.coordinate, animated: false); centeredOnGPS = true }
            }
            shapes = updated
            view.addAnnotations(updated)
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            annotation.title?.hasPrefix("WX|") == true ? 0.40 : 0.95
        }
        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            guard let title = annotation.title, title.hasPrefix("WX|") else { return .clear }
            let fields = title.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3, let value = Double(fields[2]) else { return .clear }
            switch String(fields[1]) {
            case "Ветер":
                return value < 15 ? .systemTeal : (value < 35 ? .systemYellow : .systemRed)
            case "Давление":
                return value < 1000 ? .systemBlue : (value < 1020 ? .systemGreen : .systemOrange)
            case "Осадки":
                return value < 0.1 ? .clear : (value < 2 ? .systemBlue : (value < 8 ? .systemPurple : .systemRed))
            default: return .clear
            }
        }
        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation.title?.hasPrefix("WX-ISOBAR|") == true { return .white }
            if annotation.title?.hasPrefix("WX-WIND|") == true { return .white }
            if annotation.title == "Записанный маршрут" { return .systemGreen }
            return annotation.title?.hasPrefix("НЕ ПРОВЕРЕНО") == true ? .systemYellow : .systemOrange
        }
        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            if annotation.title?.hasPrefix("WX-ISOBAR|") == true { return 1.8 }
            if annotation.title?.hasPrefix("WX-WIND|") == true { return 2.3 }
            return annotation.title == "Записанный маршрут" ? 4 : 3
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

/// MapLibre's style labels must be localized separately from the iOS interface.
/// A satellite raster may contain burned-in text that cannot be rewritten.
private enum RussianMapLabels {
    static func apply(to style: MLNStyle) {
        for case let symbol as MLNSymbolStyleLayer in style.layers {
            // Do not replace motorway numbers, route shields or other symbol-only layers.
            let identifier = symbol.identifier.lowercased()
            guard identifier.contains("label") || identifier.contains("name") ||
                  identifier.contains("place") || identifier.contains("country") ||
                  identifier.contains("settlement") || identifier.contains("road") ||
                  identifier.contains("street") || identifier.contains("poi") else { continue }
            guard symbol.text != nil else { continue }
            symbol.text = NSExpression(
                format: "mgl_coalesce({%K, %K, %K})",
                "name:ru", "name", "name:en"
            )
        }
    }
}
