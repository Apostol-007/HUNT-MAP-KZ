import SwiftUI
import HuntCore

struct WeatherPanel: View {
    @ObservedObject var service: WeatherService
    let coordinate: GeoPoint?
    let online: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var hourIndex = 0
    @State private var section: WeatherSection = .wind
    @AppStorage("hunt.weather.pressureMMHG") private var pressureMMHG = false
    @AppStorage("hunt.weather.windMS") private var windMS = false

    enum WeatherSection: String, CaseIterable {
        case wind = "Ветер", pressure = "Давление", rain = "Осадки"
        var symbol: String {
            switch self {
            case .wind: "wind"
            case .pressure: "barometer"
            case .rain: "cloud.rain.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let forecast = service.forecast {
                        header(forecast)
                        HStack(spacing: 8) {
                            ForEach(WeatherSection.allCases, id: \.self) { item in
                                Button { section = item } label: {
                                    Label(item.rawValue, systemImage: item.symbol)
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(section == item ? Color.orange.opacity(0.25) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }
                        if !forecast.hourly.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("ПРОГНОЗ ПО ЧАСАМ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(selectedHour(forecast).timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption.weight(.medium))
                                }
                                Slider(value: Binding(get: { Double(hourIndex) }, set: { hourIndex = Int($0) }),
                                       in: 0...Double(max(0, forecast.hourly.count - 1)), step: 1)
                                    .tint(.orange)
                                Text("Это прогноз для одной точки, не карта осадков или поле ветра.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            detail(selectedHour(forecast))
                        }
                        Text("Источник: \(forecast.source) · получено \(forecast.retrievedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if service.isCached || Date().timeIntervalSince(forecast.retrievedAt) > 10_800 {
                            Label("Кэш прогноза: проверьте актуальность перед выходом в поле", systemImage: "clock.badge.exclamationmark")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    } else {
                        ContentUnavailableView("Нет прогноза", systemImage: "cloud.sun", description: Text("Для обновления нужны интернет и координата. Без сети доступен только ранее сохранённый прогноз."))
                    }
                    if let coordinate {
                        Button {
                            hourIndex = 0
                            service.refresh(latitude: coordinate.latitude, longitude: coordinate.longitude, strictOffline: !online)
                        } label: {
                            Label("Обновить прогноз", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(service.busy || !online)
                    } else {
                        Text("Включите GPS, чтобы получить прогноз для своей позиции.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(service.message).font(.footnote).foregroundStyle(.secondary)
                    if service.busy { ProgressView() }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Погода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .onAppear {
            if service.forecast == nil, let coordinate {
                service.refresh(latitude: coordinate.latitude, longitude: coordinate.longitude, strictOffline: !online)
            }
        }
    }
    private func selectedHour(_ weather: PointWeather) -> WeatherHour {
        weather.hourly[min(hourIndex, weather.hourly.count - 1)]
    }
    private func header(_ weather: PointWeather) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ПОГОДА В ВЫБРАННОЙ ТОЧКЕ").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(weather.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 58, weight: .light, design: .rounded))
                Spacer()
                Image(systemName: "cloud.sun.fill").font(.system(size: 36)).symbolRenderingMode(.palette).foregroundStyle(.orange, .gray)
            }
            Text("Ощущается как \(weather.apparentTemperatureC.map { "\(Int($0.rounded()))°" } ?? "—") · Влажность \(weather.humidityPercent.map { "\(Int($0.rounded()))%" } ?? "—")")
                .font(.subheadline)
            Text("Прогнозная точка: \(weather.latitude.formatted(.number.precision(.fractionLength(3)))), \(weather.longitude.formatted(.number.precision(.fractionLength(3))))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    private func detail(_ hour: WeatherHour) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case .wind:
                Label("Ветер · прогноз на 10 м", systemImage: "wind").font(.headline)
                metric("Скорость", value: speed(hour.windSpeedKmh))
                metric("Порывы", value: speed(hour.windGustKmh))
                metric("Направление · откуда", value: hour.windDirectionFromDegrees.map { "\(Int($0.rounded()))°" } ?? "—")
                metric("Направление · куда", value: hour.windDirectionToDegrees.map { "\(Int($0.rounded()))°" } ?? "—")
                Toggle("Показывать м/с", isOn: $windMS)
            case .pressure:
                Label("Атмосферное давление", systemImage: "barometer").font(.headline)
                metric("На уровне моря", value: pressure(hour.pressureMSLHpa))
                metric("У поверхности", value: pressure(hour.surfacePressureHpa))
                Toggle("Показывать мм рт. ст.", isOn: $pressureMMHG)
                Text("У поверхности давление отличается в зависимости от высоты рельефа.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .rain:
                Label("Прогноз осадков", systemImage: "cloud.rain.fill").font(.headline)
                metric("За час", value: hour.precipitationMm.map { String(format: "%.1f мм", $0) } ?? "—")
                metric("Вероятность", value: hour.precipitationProbabilityPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                Text("Это модельный прогноз, не радар фактически наблюдаемых осадков.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    private func metric(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold) }
    }
    private func pressure(_ value: Double?) -> String {
        guard let value else { return "—" }
        return pressureMMHG ? String(format: "%.1f мм рт. ст.", WeatherMath.mmHg(value)) : String(format: "%.1f гПа", value)
    }
    private func speed(_ value: Double?) -> String {
        guard let value else { return "—" }
        return windMS ? String(format: "%.1f м/с", value / 3.6) : String(format: "%.1f км/ч", value)
    }
}
