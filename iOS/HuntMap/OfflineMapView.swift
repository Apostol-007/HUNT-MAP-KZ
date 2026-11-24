import SwiftUI
import MapLibre
import HuntCore

/// MapLibre receives only a locally generated, source-free style and file-backed MBTiles.
/// No HTTP style, glyph, sprite or tile endpoint is configured by this view.
struct OfflineMapView: UIViewRepresentable {
    @AppStorage("hunt.map.style") private var mapStyle = MapBasemap.protomaps.rawValue
    private var selectedStyle: URL {
        (MapBasemap(rawValue: mapStyle) ?? .outdoors).styleURL(apiKey: MapTilerConfiguration.apiKey) ?? MapBasemap.outdoors.styleURL(apiKey: "")!
    }

    let zones: [GeoZone]
    let position: GeoPoint?
    let markers: [Marker]
    let track: Track?
    var navigationPath: [GeoPoint] = []
    var replayPosition: GeoPoint? = nil
    let tileFiles: [URL]
    let tileRevision: Int
    var offlineRoadLines: [OfflineRoadLine] = []
    var offlineRoadRevision = 0
    var routingGeneration = 0
    var nativeOfflineStyleURL: URL? = nil
    var protomapsOnlineStyleURL: URL? = nil
    var protomapsOfflineStyleURL: URL? = nil
    var protomapsHybridStyleURL: URL? = nil
    let online: Bool
    var active = true
    var zonesRevision = 0
    @Binding var selectedZone: GeoZone?
    let weatherGrid: ForecastGrid?
    let weatherLayer: WeatherMapLayer
    var centerRequest: Int = 0
    var zoomCommand: Int = 0
    var overviewCommand: Int = 0
    var focusCoordinate: GeoPoint? = nil
    var onMapTap: (GeoPoint) -> Void = { _ in }
    var onMarkerTap: (UUID) -> Void = { _ in }
    var gridEnabled = false
    var gridStep = 0.1
    var selectedGridCells: Set<String> = []
    var onGridTap: (String) -> Void = { _ in }
    var onViewportChanged: ([Double]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(selectedZone: $selectedZone) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = UIColor(red: 0.06, green: 0.12, blue: 0.16, alpha: 1)
        container.clipsToBounds = true
        let styleURL = online ? (mapStyle == MapBasemap.protomaps.rawValue ? (protomapsOfflineStyleURL ?? protomapsOnlineStyleURL ?? selectedStyle) : selectedStyle)
                              : (mapStyle == MapBasemap.hybrid.rawValue && !tileFiles.isEmpty ? (protomapsHybridStyleURL ?? protomapsOfflineStyleURL ?? OfflineMapStyle.url) : (protomapsOfflineStyleURL ?? OfflineMapStyle.url))
        UserDefaults.standard.set("native-map-init", forKey: "hunt.diag.mapStage")
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        UserDefaults.standard.set("native-map-created", forKey: "hunt.diag.mapStage")
        context.coordinator.requestedStyleURL = styleURL
        // Critical: MapLibre is the bottom sibling. Weather overlays are separate
        // siblings and cannot disappear behind GL subviews when the style reloads.
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view.showsScale = true
        view.scaleBarUsesMetricSystem = true
        view.scaleBarShouldShowDarkStyles = true
        view.scaleBarPosition = .bottomLeft
        view.scaleBarMargins = CGPoint(x: 16, y: 108)
        view.delegate = context.coordinator
        context.coordinator.zones = zones
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMarkerTap = onMarkerTap
        context.coordinator.gridEnabled = gridEnabled
        context.coordinator.gridStep = gridStep
        context.coordinator.selectedGridCells = selectedGridCells
        context.coordinator.onGridTap = onGridTap
        context.coordinator.onViewportChanged = onViewportChanged
        context.coordinator.isOffline = !online
        context.coordinator.hybridOffline = !online && mapStyle == MapBasemap.hybrid.rawValue
        context.coordinator.routingGeneration = routingGeneration
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
        context.coordinator.fieldOverlay = WeatherFieldOverlay(mapView: view, hostView: container)
        context.coordinator.fieldOverlay?.configure(grid: weatherGrid, layer: weatherLayer)
        context.coordinator.windOverlay = WindParticlesOverlay(mapView: view, hostView: container)
        context.coordinator.windOverlay?.configure(grid: weatherGrid, enabled: weatherLayer == .wind)
        context.coordinator.tilesReadyObserver = NotificationCenter.default.addObserver(
            forName: .huntMBTilesReady, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator, weak view] _ in
            guard let coordinator, let view, let style = view.style else { return }
            coordinator.refreshOfflineTiles(style: style)
        }
        view.setCenter(CLLocationCoordinate2D(latitude: 43.24, longitude: 76.91), zoomLevel: 11, animated: false)
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        context.coordinator.renderGrid(in: view)
        UserDefaults.standard.set("native-map-mounted", forKey: "hunt.diag.mapStage")
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak view] in
            if let coordinator, let view { coordinator.reportViewport(in: view) }
        }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let view = context.coordinator.map else { return }
        view.isHidden = !active
        guard active else {
            context.coordinator.windOverlay?.configure(grid: nil, enabled: false)
            context.coordinator.fieldOverlay?.configure(grid: nil, layer: .none)
            return
        }
        let requestedOnline = online
        let targetStyle = requestedOnline ? (mapStyle == MapBasemap.protomaps.rawValue ? (protomapsOfflineStyleURL ?? protomapsOnlineStyleURL ?? selectedStyle) : selectedStyle)
                                          : (mapStyle == MapBasemap.hybrid.rawValue && !tileFiles.isEmpty ? (protomapsHybridStyleURL ?? protomapsOfflineStyleURL ?? OfflineMapStyle.url) : (protomapsOfflineStyleURL ?? OfflineMapStyle.url))
        if context.coordinator.requestedStyleURL != targetStyle {
            context.coordinator.requestedStyleURL = targetStyle
            context.coordinator.invalidateRasterLayout()
            view.styleURL = targetStyle
        }
        context.coordinator.zones = zones
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMarkerTap = onMarkerTap
        let changedGrid = context.coordinator.gridEnabled != gridEnabled ||
                          context.coordinator.gridStep != gridStep ||
                          context.coordinator.selectedGridCells != selectedGridCells
        context.coordinator.gridEnabled = gridEnabled
        context.coordinator.gridStep = gridStep
        context.coordinator.selectedGridCells = selectedGridCells
        context.coordinator.onGridTap = onGridTap
        context.coordinator.onViewportChanged = onViewportChanged
        let modeChanged = context.coordinator.isOffline != !online
        if modeChanged { context.coordinator.invalidateRasterLayout() }
        let needsRoadRefresh = modeChanged ||
                               context.coordinator.routingGeneration != routingGeneration
        context.coordinator.isOffline = !online
        let nextHybrid = !online && mapStyle == MapBasemap.hybrid.rawValue
        if context.coordinator.hybridOffline != nextHybrid {
            context.coordinator.hybridOffline = nextHybrid
            context.coordinator.invalidateRasterLayout()
        }
        context.coordinator.routingGeneration = routingGeneration
        if needsRoadRefresh {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak view] in
                if let coordinator, let view { coordinator.reportViewport(in: view) }
            }
        }
        if changedGrid { context.coordinator.renderGrid(in: view) }
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        context.coordinator.fieldOverlay?.configure(grid: weatherGrid, layer: weatherLayer)
        context.coordinator.windOverlay?.configure(grid: weatherGrid, enabled: weatherLayer == .wind)
        // Native MapLibre may add/reorder its own GL subviews after style reload.
        context.coordinator.fieldOverlay?.syncMapGeometry()
        context.coordinator.windOverlay?.syncMapGeometry()
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
        context.coordinator.updateAnnotations(view: view, zones: zones, zonesRevision: zonesRevision, markers: markers, position: position, track: track, navigationPath: navigationPath, replayPosition: replayPosition,
                                              weatherGrid: weatherGrid, weatherLayer: weatherLayer,
                                              offlineRoadLines: online ? [] : offlineRoadLines, offlineRoadRevision: offlineRoadRevision)
        context.coordinator.applyCameraCommands(view: view, position: focusCoordinate ?? position,
                                                centerRequest: centerRequest, zoomCommand: zoomCommand)
        context.coordinator.fitCountryIfNeeded(view: view, command: overviewCommand)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.windOverlay?.configure(grid: nil, enabled: false)
        coordinator.fieldOverlay?.configure(grid: nil, layer: .none)
        coordinator.map?.delegate = nil
        coordinator.cancelPendingUpdates()
        coordinator.map = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var selectedZone: Binding<GeoZone?>
        var tilesReadyObserver: NSObjectProtocol?
        deinit {
            if let tilesReadyObserver { NotificationCenter.default.removeObserver(tilesReadyObserver) }
        }
        weak var map: MLNMapView?
        var requestedStyleURL: URL?
        private var viewportWork: DispatchWorkItem?
        func cancelPendingUpdates() {
            rasterRequest += 1
            zoneTask?.cancel()
            zoneWorker?.cancel()
            viewportWork?.cancel()
            viewportWork = nil
            if let observer = tilesReadyObserver { NotificationCenter.default.removeObserver(observer); tilesReadyObserver = nil }
        }
        var windOverlay: WindParticlesOverlay?
        var fieldOverlay: WeatherFieldOverlay?
        var zones: [GeoZone] = []
        var onMapTap: (GeoPoint) -> Void = { _ in }
        var onMarkerTap: (UUID) -> Void = { _ in }
        var gridEnabled = false
        var gridStep = 0.1
        var selectedGridCells: Set<String> = []
        var onGridTap: (String) -> Void = { _ in }
        var onViewportChanged: ([Double]) -> Void = { _ in }
        var isOffline = false
        var hybridOffline = false
        func invalidateRasterLayout() { lastRevision = -1; rasterRequest += 1 }
        var routingGeneration = 0
        private var gridAnnotations: [MLNShape] = []
        private var markerAnnotations: [ObjectIdentifier: UUID] = [:]
        private var markerAppearance: [ObjectIdentifier: Marker] = [:]
        private var markerSignatures: [UUID: String] = [:]
        private var stableMarkers: [UUID: MLNPointAnnotation] = [:]
        private var gpsAnnotation: MLNPointAnnotation?
        private var transientAnnotations: [MLNAnnotation] = []
        private var lastTransientKey: Int?
        private var zoneAnnotations: [MLNAnnotation] = []
        private var zoneTask: Task<Void, Never>?
        private var zoneWorker: Task<[BoundaryLine], Never>?
        private struct BoundaryLine: Sendable {
            let title: String
            let points: [GeoPoint]
        }
        private var lastZonesRevision: Int?
        private var lastZonesVisible = false
        private var replayAnnotation: MLNPointAnnotation?
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
            if gridEnabled {
                let coordinate = map.convert(screenPoint, toCoordinateFrom: map)
                if let cell = OfflineGridCell(latitude: coordinate.latitude, longitude: coordinate.longitude, step: gridStep) {
                    onGridTap(cell.id)
                }
                return
            }
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
        private weak var lastStyle: MLNStyle?
        private var latestFiles: [URL] = []
        private var centeredOnGPS = false
        private var appliedCenterRequest = 0
        private var appliedZoomCommand = 0
        private var appliedOverviewCommand = 0
        func fitCountryIfNeeded(view: MLNMapView, command: Int) {
            guard command != appliedOverviewCommand else { return }
            appliedOverviewCommand = command
            view.setCenter(CLLocationCoordinate2D(latitude: 48.6, longitude: 67.0),
                           zoomLevel: 3.25, animated: true)
        }

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

        func mapView(_ mapView: MLNMapView, didFailLoadingMapWithError error: Error) {
            AppDiagnosticLog.shared.recordError(subsystem: "Карта",
                operation: "MapLibre загрузка стиля или карты", error: error)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            UserDefaults.standard.set("style-loaded", forKey: "hunt.diag.mapStage")
            configure(style: style, files: latestFiles)
            lastStyle = style
            fieldOverlay?.syncMapGeometry()
            windOverlay?.syncMapGeometry()
        }

        func refreshOfflineTiles(style: MLNStyle) {
            configure(style: style, files: latestFiles)
        }

        private var rasterRequest = 0
        private var rasterLayerCount = 0
        private weak var rasterStyle: MLNStyle?

        private func configure(style: MLNStyle, files: [URL]) {
            rasterRequest += 1
            let request = rasterRequest
            if rasterStyle !== style {
                rasterStyle = style
                rasterLayerCount = 0
                // Keep the provider's original expressions. Rewriting arbitrary symbol
                // layers through NSExpression can raise an Objective-C exception.
                // The generated Protomaps style already contains Russian-first labels.
            }
            let hasProtomaps = style.source(withIdentifier: "protomaps_0") != nil
            if (hasProtomaps && !hybridOffline) || files.isEmpty {
                removeRasterLayers(from: style)
                return
            }
            LocalMBTilesServer.shared.prepareTemplates(files, revision: lastRevision) { [weak self, weak style] templates in
                guard let self, let style, self.rasterRequest == request,
                      self.map?.style === style else { return }
                self.removeRasterLayers(from: style)
                for (index, template) in templates.enumerated() {
                    let id = "hunt-raster-\(index)"
                    let source = MLNRasterTileSource(identifier: id, tileURLTemplates: [template])
                    style.addSource(source)
                    let raster = MLNRasterStyleLayer(identifier: id, source: source)
                    if hasProtomaps && self.hybridOffline,
                       let vector = style.layer(withIdentifier: "highways_0") {
                        style.insertLayer(raster, below: vector)
                    } else {
                        style.addLayer(raster)
                    }
                }
                self.rasterLayerCount = templates.count
            }
        }

        private func removeRasterLayers(from style: MLNStyle) {
            for index in 0..<rasterLayerCount {
                let id = "hunt-raster-\(index)"
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            rasterLayerCount = 0
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            fieldOverlay?.syncMapGeometry()
            windOverlay?.syncMapGeometry()
            fieldOverlay?.setNeedsDisplay()
            if gridEnabled { renderGrid(in: mapView) }
            reportViewport(in: mapView)
        }

        func reportViewport(in view: MLNMapView) {
            let area = view.visibleCoordinateBounds
            let bounds = [min(area.sw.longitude, area.ne.longitude),
                          min(area.sw.latitude, area.ne.latitude),
                          max(area.sw.longitude, area.ne.longitude),
                          max(area.sw.latitude, area.ne.latitude)]
            guard bounds.allSatisfy({ $0.isFinite }) else { return }
            viewportWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.map != nil else { return }
                self.onViewportChanged(bounds)
            }
            viewportWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func renderGrid(in view: MLNMapView) {
            if !gridAnnotations.isEmpty {
                view.removeAnnotations(gridAnnotations)
                gridAnnotations.removeAll()
            }
            guard gridEnabled, (0.01...1).contains(gridStep) else { return }
            let area = view.visibleCoordinateBounds
            let south = max(-90, min(area.sw.latitude, area.ne.latitude))
            let north = min(90, max(area.sw.latitude, area.ne.latitude))
            let west = max(-180, min(area.sw.longitude, area.ne.longitude))
            let east = min(180, max(area.sw.longitude, area.ne.longitude))
            guard south.isFinite, north.isFinite, west.isFinite, east.isFinite else { return }
            let minX = Int(floor(west / gridStep))
            let maxX = Int(floor(east / gridStep))
            let minY = Int(floor(south / gridStep))
            let maxY = Int(floor(north / gridStep))
            guard maxX >= minX, maxY >= minY,
                  (maxX - minX + 1) * (maxY - minY + 1) <= 144 else { return }
            var shapes: [MLNShape] = []
            for x in minX...maxX {
                for y in minY...maxY {
                    let key = "\(x)_\(y)"
                    let a = Double(x) * gridStep, b = Double(y) * gridStep
                    var coords = [
                        CLLocationCoordinate2D(latitude: b, longitude: a),
                        CLLocationCoordinate2D(latitude: b, longitude: a + gridStep),
                        CLLocationCoordinate2D(latitude: b + gridStep, longitude: a + gridStep),
                        CLLocationCoordinate2D(latitude: b + gridStep, longitude: a),
                        CLLocationCoordinate2D(latitude: b, longitude: a)
                    ]
                    let boundary = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                    boundary.title = selectedGridCells.contains(key) ? "GRID|SELECTED" : "GRID|AVAILABLE"
                    shapes.append(boundary)
                }
            }
            gridAnnotations = shapes
            view.addAnnotations(shapes)
        }

        private func prepareZones(_ zones: [GeoZone], in view: MLNMapView) {
            zoneTask?.cancel()
            zoneWorker?.cancel()
            if !zoneAnnotations.isEmpty { view.removeAnnotations(zoneAnnotations) }
            zoneAnnotations.removeAll()
            let previous = zoneWorker
            let worker = Task.detached(priority: .utility) {
                _ = await previous?.value
                var lines: [BoundaryLine] = []
                for zone in zones {
                    let title = zone.verified ? "Граница: \(zone.name)" : "НЕ ПРОВЕРЕНО: \(zone.name)"
                    for polygon in zone.polygons {
                        for ring in polygon.rings where ring.count >= 3 {
                            guard !Task.isCancelled else { return [BoundaryLine]() }
                            // Split long rings into overlapping pieces; retain every vertex.
                            var start = 0
                            while start < ring.count - 1 {
                                guard !Task.isCancelled else { return [BoundaryLine]() }
                                let end = min(start + 1024, ring.count - 1)
                                lines.append(BoundaryLine(title: title, points: Array(ring[start...end])))
                                start = end
                            }
                            if ring.first != ring.last, let first = ring.first, let last = ring.last {
                                lines.append(BoundaryLine(title: title, points: [last, first]))
                            }
                        }
                    }
                }
                return lines
            }
            zoneWorker = worker
            zoneTask = Task { @MainActor [weak self, weak view] in
                let lines = await worker.value
                guard !Task.isCancelled else { return }
                var batch: [MLNAnnotation] = []
                var vertices = 0
                for line in lines {
                    guard !Task.isCancelled, let self, let view, self.map === view else { return }
                    var coordinates = line.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let shape = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                    shape.title = line.title
                    batch.append(shape)
                    vertices += coordinates.count
                    if vertices >= 2048 || batch.count >= 32 {
                        view.addAnnotations(batch)
                        self.zoneAnnotations.append(contentsOf: batch)
                        batch.removeAll(keepingCapacity: true)
                        vertices = 0
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                }
                if !Task.isCancelled, let self, let view, self.map === view, !batch.isEmpty {
                    view.addAnnotations(batch)
                    self.zoneAnnotations.append(contentsOf: batch)
                }
            }
        }

        func updateAnnotations(view: MLNMapView, zones: [GeoZone], zonesRevision: Int, markers: [Marker], position: GeoPoint?, track: Track?, navigationPath: [GeoPoint], replayPosition: GeoPoint?,
                               weatherGrid: ForecastGrid?, weatherLayer: WeatherMapLayer,
                               offlineRoadLines: [OfflineRoadLine], offlineRoadRevision: Int) {
            // Persistent MLNPointAnnotation identity is critical for tapping. Recreating
            // every marker on each GPS/SwiftUI update used to cancel selection gestures.
            // Stable allocation-light fingerprint, including every geometry vertex.
            // String(describing:) serialised entire arrays on every GPS/SwiftUI update.
            var geometryHash = Hasher()
            geometryHash.combine(offlineRoadRevision)
            if let track {
                geometryHash.combine(track.id)
                geometryHash.combine(track.fixes.count)
                for fix in track.fixes {
                    geometryHash.combine(fix.point.latitude)
                    geometryHash.combine(fix.point.longitude)
                }
            }
            geometryHash.combine(navigationPath.count)
            for point in navigationPath {
                geometryHash.combine(point.latitude)
                geometryHash.combine(point.longitude)
            }
            let transientKey = geometryHash.finalize()
            let geometryChanged = transientKey != lastTransientKey
            if geometryChanged {
                if !transientAnnotations.isEmpty { view.removeAnnotations(transientAnnotations) }
                transientAnnotations.removeAll()
                lastTransientKey = transientKey
            }
            if lastZonesRevision != zonesRevision || lastZonesVisible != !zones.isEmpty {
                lastZonesRevision = zonesRevision
                lastZonesVisible = !zones.isEmpty
                prepareZones(zones, in: view)
            }
            if let replayPosition, replayPosition.valid {
                let coordinate = CLLocationCoordinate2D(latitude: replayPosition.latitude, longitude: replayPosition.longitude)
                if let pin = replayAnnotation { pin.coordinate = coordinate }
                else {
                    let pin = MLNPointAnnotation()
                    pin.coordinate = coordinate
                    pin.title = "REPLAY|LOCATION"
                    replayAnnotation = pin
                    view.addAnnotation(pin)
                }
            } else if let pin = replayAnnotation {
                view.removeAnnotation(pin)
                replayAnnotation = nil
            }
            var updated: [MLNAnnotation] = []
            // Hold transient annotation building behind a change check; GPS is refreshed separately.
            if geometryChanged {
            // Weather shades are drawn by WeatherFieldOverlay in a lightweight canvas.
            // Never add hundreds of weather polygons/arrow annotations to MapLibre.
            for road in offlineRoadLines where road.points.count >= 2 {
                var coords = road.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                line.title = road.isTrail ? "OFFLINE|TRAIL" : "OFFLINE|ROAD"
                updated.append(line)
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
                let coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
                let gps: MLNPointAnnotation
                if let existing = gpsAnnotation {
                    gps = existing
                    if gps.coordinate.latitude != coordinate.latitude || gps.coordinate.longitude != coordinate.longitude {
                        gps.coordinate = coordinate
                    }
                } else {
                    gps = MLNPointAnnotation()
                    gps.title = "GPS · текущая позиция"
                    gps.coordinate = coordinate
                    gpsAnnotation = gps
                    view.addAnnotation(gps)
                }
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
            if annotation.title == "GRID|SELECTED" { return .systemGreen }
            if annotation.title == "GRID|AVAILABLE" { return UIColor.white.withAlphaComponent(0.65) }
            if annotation.title?.hasPrefix("WX-ISOBAR|") == true { return .white }
            if annotation.title?.hasPrefix("WX-WIND|") == true { return .white }
            if annotation.title == "OFFLINE|TRAIL" { return .systemOrange }
            if annotation.title == "OFFLINE|ROAD" { return .systemGreen }
            if annotation.title == "NAV|HUNT" { return .systemCyan }
            if annotation.title == "Записанный маршрут" { return .systemGreen }
            return annotation.title?.hasPrefix("НЕ ПРОВЕРЕНО") == true ? .systemYellow : .systemOrange
        }
        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            if annotation.title == "GRID|SELECTED" { return 3 }
            if annotation.title == "GRID|AVAILABLE" { return 1 }
            if annotation.title?.hasPrefix("WX-ISOBAR|") == true { return 1.8 }
            if annotation.title?.hasPrefix("WX-WIND|") == true { return 2.3 }
            if annotation.title == "OFFLINE|TRAIL" { return 2.5 }
            if annotation.title == "OFFLINE|ROAD" { return 2 }
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
private
