import SwiftUI
import AVFoundation
import CoreLocation
import HuntCore

private struct LiveCameraPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> CameraHostView { CameraHostView() }
    func updateUIView(_ view: CameraHostView, context: Context) {}
}

private final class CameraHostView: UIView {
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
        Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard allowed, let self else { return }
            await self.configureCamera()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); preview.frame = bounds }
    private func configureCamera() async {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        session.startRunning()
    }

}

@MainActor private final class CompassHeading: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var degrees: Double = 0
    @Published var calibrated = false
    private let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        guard heading.headingAccuracy >= 0, value.isFinite else { return }
        degrees = value
        calibrated = true
    }
    deinit { manager.stopUpdatingHeading() }
}

// Heading is shared by the map compass and the camera bearing estimator.
struct MapCompassView: View {
    @StateObject private var compass = CompassHeading()
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(.black.opacity(0.85)).frame(width: 54, height: 54)
                Circle().stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 45, height: 45)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(-compass.degrees))
            }
            Text(compass.calibrated ? String(format: "%03.0f°", compass.degrees) : "—°")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Компас: направление на север")
    }
}

/// Calculates a GPS destination from the device position, heading and an
/// explicitly user-entered distance. Camera pixels do NOT measure range.
struct RangefinderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var heading = CompassHeading()
    let position: GeoPoint?
    let accuracy: Double?
    let onCreateMarker: (Marker) -> Void
    @State private var meters: Double = 100
    @State private var title = "Метка с камеры"
    @State private var selectedSymbol = "mappin.circle.fill"
    @State private var saved = false

    private var destination: GeoPoint? {
        guard let position, heading.calibrated, position.latitude.isFinite,
              position.longitude.isFinite else { return nil }
        let radius = 6_371_000.0
        let angular = meters / radius
        let lat1 = position.latitude * .pi / 180
        let lon1 = position.longitude * .pi / 180
        let bearing = heading.degrees * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        let normalizedLon = (lon2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoPoint(lat2 * 180 / .pi, normalizedLon)
    }

    var body: some View {
        ZStack {
            LiveCameraPreview().ignoresSafeArea()
            Color.black.opacity(0.22).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    Spacer()
                    Text("ДАЛЬНОМЕР").font(.headline)
                    Spacer()
                }
                .padding(.top, 12)
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 78, height: 78)
                    Rectangle().fill(.white).frame(width: 1, height: 116)
                    Rectangle().fill(.white).frame(width: 116, height: 1)
                    Circle().fill(.orange).frame(width: 7, height: 7)
                }
                Text(String(format: "%.0f м", meters))
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("Наведите центр камеры на объект и задайте расстояние вручную")
                    .font(.caption).multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Slider(value: $meters, in: 10...5000, step: 10)
                    HStack {
                        Text("10 м")
                        Spacer()
                        Text("5 км")
                    }.font(.caption2)
                    TextField("Название метки", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.black)
                    Picker("Значок", selection: $selectedSymbol) {
                        Label("Точка", systemImage: "mappin.circle.fill").tag("mappin.circle.fill")
                        Label("Флаг", systemImage: "flag.fill").tag("flag.fill")
                        Label("Животное", systemImage: "pawprint.fill").tag("pawprint.fill")
                        Label("Машина", systemImage: "car.fill").tag("car.fill")
                    }.tint(.white)
                    Button {
                        guard let destination else { return }
                        let marker = Marker(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Метка с камеры" : title,
                                            kind: "Точка", coordinate: destination,
                                            symbol: selectedSymbol, colorHex: "#FF9F1C")
                        onCreateMarker(marker)
                        saved = true
                        dismiss()
                    } label: {
                        Label("Поставить метку на выбранной дальности", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil)
                }
                .padding(16)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                Text(heading.calibrated ? String(format: "Азимут %.0f° · GPS ±%.0f м", heading.degrees, accuracy ?? 0) : "Ожидание GPS и компаса")
                    .font(.caption.bold())
                Text("Это расчётная точка по GPS, азимуту и введённой дальности. Камера не измеряет расстояние. Точность зависит от GPS, компаса и заданной дистанции.")
                    .font(.caption2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
    }
}
