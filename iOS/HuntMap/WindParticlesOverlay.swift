import UIKit
import MapLibre

/// Native iOS wind particles. The application uses MapLibre Native, not MapLibre GL JS;
/// therefore a deck.gl / JavaScript package cannot be attached to this map.
/// Particles are driven exclusively by the validated, locally cached forecast grid.
final class WindParticlesOverlay: UIView {
    private struct Particle {
        var latitude: Double
        var longitude: Double
        var life: Int
    }

    private weak var mapView: MLNMapView?
    private var grid: ForecastGrid?
    private var particles: [Particle] = []
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var lastTimestamp = ""
    private let particleCount = 85

    init(mapView: MLNMapView) {
        self.mapView = mapView
        super.init(frame: mapView.bounds)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.addSubview(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { displayLink?.invalidate() }

    func configure(grid: ForecastGrid?, enabled: Bool) {
        guard enabled, let grid, grid.validated() else {
            self.grid = nil
            lastTimestamp = ""
            particles.removeAll()
            displayLink?.invalidate()
            displayLink = nil
            setNeedsDisplay()
            isHidden = true
            return
        }
        isHidden = false
        if lastTimestamp != grid.forecastTimeUTC || self.grid == nil {
            self.grid = grid
            lastTimestamp = grid.forecastTimeUTC
            particles = (0..<particleCount).map { _ in spawn() }
            setNeedsDisplay()
        }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
            link.preferredFramesPerSecond = 20
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func spawn() -> Particle {
        guard let grid else { return Particle(latitude: 0, longitude: 0, life: 1) }
        let lat = Double.random(in: grid.bounds.south...grid.bounds.north)
        let lon = Double.random(in: grid.bounds.west...grid.bounds.east)
        return Particle(latitude: lat, longitude: lon, life: Int.random(in: 20...90))
    }

    /// Bilinear interpolation only inside the sampled grid. Never extrapolate outside it.
    private func vector(lat: Double, lon: Double) -> (east: Double, north: Double, speed: Double)? {
        guard let grid else { return nil }
        let b = grid.bounds
        guard lat >= b.south, lat <= b.north, lon >= b.west, lon <= b.east else { return nil }
        let x = (lon - b.west) / (b.east - b.west) * Double(grid.gridWidth - 1)
        let y = (lat - b.south) / (b.north - b.south) * Double(grid.gridHeight - 1)
        let ix = min(Int(x), grid.gridWidth - 2)
        let iy = min(Int(y), grid.gridHeight - 2)
        let u = x - Double(ix), v = y - Double(iy)
        func component(_ cx: Int, _ cy: Int) -> (Double, Double)? {
            let p = grid.points[cy * grid.gridWidth + cx]
            guard let speed = p.windSpeed, let direction = p.direction else { return nil }
            let toward = (direction + 180) * .pi / 180
            return (sin(toward) * speed, cos(toward) * speed)
        }
        guard let a = component(ix, iy), let b = component(ix + 1, iy),
              let c = component(ix, iy + 1), let d = component(ix + 1, iy + 1) else { return nil }
        let e = a.0 * (1-u)*(1-v) + b.0*u*(1-v) + c.0*(1-u)*v + d.0*u*v
        let n = a.1 * (1-u)*(1-v) + b.1*u*(1-v) + c.1*(1-u)*v + d.1*u*v
        return (e, n, hypot(e, n))
    }

    @objc private func advance(_ link: CADisplayLink) {
        guard grid != nil, window != nil else { return }
        if link.timestamp - lastFrame < 0.045 { return }
        lastFrame = link.timestamp
        // Visual motion is deliberately accelerated for readability; not a prediction of travel distance.
        for i in particles.indices {
            var p = particles[i]
            if p.life <= 0 || vector(lat: p.latitude, lon: p.longitude) == nil {
                particles[i] = spawn()
                continue
            }
            guard let flow = vector(lat: p.latitude, lon: p.longitude) else { continue }
            let factor = 0.000030
            let cosLat = max(0.15, cos(p.latitude * .pi / 180))
            p.longitude += flow.east * factor / cosLat
            p.latitude += flow.north * factor
            p.life -= 1
            particles[i] = p
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let mapView, grid != nil, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineWidth(1.7)
        ctx.setLineCap(.round)
        for particle in particles {
            guard let flow = vector(lat: particle.latitude, lon: particle.longitude) else { continue }
            let position = mapView.convert(CLLocationCoordinate2D(latitude: particle.latitude, longitude: particle.longitude), toPointTo: self)
            guard rect.insetBy(dx: -10, dy: -10).contains(position) else { continue }
            let magnitude = max(0.001, hypot(flow.east, flow.north))
            let length = CGFloat(min(14, max(3, magnitude * 0.55)))
            let dx = CGFloat(flow.east / magnitude) * length
            let dy = CGFloat(-flow.north / magnitude) * length
            let color: UIColor = magnitude < 15 ? .systemTeal : (magnitude < 35 ? .systemYellow : .systemRed)
            ctx.setStrokeColor(color.withAlphaComponent(0.78).cgColor)
            ctx.move(to: CGPoint(x: position.x - dx, y: position.y - dy))
            ctx.addLine(to: position)
            ctx.strokePath()
        }
    }
}