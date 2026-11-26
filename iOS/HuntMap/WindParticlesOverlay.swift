import UIKit
import MapLibre

/// Animated native wind streamlines over MapLibre. A soft comet trail is rendered
/// along the historical path of each particle instead of drawing rigid arrow strokes.
/// All motion is computed from the real model's U/V vectors, bilinearly interpolated
/// inside the forecast grid; visual particle speed is deliberately exaggerated.
final class WindParticlesOverlay: UIView {
    private struct Coordinate {
        var latitude: Double
        var longitude: Double
    }
    private struct Particle {
        var position: Coordinate
        var trail: [Coordinate]
        var age: Int
        var lifetime: Int
    }

    private weak var mapView: MLNMapView?
    private var forecast: ForecastGrid?
    private var particles: [Particle] = []
    private var displayLink: CADisplayLink?
    private var previousFrame: CFTimeInterval = 0
    private var forecastSignature = ""
    private let maximumTrail = 9
    private let particleCount = 85

    init(mapView: MLNMapView, hostView: UIView) {
        self.mapView = mapView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            topAnchor.constraint(equalTo: hostView.topAnchor),
            bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { displayLink?.invalidate() }

    func configure(grid: ForecastGrid?, enabled: Bool) {
        guard enabled, let grid, grid.validated() else {
            forecast = nil
            forecastSignature = ""
            particles.removeAll()
            displayLink?.invalidate()
            displayLink = nil
            isHidden = true
            setNeedsDisplay()
            return
        }
        isHidden = false
        let b = grid.bounds
        let signature = "\(grid.forecastTimeUTC)|\(b.west)|\(b.south)|\(b.east)|\(b.north)|\(grid.gridWidth)x\(grid.gridHeight)|\(grid.points.first?.windSpeed ?? -1)|\(grid.points.last?.direction ?? -1)"
        if signature != forecastSignature {
            forecast = grid
            forecastSignature = signature
            particles = (0..<particleCount).map { _ in spawn() }
            setNeedsDisplay()
        }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFramesPerSecond = 15
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func spawn() -> Particle {
        guard let forecast, let mapView else {
            return Particle(position: Coordinate(latitude: 0, longitude: 0), trail: [], age: 0, lifetime: 1)
        }
        let bounds = forecast.bounds
        let visible = mapView.visibleCoordinateBounds
        let west = max(bounds.west, min(visible.sw.longitude, visible.ne.longitude))
        let east = min(bounds.east, max(visible.sw.longitude, visible.ne.longitude))
        let south = max(bounds.south, min(visible.sw.latitude, visible.ne.latitude))
        let north = min(bounds.north, max(visible.sw.latitude, visible.ne.latitude))
        let lon = west < east ? Double.random(in: west...east) : Double.random(in: bounds.west...bounds.east)
        let lat = south < north ? Double.random(in: south...north) : Double.random(in: bounds.south...bounds.north)
        let coordinate = Coordinate(latitude: lat, longitude: lon)
        return Particle(position: coordinate, trail: [coordinate], age: 0, lifetime: Int.random(in: 55...125))
    }

    /// Returns east/north components in km/h using weather convention FROM -> TO.
    private func wind(at p: Coordinate) -> (east: Double, north: Double, speed: Double)? {
        guard let forecast else { return nil }
        let b = forecast.bounds
        guard p.longitude >= b.west, p.longitude <= b.east,
              p.latitude >= b.south, p.latitude <= b.north else { return nil }
        let x = (p.longitude - b.west) / (b.east - b.west) * Double(forecast.gridWidth - 1)
        let y = (p.latitude - b.south) / (b.north - b.south) * Double(forecast.gridHeight - 1)
        let col = min(Int(x), forecast.gridWidth - 2)
        let row = min(Int(y), forecast.gridHeight - 2)
        let u = x - Double(col), v = y - Double(row)
        func uv(_ dx: Int, _ dy: Int) -> (Double, Double)? {
            let point = forecast.points[(row + dy) * forecast.gridWidth + col + dx]
            guard let speed = point.windSpeed, let direction = point.direction else { return nil }
            let radians = (direction + 180) * .pi / 180
            return (speed * sin(radians), speed * cos(radians))
        }
        guard let a = uv(0, 0), let b = uv(1, 0),
              let c = uv(0, 1), let d = uv(1, 1) else { return nil }
        let east = a.0 * (1-u)*(1-v) + b.0*u*(1-v) + c.0*(1-u)*v + d.0*u*v
        let north = a.1 * (1-u)*(1-v) + b.1*u*(1-v) + c.1*(1-u)*v + d.1*u*v
        return (east, north, hypot(east, north))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let mapView, forecast != nil, window != nil,
              UIApplication.shared.applicationState == .active,
              !UIAccessibility.isReduceMotionEnabled else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        let preferred = constrained ? 8 : 15
        if link.preferredFramesPerSecond != preferred { link.preferredFramesPerSecond = preferred }
        if link.timestamp - previousFrame < 0.064 { return }
        previousFrame = link.timestamp
        for index in particles.indices {
            var particle = particles[index]
            guard particle.age < particle.lifetime, let flow = wind(at: particle.position) else {
                particles[index] = spawn()
                continue
            }
            // Move 0.7...2.5 SCREEN pixels per animation frame regardless of zoom.
            // This keeps a country-level overview readable and avoids huge streaks on zoom.
            let length = max(0.4, min(2.7, 0.55 + flow.speed * 0.065))
            let angle = atan2(flow.east, flow.north)
            let origin = mapView.convert(CLLocationCoordinate2D(latitude: particle.position.latitude,
                                                               longitude: particle.position.longitude), toPointTo: self)
            let destination = CGPoint(x: origin.x + CGFloat(sin(angle) * length),
                                      y: origin.y - CGFloat(cos(angle) * length))
            let next = mapView.convert(destination, toCoordinateFrom: self)
            particle.position = Coordinate(latitude: next.latitude, longitude: next.longitude)
            particle.trail.append(particle.position)
            if particle.trail.count > maximumTrail { particle.trail.removeFirst() }
            particle.age += 1
            particles[index] = particle
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let mapView, forecast != nil, let context = UIGraphicsGetCurrentContext() else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for particle in particles where particle.trail.count > 1 {
            guard let flow = wind(at: particle.position) else { continue }
            let color: UIColor
            switch flow.speed {
            case ..<12: color = UIColor(red: 0.35, green: 0.87, blue: 0.96, alpha: 1)
            case ..<28: color = UIColor(red: 0.45, green: 0.94, blue: 0.72, alpha: 1)
            case ..<45: color = UIColor(red: 0.98, green: 0.85, blue: 0.48, alpha: 1)
            default: color = UIColor(red: 1.0, green: 0.58, blue: 0.47, alpha: 1)
            }
            let fade = min(1, Double(particle.age) / 15) * min(1, Double(particle.lifetime - particle.age) / 17)
            let points = particle.trail.map {
                mapView.convert(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), toPointTo: self)
            }
            guard let last = points.last, rect.insetBy(dx: -80, dy: -80).contains(last) else { continue }
            for segment in 1..<points.count {
                let strength = CGFloat(segment) / CGFloat(points.count)
                let alpha = CGFloat(fade) * strength * strength
                let from = points[segment - 1], to = points[segment]
                // Diffuse glow under a thin tapered strand, not a static directional arrow.
                context.setLineWidth(3.0 * strength + 0.6)
                context.setStrokeColor(color.withAlphaComponent(0.07 * alpha).cgColor)
                context.move(to: from); context.addLine(to: to); context.strokePath()
                context.setLineWidth(0.65 + 1.15 * strength)
                context.setStrokeColor(color.withAlphaComponent(0.6 * alpha).cgColor)
                context.move(to: from); context.addLine(to: to); context.strokePath()
            }
            context.setFillColor(UIColor.white.withAlphaComponent(CGFloat(0.48 * fade)).cgColor)
            context.fillEllipse(in: CGRect(x: last.x - 1.15, y: last.y - 1.15, width: 2.3, height: 2.3))
        }
    }
}