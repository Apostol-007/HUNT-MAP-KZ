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

    var report: String {
        let location = includeApproximatePosition && model.coordinate != nil
            ? "GPS approximate: \(String(format: "%.2f", model.coordinate!.latitude)), \(String(format: "%.2f", model.coordinate!.longitude))"
            : "GPS coordinates: REDACTED"
        return """
        HUNT MAP KZ — diagnostic report
        Build: 0.9.0 (source build; exact Xcode revision from app build)
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
        Map packs: \(mapCount)
        Wildlife catalogs: \(wildlifeCount)
        Map mode: \(onlineMap ? "online OpenFreeMap" : "strict offline")
        Last GPS error: \(model.lastError)
        Last warning: \(model.lastWarning)
        NOTE: Diagnostic does NOT include exact coordinates, names, tracks, emails, tokens or personal identifiers.
        """
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Отчёт об ошибках") {
                    Text("Потрясите iPhone, чтобы снова открыть этот экран. Перед отправкой проверьте содержимое.")
                    Toggle("Добавить примерное местоположение (округлено)", isOn: $includeApproximatePosition)
                    Text(report).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                Section {
                    ShareLink(item: report, subject: Text("HUNT MAP KZ · диагностика"), message: Text("Отчёт для анализа ошибки")) {
                        Label("Поделиться отчётом / ChatGPT", systemImage: "square.and.arrow.up")
                    }
                    if let file = reportFile() {
                        ShareLink(item: file) { Label("Сохранить .txt в Файлы", systemImage: "doc.text") }
                    }
                }
            }.navigationTitle("Диагностика")
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
                    Text("Версия исходников: 0.9.0 · Offline First")
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
                    Link("GBIF", destination: URL(string: "https://www.gbif.org/")!)
                    Link("Государственный портал данных", destination: URL(string: "https://data.egov.kz/")!)
                }
                Section("Конфиденциальность") {
                    Text("Точные координаты, сохранённые маршруты и личные метки остаются локальными, пока пользователь самостоятельно не поделится ими. Диагностика скрывает координаты по умолчанию.")
                }
            }.navigationTitle("О приложении")
                .toolbar { Button("Готово") { dismiss() } }
        }
    }
}
