import SwiftUI
import MapLibre
import HuntCore

/// MapLibre receives only a locally generated, source-free style and file-backed MBTiles.
/// No HTTP style, glyph, sprite or tile endpoint is configured by this view.
struct OfflineMapView: UIViewRepresentable {
    let zones: [GeoZone]
    let position: GeoPoint?
    let markers: [Marker]
    let track: Track?
    let tileFiles: [URL]
    let tileRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: OfflineMapStyle.url)
        view.delegate = context.coordinator
        view.setCenter(CLLocationCoordinate2D(latitude: 43.24, longitude: 76.91), zoomLevel: 11, animated: false)
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.apply(view: view, files: tileFiles, revision: tileRevision)
        context.coordinator.updateAnnotations(view: view, zones: zones, markers: markers, position: position, track: track)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
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

        func updateAnnotations(view: MLNMapView, zones: [GeoZone], markers: [Marker], position: GeoPoint?, track: Track?) {
            if !shapes.isEmpty { view.removeAnnotations(shapes) }
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

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat { 0.95 }
        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation.title == "Записанный маршрут" { return .systemGreen }
            return annotation.title?.hasPrefix("НЕ ПРОВЕРЕНО") == true ? .systemYellow : .systemOrange
        }
        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            annotation.title == "Записанный маршрут" ? 4 : 3
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
