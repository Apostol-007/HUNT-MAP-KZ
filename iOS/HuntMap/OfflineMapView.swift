import SwiftUI
import MapLibre
import HuntCore

/// MapLibre receives only a locally generated, source-free style and file-backed MBTiles.
/// No HTTP style, glyph, sprite or tile endpoint is configured by this view.
struct OfflineMapView: UIViewRepresentable {
    @AppStorage("hunt.map.style") private var mapStyle = (MapTilerConfiguration.isConfigured ? MapBasemap.satellite.rawValue : MapBasemap.outdoors.rawValue)
    private var selectedStyle: URL {
        (MapBasemap(rawValue: mapStyle) ?? .bright).styleURL(apiKey: MapTilerConfiguration.apiKey) ?? MapBasemap.bright.styleURL(apiKey: "")!
    }

    let zones: [GeoZone]
    let position: GeoPoint?
    let markers: [Marker]
    let track: Track?
    var navigationPath: [GeoPoint] = []
    let tileFiles: [URL]
    let tileRevision: Int
    let online: Bool
    @Binding var selectedZone: GeoZone?
    let weatherGrid: ForecastGrid?
    let weatherLayer: WeatherMapLayer
    var centerRequest: Int = 0
    var zoomCommand: Int = 0
    var focusCoordinate: GeoPoint? = nil
    var onMapTap: (GeoPoint) -> Void = { _ in }
    var onMarkerTap: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(selectedZone: $selectedZone) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = online ? selectedStyle : OfflineMapStyle.url
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        context.coordinator.zones = zones
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMarkerTap = onMarkerTap
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.require(toFail: longPress)
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.map = view
        context.coordinator.tilesReadyObserver = NotificationCenter.default.addObserver(
            forName: .huntMBTilesReady, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator, weak view] _ in
            guard let coordinator, let view, let style = view.style else { return }
            coordinator.refreshOfflineTiles(style: style)
        }
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
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMarkerTap = onMarkerTap
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
        context.coordinator.updateAnnotations(view: view, zones: zones, markers: markers, position: position, track: track, navigationPath: navigationPath,
                                              weatherGrid: weatherGrid, weatherLayer: weatherLayer)
        context.coordinator.applyCameraCommands(view: view, position: focusCoordinate ?? position,
                                                centerRequest: centerRequest, zoomCommand: zoomCommand)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var selectedZone: Binding<GeoZone?>
        var tilesReadyObserver: NSObjectProtocol?
        deinit {
            if let tilesReadyObserver { NotificationCenter.default.removeObserver(tilesReadyObserver) }
        }
        weak var map: MLNMapView?
        var zones: [GeoZone] = []
        var onMapTap: (GeoPoint) -> Void = { _ in }
        var onMarkerTap: (UUID) -> Void = { _ in }
        private var markerAnnotations: [ObjectIdentifier: UUID] = [:]
        private var markerAppearance: [ObjectIdentifier: Marker] = [:]
        private var markerSignatures: [UUID: String] = [:]
        private var stableMarkers: [UUID: MLNPointAnnotation] = [:]
        private var gpsAnnotation: MLNPointAnnotation?
        private var transientAnnotations: [MLNAnnotation] = []
        private var lastTransientKey: String?
        private var markerCoordinates: [(UUID, CLLocationCoordinate2D)] = []
        init(selectedZone: Binding<GeoZone?>) { self.selectedZone = selectedZone }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // MapLibre owns pan/pinch/double tap. Our single tap must not block them.
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Ignore taps on MapLibre controls; only canvas taps reach the handler.
            return touch.view is MLNMapView || touch.view?.isDescendant(of: map ?? UIView()) == true
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            let point = GeoPoint(coordinate.latitude, coordinate.longitude)
            if point.valid { onMapTap(point) }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map else { return }
            let screenPoint = recognizer.location(in: map)
            // MapLibre can also dispatch didSelect for markers. Only handle it once.
            if let nearby = markerCoordinates.first(where: { _, coordinate in
                let markerPoint = map.convert(coordinate, toPointTo: map)
                return hypot(markerPoint.x - screenPoint.x, markerPoint.y - screenPoint.y) <= 28
            }) {
                onMarkerTap(nearby.0)
                return
            }
            let coordinate = map.convert(screenPoint, toCoordinateFrom: map)
            let point = GeoPoint(coordinate.latitude, coordinate.longitude)
            guard point.valid else { return }
            onMapTap(point)
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            // Selection is handled by hit testing in handleTap; prevent a duplicate sheet.
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let marker = markerAppearance[ObjectIdentifier(annotation as AnyObject)] else { return nil }
            let symbol = marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind)
            let color = UIColor(hex: marker.colorHex ?? "#24DA66")
            let size = CGSize(width: 52, height: 52)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                let background = CGRect(x: 4, y: 4, width: 44, height: 44)
                color.setFill()
                UIBezierPath(roundedRect: background, cornerRadius: 13).fill()
                UIColor.white.withAlphaComponent(0.65).setStroke()
                let border = UIBezierPath(roundedRect: background.insetBy(dx: 1, dy: 1), cornerRadius: 12)
                border.lineWidth = 1.5
                border.stroke()
                let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
                    ?? UIImage(systemName: "mappin")
                glyph?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 13, y: 13, width: 26, height: 26))
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: "hunt-marker-\(marker.id.uuidString)-\(symbol)-\(marker.colorHex ?? "green")")
        }

        private var lastRevision = -1
        private var lastStyle: MLNStyle?
        private var latestFiles: [URL] = []
        private var centeredOnGPS = false
        private var appliedCenterRequest = 0
        private var appliedZoomCommand = 0

        func applyCameraCommands(view: MLNMapView, position: GeoPoint?, centerRequest: Int, zoomCommand: Int) {
            if centerRequest != appliedCenterRequest, let position {
                view.setCenter(CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude),
                               zoomLevel: max(view.zoomLevel, 13), animated: true)
                appliedCenterRequest = centerRequest
            }
            if zoomCommand != appliedZoomCommand {
                let delta = zoomCommand - appliedZoomCommand
                let nextZoom = max(2, min(20, view.zoomLevel + Double(delta)))
                view.setZoomLevel(nextZoom, animated: true)
                appliedZoomCommand = zoomCommand
            }
        }

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

        func refreshOfflineTiles(style: MLNStyle) {
            configure(style: style, files: latestFiles)
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
            // Raster MBTiles are served by the existing loopback-only tile service.
            // MapLibre cannot open arbitrary mbtiles:// files using a generic HTTP source.
            let server = LocalMBTilesServer.shared
            let registered = server.register(files)
            for (index, entry) in registered.enumerated() {
                let (key, _) = entry
                guard let template = server.tileTemplate(for: key) else { continue }
                let id = "hunt-raster-\(index)"
                let source = MLNRasterTileSource(identifier: id, tileURLTemplates: [template])
                style.addSource(source)
                style.addLayer(MLNRasterStyleLayer(identifier: id, source: source))
            }
        }

        func updateAnnotations(view: MLNMapView, zones: [GeoZone], markers: [Marker], position: GeoPoint?, track: Track?, navigationPath: [GeoPoint],
                               weatherGrid: ForecastGrid?, weatherLayer: WeatherMapLayer) {
            // Persistent MLNPointAnnotation identity is critical for tapping. Recreating
            // every marker on each GPS/SwiftUI update used to cancel selection gestures.
            let transientKey = String(describing: zones) + "|" + String(describing: track) + "|" + String(describing: navigationPath) + "|" + String(describing: weatherLayer) + "|" + String(describing: weatherGrid)
            if transientKey != lastTransientKey {
                if !transientAnnotations.isEmpty { view.removeAnnotations(transientAnnotations) }
                transientAnnotations.removeAll()
                lastTransientKey = transientKey
            }
            var updated: [MLNAnnotation] = []
            // Hold transient annotation building behind a change check; GPS is refreshed separately.
            if transientAnnotations.isEmpty && transientKey == lastTransientKey {
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
            if navigationPath.count >= 2 {
                var routeCoords = navigationPath.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let route = MLNPolyline(coordinates: &routeCoords, count: UInt(routeCoords.count))
                route.title = "NAV|HUNT"
                updated.append(route)
            }
            transientAnnotations = updated
            if !updated.isEmpty { view.addAnnotations(updated) }
            }
            let incoming = Set(markers.map(\.id))
            for (id, annotation) in stableMarkers where !incoming.contains(id) {
                view.removeAnnotation(annotation)
                stableMarkers.removeValue(forKey: id)
                markerAnnotations.removeValue(forKey: ObjectIdentifier(annotation))
                markerAppearance.removeValue(forKey: ObjectIdentifier(annotation))
                markerSignatures.removeValue(forKey: id)
            }
            markerCoordinates.removeAll(keepingCapacity: true)
            for marker in markers where marker.coordinate.valid {
                let signature = "\(marker.title)|\(marker.kind)|\(marker.symbol ?? "")|\(marker.colorHex ?? "")|\(marker.coordinate.latitude)|\(marker.coordinate.longitude)"
                let annotation: MLNPointAnnotation
                if let existing = stableMarkers[marker.id], markerSignatures[marker.id] == signature {
                    annotation = existing
                } else {
                    if let existing = stableMarkers.removeValue(forKey: marker.id) {
                        view.removeAnnotation(existing)
                        markerAnnotations.removeValue(forKey: ObjectIdentifier(existing))
                        markerAppearance.removeValue(forKey: ObjectIdentifier(existing))
                    }
                    let fresh = MLNPointAnnotation()
                    fresh.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
                    fresh.title = marker.title
                    annotation = fresh
                    stableMarkers[marker.id] = fresh
                    // Register appearance BEFORE addAnnotation so delegate imageFor receives it.
                    markerAnnotations[ObjectIdentifier(fresh)] = marker.id
                    markerAppearance[ObjectIdentifier(fresh)] = marker
                    view.addAnnotation(fresh)
                    markerSignatures[marker.id] = signature
                }
                markerCoordinates.append((marker.id, annotation.coordinate))
            }
            // Keep GPS independent from editable markers (never assign a marker UUID).
            if let position, position.valid {
                if let gpsAnnotation { view.removeAnnotation(gpsAnnotation) }
                let gps = MLNPointAnnotation()
                gps.title = "GPS · текущая позиция"
                gps.coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                gpsAnnotation = gps
                view.addAnnotation(gps)
                if !centeredOnGPS { view.setCenter(gps.coordinate, animated: false); centeredOnGPS = true }
            } else if let gpsAnnotation {
                view.removeAnnotation(gpsAnnotation)
                self.gpsAnnotation = nil
            }
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
            if annotation.title == "NAV|HUNT" { return .systemCyan }
            if annotation.title == "Записанный маршрут" { return .systemGreen }
            return annotation.title?.hasPrefix("НЕ ПРОВЕРЕНО") == true ? .systemYellow : .systemOrange
        }
        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            if annotation.title?.hasPrefix("WX-ISOBAR|") == true { return 1.8 }
            if annotation.title?.hasPrefix("WX-WIND|") == true { return 2.3 }
            if annotation.title == "NAV|HUNT" { return 5 }
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
