import SwiftUI
import UIKit
import HuntCore

struct FieldModeScreen: View {
    @ObservedObject var model: FieldModel
    let onReturn: (Track) -> Void
    @State private var confirmReturn = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var emergency = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Полевой режим").font(.headline).accessibilityIdentifier("field_screen_ready")
                        gpsStatus(at: clock.date)
                        FieldCompass(heading: model.fieldHeading, trueNorth: model.fieldHeadingIsTrue)
                            .huntSurface()
                        metrics(at: clock.date)
                        originCard(at: clock.date)
                        returnControl(at: clock.date)
                        recordingControls
                        HuntAction(title: "Экстренная помощь", symbol: "cross.case") { emergency = true }
                            .accessibilityIdentifier("field_sos")
                        Text(model.status).font(.caption).foregroundStyle(HuntReference.muted)
                    }.padding(.horizontal, 18).padding(.vertical, 14)
                }
            }
            .background(HuntReference.background.ignoresSafeArea())
            .navigationTitle("Полевой режим")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() }.accessibilityIdentifier("field_close") } }
            .sheet(isPresented: $emergency) { EmergencyScreen(model: model).huntModal() }
            .alert("Вернуться по записанному пути?", isPresented: $confirmReturn) {
                Button("Начать возвращение") {
                    guard let track = model.currentTrack, canReturn(at: Date()) else { return }
                    onReturn(track)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будет использована обратная последовательность уже записанных GPS-точек. Запись не остановится. Учитывайте реальные препятствия и разрывы трека.")
            }
            .confirmationDialog("Завершить запись маршрута?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Завершить", role: .destructive) { model.stopTrack() }
                Button("Отмена", role: .cancel) {}
            }
        }
        .onAppear { model.startFieldHeading() }
        .onDisappear { model.stopFieldHeading() }
        .onChange(of: phase) { _, value in
            if value == .active { model.startFieldHeading() }
            else { model.stopFieldHeading() }
        }
    }

    private func fresh(_ now: Date) -> Bool {
        guard let at = model.fieldFixTime else { return false }
        return now.timeIntervalSince(at) < 30 && now.timeIntervalSince(at) >= -5
    }
    private func gpsStatus(at now: Date) -> some View {
        let valid = fresh(now)
        return HStack {
            Image(systemName: valid ? "location.fill" : "location.slash")
                .foregroundStyle(valid ? HuntReference.green : Color.orange)
            Text(valid ? "GPS ±" + fieldNumber(model.accuracy, digits: 0) + " м" : "Нет свежей GPS-позиции")
                .font(.subheadline.bold())
            Spacer()
        }.huntSurface()
    }
    private func metrics(at now: Date) -> some View {
        let valid = fresh(now)
        let distance = model.currentTrack?.distanceMeters
        let elapsed = model.currentTrack?.durationSeconds
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            FieldMetricTile(title: "Скорость", value: fieldNumber(valid ? model.fieldSpeed : nil, digits: 1), unit: "км/ч")
            FieldMetricTile(title: "Высота", value: fieldNumber(valid ? model.fieldAltitude : nil, digits: 0), unit: "м")
            FieldMetricTile(title: "Пройдено", value: fieldNumber(distance.map { $0 / 1000 }, digits: 2), unit: "км")
            FieldMetricTile(title: "Длительность трека", value: elapsed.map { fieldDuration($0) } ?? "—", unit: "ч:мин:сек")
        }
    }
    private func originCard(at now: Date) -> some View {
        let origin = model.currentTrack?.fixes.first?.point
        let current = fresh(now) ? model.coordinate : nil
        let distance = origin.flatMap { first in current.map { GeoMath.meters(first, $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("До исходной точки по прямой").font(.subheadline).foregroundStyle(HuntReference.muted)
            Text(distance.map { fieldNumber($0 / 1000, digits: 2) + " км" } ?? "—")
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Исходная точка — первый сохранённый GPS-замер текущего трека.")
                .font(.caption).foregroundStyle(HuntReference.muted)
        }.huntSurface()
    }
    private func canReturn(at now: Date) -> Bool {
        guard fresh(now), let accuracy = model.accuracy, accuracy <= 50,
              let track = model.currentTrack, track.fixes.count >= 2 else { return false }
        return track.distanceMeters >= 15
    }
    private func returnControl(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HuntAction(title: "Вернуться по треку", symbol: "arrow.uturn.backward", primary: true) {
                confirmReturn = true
            }
            .disabled(!canReturn(at: now))
            .opacity(canReturn(at: now) ? 1 : 0.45)
            .accessibilityIdentifier("field_return")
            if !canReturn(at: now) {
                Text("Нужны свежая GPS-позиция и записанный путь не менее 15 м.")
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
        }
    }
    private var recordingControls: some View {
        VStack(spacing: 10) {
            if model.recording {
                HStack(spacing: 8) {
                    HuntAction(title: model.paused ? "Продолжить" : "Пауза", symbol: model.paused ? "play.fill" : "pause.fill") { model.togglePause() }
                    HuntAction(title: "Завершить", symbol: "stop.fill") { confirmStop = true }
                }
            } else {
                HuntAction(title: "Начать запись", symbol: "record.circle", primary: true) { model.startTrack() }
                    .accessibilityIdentifier("field_record")
            }
        }
    }
}

private struct FieldMetricTile: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(HuntReference.muted)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.65).lineLimit(1)
            Text(unit).font(.caption2).foregroundStyle(HuntReference.green)
        }.huntSurface()
    }
}

