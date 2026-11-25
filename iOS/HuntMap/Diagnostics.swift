import SwiftUI
import UIKit
import CoreLocation

extension Notification.Name { static let huntShake = Notification.Name("HuntMapShakeDetected") }

/// An invisible focusable responder receives physical-device motionEnded events.
struct ShakeDetector: UIViewRepresentable {
    func makeUIView(context: Context) -> ShakeView { ShakeView(frame: .zero) }
    func updateUIView(_ uiView: ShakeView, context: Context) { if !uiView.isFirstResponder { uiView.becomeFirstResponder() } }
    final class ShakeView: UIView {
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { DispatchQueue.main.async { self.becomeFirstResponder() } } }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { NotificationCenter.default.post(name: .huntShake, object: nil) }
            super.motionEnded(motion, with: event)
        }
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: FieldModel
    let mapCount: Int
    let wildlifeCount: Int
    let onlineMap: Bool
    @State private var includeApproximatePosition = false
    @ObservedObject private var diagnostics = AppDiagnosticLog.shared
    var weatherGridStatus = "unknown"
    var weatherPointStatus = "unknown"
    var startupStatus = "unknown"
    var startupErrors: [String] = []
    var internetConnected = false
    var weatherLayer = "none"
    var navigationStatus = "none"
    var protomapsStatus = "unknown"
    var valhallaStatus = "unknown"

    private var releaseVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }
    private var screenGeometry: String {
        let bounds = UIScreen.main.bounds
        let native = UIScreen.main.nativeBounds
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        let frame = window?.bounds ?? .zero
        let insets = window?.safeAreaInsets ?? .zero
        return "Screen pt: \(Int(bounds.width))x\(Int(bounds.height)); pixels: \(Int(native.width))x\(Int(native.height)); window pt: \(Int(frame.width))x\(Int(frame.height)); safe area T/B: \(Int(insets.top))/\(Int(insets.bottom))"
    }
    var report: String {
        let location = includeApproximatePosition && model.coordinate != nil
            ? "GPS approximate: \(String(format: "%.2f", model.coordinate!.latitude)), \(String(format: "%.2f", model.coordinate!.longitude))"
            : "GPS coordinates: REDACTED"
        return """
        HUNT MAP KZ — diagnostic report
        Build: \(releaseVersion)
        \(screenGeometry)
        Captured UTC: \(ISO8601DateFormatter().string(from: Date()))
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        GPS state: \(model.status)
        GPS authorization raw: \(model.gpsAuthorization)
        GPS horizontal accuracy m: \(model.accuracy.map { String(Int($0)) } ?? "unknown")
        \(location)
        Track recording: \(model.recording)
        Track paused: \(model.paused)
        Current track point count: \(model.currentTrack?.fixes.count ?? 0)
        Saved track count: \(model.tracks.count)
        Marker count: \(model.markers.count)
        Boundary count: \(model.zones.count)
        Map frame pt: \(UserDefaults.standard.string(forKey: "hunt.diag.mapFrame") ?? "not measured")
        Fullscreen map geometry: \(UserDefaults.standard.object(forKey: "hunt.diag.fullscreenMap") == nil ? "not measured" : String(UserDefaults.standard.bool(forKey: "hunt.diag.fullscreenMap")))
        Network path available: \(internetConnected)
        Weather point status: \(weatherPointStatus)
        Weather grid status: \(weatherGridStatus)
        Weather selected layer: \(weatherLayer)
        Startup: \(startupStatus)
        Startup failures: \(startupErrors.joined(separator: " | "))
        Protomaps: \(protomapsStatus)
        Valhalla: \(valhallaStatus)
        Navigation: \(navigationStatus)
        Weather: Open-Meteo model forecast; cached observations are not live radar.
        Map packs: \(mapCount)
        Wildlife catalogs: \(wildlifeCount)
        Map mode: \(onlineMap ? "online OpenFreeMap" : "strict offline")
        Last GPS error: \(model.lastError)
        Last warning: \(model.lastWarning)
        ---- PERFORMANCE ----
        \(HuntPerformance.shared.report)
        ---- LOGGED ERRORS AND ROOT CAUSES (last \(diagnostics.events.count)) ----
        \(diagnostics.export())
        NOTE: Diagnostic does NOT include exact coordinates, names, tracks, emails, tokens or personal identifiers.
        """
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Сводка событий") {
                    HStack {
                        Label("Сохранённые события", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text("\(diagnostics.events.count)").monospacedDigit()
                    }
                    Label(internetConnected ? "Интернет доступен" : "Нет интернет-подключения",
                          systemImage: internetConnected ? "wifi" : "wifi.slash")
                    Text("Погода: \(weatherGridStatus)")
                        .font(.caption)
                    Text("Прогноз точки: \(weatherPointStatus)")
                        .font(.caption)
                    Text("Синхронизация: \(startupStatus)")
                        .font(.caption)
                    if !startupErrors.isEmpty {
                        ForEach(startupErrors.prefix(7), id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Причины ошибок и рекомендации") {
                    if diagnostics.events.isEmpty {
                        Text("Ошибок пока не зарегистрировано. При следующем сбое журнал заполнится автоматически.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(diagnostics.events.reversed().prefix(35))) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(event.subsystem) · \(event.operation)")
                                .font(.subheadline.bold())
                            Text("\(event.code) · \(event.recordedAt.formatted(date: .numeric, time: .standard))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                            Text("Причина: \(event.rootCause)").font(.caption)
                            Text("Что проверить: \(event.nextAction)")
                                .font(.caption).foregroundStyle(.secondary)
                            if !event.details.isEmpty {
                                Text(event.details).font(.caption2.monospaced())
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding(.vertical, 5)
                    }
                }
                Section("Отчёт об ошибках") {
                    Text("Потрясите iPhone, чтобы снова открыть этот экран. Перед отправкой проверьте содержимое.")
                    Toggle("Добавить примерное местоположение (округлено)", isOn: $includeApproximatePosition)
                    Text("Отчёт включает версию сборки, iOS, GPS, настройки карты, состояние погоды, синхронизацию, историю ошибок, предполагаемые причины и рекомендации.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Section {
                    ShareLink(item: report, subject: Text("HUNT MAP KZ · диагностика"), message: Text("Отчёт для анализа ошибки")) {
                        Label("Поделиться отчётом / ChatGPT", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = report
                    } label: { Label("Скопировать полный отчёт", systemImage: "doc.on.doc") }
                    if let file = reportFile() {
                        ShareLink(item: file) { Label("Сохранить .txt в Файлы", systemImage: "doc.text") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FBTheme.background)
            .navigationTitle("Диагностика")
                .toolbar { Button("Готово") { dismiss() } }
        }
    }
    private func reportFile() -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HUNT_MAP_KZ_diagnostic.txt")
        do { try report.write(to: file, atomically: true, encoding: .utf8); return file } catch { return nil }
    }
}

struct AboutHuntView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("HUNT MAP KZ") {
                    Text("Версия приложения: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "неизвестна") · Offline First")
                    Text("Навигатор для маршрутов, пользовательских меток и проверки геозон Казахстана. Данные о границах и животных не являются юридическим разрешением на охоту.")
                }
                Section("Автор и инициатор") {
                    LabeledContent("Имя", value: "Николай Олегович Мякшин")
                    LabeledContent("Город", value: "Алматы, Казахстан")
                    LabeledContent("Профессиональная роль", value: "Руководитель направления мониторинга и Observability")
                    Text("Идея проекта: автономная навигация для охотников с геозонами, маршрутами, метками и проверяемыми источниками.")
                }
                Section("Открытые данные") {
                    Link("OpenStreetMap и лицензия ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org/")!)
                    Link("Open-Meteo и условия использования", destination: URL(string: "https://open-meteo.com/")!)
                    Link("GBIF", destination: URL(string: "https://www.gbif.org/")!)
                    Link("Государственный портал данных", destination: URL(string: "https://data.egov.kz/")!)
                }
                Section("Конфиденциальность") {
                    Text("Точные координаты, сохранённые маршруты и личные метки остаются локальными, пока пользователь самостоятельно не поделится ими. Диагностика скрывает координаты по умолчанию.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FBTheme.background)
            .navigationTitle("О приложении")
                .toolbar { Button("Готово") { dismiss() } }
        }
    }
}
