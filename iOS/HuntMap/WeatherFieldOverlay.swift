import UIKit
import MapLibre

/// Draws forecast shade as a single lightweight overlay, NOT hundreds of MapLibre annotations.
/// Repaint on forecast/viewport change only; never on each wind animation frame.
final class WeatherFieldOverlay: UIView {
    private weak var mapView: MLNMapView?
    private var forecast: ForecastGrid?
    private var selectedLayer: WeatherMapLayer = .none
    private var lastSignature = ""

    init(mapView: MLNMapView) {
        self.mapView = mapView
        super.init(frame: mapView.bounds)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.addSubview(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// MLNMapView starts with a zero-sized frame in UIViewRepresentable.
    /// Keep the canvas exactly aligned after UIKit completes actual layout.
    func syncMapGeometry() {
        guard let mapView, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        if frame != mapView.bounds {
            frame = mapView.bounds
            setNeedsDisplay()
        }
        mapView.bringSubviewToFront(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.syncMapGeometry() }
    }

    func configure(grid: ForecastGrid?, layer: WeatherMapLayer) {
        syncMapGeometry()
        guard layer != .none, let grid, grid.validated() else {
            if !isHidden {
                forecast = nil
                lastSignature = ""
                isHidden = true
                setNeedsDisplay()
            }
            return
        }
        isHidden = false
        let first = grid.points.first
        let last = grid.points.last
        let signature = "\(layer.rawValue)|\(grid.forecastTimeUTC)|\(grid.bounds.west)|\(grid.bounds.south)|\(grid.bounds.east)|\(grid.bounds.north)|\(grid.gridWidth)x\(grid.gridHeight)|\(first?.windSpeed ?? -1)|\(first?.pressure ?? -1)|\(last?.precipitation ?? -1)"
        // Assign every time: a refreshed provider field can share the same bounds/time.
        forecast = grid
        selectedLayer = layer
        if signature != lastSignature {
            lastSignature = signature
            setNeedsDisplay()
        }
    }

    private func value(_ point: ForecastGrid.Point) -> Double? {
        switch selectedLayer {
        case .wind: return point.windSpeed
        case .pressure: return point.pressure
        case .precipitation: return point.precipitation
        case .none: return nil
        }
    }

    private func color(_ measurement: Double) -> UIColor {
        switch selectedLayer {
        case .wind:
            if measurement < 15 { return UIColor(red: 0.15, green: 0.80, blue: 0.88, alpha: 0.30) }
            if measurement < 35 { return UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 0.32) }
            return UIColor(red: 0.98, green: 0.32, blue: 0.26, alpha: 0.36)
        case .pressure:
            if measurement < 1000 { return UIColor(red: 0.13, green: 0.46, blue: 0.94, alpha: 0.40) }
            if measurement < 1020 { return UIColor(red: 0.25, green: 0.82, blue: 0.50, alpha: 0.32) }
            return UIColor(red: 0.96, green: 0.60, blue: 0.26, alpha: 0.36)
        case .precipitation:
            if measurement < 0.1 { return .clear }
            if measurement < 2 { return UIColor(red: 0.19, green: 0.60, blue: 1, alpha: 0.40) }
            if measurement < 8 { return UIColor(red: 0.58, green: 0.32, blue: 0.92, alpha: 0.48) }
            return UIColor(red: 0.96, green: 0.29, blue: 0.45, alpha: 0.53)
        case .none: return .clear
        }
    }

    override func draw(_ rect: CGRect) {
        guard let forecast, let mapView, let context = UIGraphicsGetCurrentContext() else { return }
        let countX = forecast.gridWidth - 1
        let countY = forecast.gridHeight - 1
        guard countX > 0, countY > 0 else { return }
        let latStep = (forecast.bounds.north - forecast.bounds.south) / Double(countY)
        let lonStep = (forecast.bounds.east - forecast.bounds.west) / Double(countX)

        func bilinear(_ a: Double, _ b: Double, _ c: Double, _ d: Double,
                      _ u: Double, _ v: Double) -> Double {
            a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v
        }
        // Four small tiles per model cell provide a readable field with a bounded
        // draw cost (at 8x6 nodes: 140 tiles total, rather than thousands).
        for row in 0..<countY {
            for column in 0..<countX {
                let a = forecast.points[row * forecast.gridWidth + column]
                let b = forecast.points[row * forecast.gridWidth + column + 1]
                let c = forecast.points[(row + 1) * forecast.gridWidth + column]
                let d = forecast.points[(row + 1) * forecast.gridWidth + column + 1]
                guard let av = value(a), let bv = value(b),
                      let cv = value(c), let dv = value(d) else { continue }
                for subY in 0..<2 {
                    for subX in 0..<2 {
                        let u0 = Double(subX) / 2, u1 = Double(subX + 1) / 2
                        let v0 = Double(subY) / 2, v1 = Double(subY + 1) / 2
                        let average = bilinear(av, bv, cv, dv,
                                               (u0 + u1) / 2, (v0 + v1) / 2)
                        let fill = color(average)
                        if fill.cgColor.alpha < 0.01 { continue }
                        let corners = [(u0,v0),(u1,v0),(u1,v1),(u0,v1)]
                        let points: [CGPoint] = corners.map { pair in
                            let u = pair.0, v = pair.1
                            let location = CLLocationCoordinate2D(
                                latitude: forecast.bounds.south + (Double(row) + v) * latStep,
                                longitude: forecast.bounds.west + (Double(column) + u) * lonStep)
                            return mapView.convert(location, toPointTo: self)
                        }
                        context.move(to: points[0])
                        for p in points.dropFirst() { context.addLine(to: p) }
                        context.closePath()
                        context.setFillColor(fill.cgColor)
                        context.fillPath()
                    }
                }
            }
        }
    }
}