private struct FieldCompass: View {
    let heading: Double?
    let trueNorth: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(HuntReference.separator, lineWidth: 1)
                ForEach(0..<36, id: \.self) { index in
                    Rectangle().fill(index % 3 == 0 ? Color.white : HuntReference.muted)
                        .frame(width: index % 3 == 0 ? 2 : 1, height: index % 3 == 0 ? 10 : 5)
                        .offset(y: -87).rotationEffect(.degrees(Double(index) * 10))
                }
                VStack {
                    Text("С").foregroundStyle(HuntReference.green)
                    Spacer()
                    Text("Ю")
                }.padding(.vertical, 18)
                HStack {
                    Text("З")
                    Spacer()
                    Text("В")
                }.padding(.horizontal, 18)
                if let heading {
                    VStack(spacing: 0) {
                        Image(systemName: "arrowtriangle.up.fill").foregroundStyle(HuntReference.green)
                        Spacer()
                    }.frame(height: 144).rotationEffect(.degrees(heading))
                }
                Text(heading.map { String(Int($0.rounded()) % 360) + "°" } ?? "—")
                    .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
            }.font(.caption.bold()).frame(width: 200, height: 200)
            Text(heading == nil ? "Компас недоступен" : (trueNorth ? "Истинный север · направление телефона" : "Магнитный север · направление телефона"))
                .font(.caption).foregroundStyle(HuntReference.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

struct EmergencyScreen: View {
    @ObservedObject var model: FieldModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var confirmCall = false
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Экстренная помощь").font(.headline).accessibilityIdentifier("sos_screen_ready")
                        locationCard(now: clock.date)
                        if let point = model.coordinate {
                            let message = locationMessage(point)
                            HuntAction(title: copied ? "Скопировано" : "Копировать координаты", symbol: "doc.on.doc") {
                                UIPasteboard.general.string = message
                                copied = true
                            }.accessibilityIdentifier("sos_copy")
                            ShareLink(item: message) {
                                Label("Поделиться местоположением", systemImage: "square.and.arrow.up")
                                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 56)
                                    .foregroundStyle(HuntReference.green)
                                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 12))
                            }.accessibilityIdentifier("sos_share")
                        }
                        Button { confirmCall = true } label: {
                            Label("Экстренный вызов 112", systemImage: "phone.fill")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(.white).background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityIdentifier("sos_call")
                        Text("Для вызова и передачи координат может потребоваться связь. Приложение не подтверждает доставку или вызов помощи.")
                            .font(.caption).foregroundStyle(HuntReference.muted)
                    }.padding(.horizontal, 18).padding(.vertical, 14)
                }
            }
            .background(HuntReference.background.ignoresSafeArea())
            .navigationTitle("Экстренная помощь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() }.accessibilityIdentifier("sos_close") } }
            .confirmationDialog("Позвонить 112?", isPresented: $confirmCall, titleVisibility: .visible) {
                Button("Позвонить") { if let url = URL(string: "tel:112") { openURL(url) } }
                Button("Отмена", role: .cancel) {}
            }
        }
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true; model.requestGPS() }
        .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false }
    }
    private func locationCard(now: Date) -> some View {
        let battery = UIDevice.current.batteryLevel
        return VStack(alignment: .leading, spacing: 10) {
            Text("Последнее известное местоположение").font(.subheadline.bold())
            if let p = model.coordinate {
                Text(String(format: "%.6f°, %.6f°", p.latitude, p.longitude))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1)
            } else { Text("GPS-позиция отсутствует").foregroundStyle(.orange) }
            Text("Точность: ±" + fieldNumber(model.accuracy, digits: 0) + " м")
            if let time = model.fieldFixTime {
                Text("Замер: " + time.formatted(date: .abbreviated, time: .standard))
                if now.timeIntervalSince(time) >= 30 { Text("Позиция устарела").foregroundStyle(.orange) }
            }
            Text("Заряд: " + (battery >= 0 ? String(Int(battery * 100)) + "%" : "—"))
        }.font(.subheadline).huntSurface()
    }
    private func locationMessage(_ p: GeoPoint) -> String {
        let coords = String(format: "%.6f, %.6f", p.latitude, p.longitude)
        let time = model.fieldFixTime?.formatted(date: .abbreviated, time: .standard) ?? "неизвестно"
        return "HUNT MAP KZ\nПоследняя GPS-позиция: " + coords + "\nВремя замера: " + time + "\nТочность: " + fieldNumber(model.accuracy, digits: 0) + " м"
    }
}

private func fieldNumber(_ value: Double?, digits: Int) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.*f", digits, value)
}
private func fieldDuration(_ seconds: TimeInterval) -> String {
    let n = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
}
