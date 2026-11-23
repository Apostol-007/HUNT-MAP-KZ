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

    /// Draw only the visible screen. Geographic model cells can span millions of
    /// display pixels at street zoom; projecting whole-cell polygons is expensive
    /// and can fail to rasterize. Screen sampling is bounded at every zoom.
    override func draw(_ rect: CGRect) {
        guard let forecast, let mapView, let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0, bounds.height > 0 else {
            UserDefaults.standard.set("Canvas or forecast not ready", forKey: "hunt.diag.weatherPaint")
            return
        }
        let width = forecast.gridWidth, height = forecast.gridHeight
        guard width >= 2, height >= 2 else { return }
        let west = forecast.bounds.west, east = forecast.bounds.east
        let south = forecast.bounds.south, north = forecast.bounds.north

        func sample(latitude: Double, longitude: Double) -> Double? {
            guard longitude >= west, longitude <= east,
                  latitude >= south, latitude <= north else { return nil }
            let x = (longitude - west) * Double(width - 1) / (east - west)
            let y = (latitude - south) * Double(height - 1) / (north - south)
            let column = min(max(Int(x), 0), width - 2)
            let row = min(max(Int(y), 0), height - 2)
            let u = min(1.0, max(0.0, x - Double(column)))
            let v = min(1.0, max(0.0, y - Double(row)))
            let a = forecast.points[row * width + column]
            let b = forecast.points[row * width + column + 1]
            let c = forecast.points[(row + 1) * width + column]
            let d = forecast.points[(row + 1) * width + column + 1]
            guard let av = value(a), let bv = value(b),
                  let cv = value(c), let dv = value(d) else { return nil }
            return (1-u)*(1-v)*av + u*(1-v)*bv + (1-u)*v*cv + u*v*dv
        }

        let pixelStep: CGFloat = 20
        let columns = Int(ceil(bounds.width / pixelStep))
        let rows = Int(ceil(bounds.height / pixelStep))
        var paintedCells = 0
        var populatedCells = 0
        for row in 0..<rows {
            let y = CGFloat(row) * pixelStep
            for column in 0..<columns {
                let x = CGFloat(column) * pixelStep
                let screenPoint = CGPoint(x: min(bounds.width - 1, x + pixelStep / 2),
                                          y: min(bounds.height - 1, y + pixelStep / 2))
                let geo = mapView.convert(screenPoint, toCoordinateFrom: self)
                guard let reading = sample(latitude: geo.latitude, longitude: geo.longitude) else { continue }
                populatedCells += 1
                let fill = color(reading)
                guard fill.cgColor.alpha > 0.001 else { continue }
                let tile = CGRect(x: x, y: y,
                                  width: min(pixelStep + 0.5, bounds.width - x),
                                  height: min(pixelStep + 0.5, bounds.height - y))
                context.setFillColor(fill.cgColor)
                context.fill(tile)
                paintedCells += 1
            }
        }
        let detail = "layer: \(selectedLayer.rawValue); painted: \(paintedCells)/\(populatedCells); screen: \(Int(bounds.width))x\(Int(bounds.height)); grid: \(width)x\(height)"
        UserDefaults.standard.set(detail, forKey: "hunt.diag.weatherPaint")
    }
}
