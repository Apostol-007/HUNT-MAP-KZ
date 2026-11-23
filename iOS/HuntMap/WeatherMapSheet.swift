import SwiftUI
import HuntCore

/// The sheet is a controller for an actual gridded model forecast, not a radar image.
struct WeatherMapSheet: View {
    @ObservedObject var service: WeatherGridService
    @Binding var layer: WeatherMapLayer
    let coordinate: GeoPoint?
    let online: Bool
    @AppStorage("hunt.weather.gridServer") private var server = ""
    @State private var hoursAhead = 0.0
    @Environment(\.dismiss) private var dismiss

    private var forecastDate: Date {
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
        return start.addingTimeInterval(hoursAhead * 3600)
    }
    private var timeDescription: String {
        forecastDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()
            .locale(Locale(identifier: "ru_RU")))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Погода на карте").font(.title3.bold())
                        Picker("Слой", selection: $layer) {
                            ForEach(WeatherMapLayer.allCases) { choice in Text(choice.rawValue).tag(choice) }
                        }.pickerStyle(.segmented)
                        Text("Прогноз модели, не погодный радар. Цветные участки вычислены интерполяцией внутри полученной сетки. Стрелки показывают направление ветра, а изобары — расчётные линии давления.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    if layer != .none {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                                Text("Время прогноза").font(.headline)
                            }
                            Text(timeDescription.capitalized).font(.subheadline.bold())
                            HStack(spacing: 12) {
                                Button { hoursAhead = max(0, hoursAhead - 1) } label: {
                                    Image(systemName: "minus").frame(width: 44, height: 44)
                                }.disabled(hoursAhead == 0)
                                Slider(value: $hoursAhead, in: 0...48, step: 1).tint(.orange)
                                    .accessibilityLabel("Час прогноза")
                                Button { hoursAhead = min(48, hoursAhead + 1) } label: {
                                    Image(systemName: "plus").frame(width: 44, height: 44)
                                }.disabled(hoursAhead == 48)
                            }
                            Text("Сдвиг: +\(Int(hoursAhead)) ч. Чтобы сменить прогноз на карте, нажмите «Загрузить».")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Легенда · \(legendUnit)").font(.headline)
                            HStack(spacing: 0) {
                                ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                                    VStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(item.1).frame(height: 12)
                                        Text(item.0).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                            Text(legendExplanation).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Источник сеточных данных").font(.headline)
                        TextField("https://твой-сервер.kz", text: $server)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).textFieldStyle(.roundedBorder)
                        Text("Нужен собственный HTTPS-сервер с /v1/weather/grid. Публичные тайлы карты и этот прогноз — разные источники.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let coordinate {
                            Button {
                                service.load(server: server, latitude: coordinate.latitude,
                                             longitude: coordinate.longitude,
                                             hourOffset: Int(hoursAhead), strictOffline: !online)
                            } label: {
                                Label(service.loading ? "Получение данных…" : "Загрузить прогноз на карту", systemImage: "arrow.down.circle.fill")
                                    .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 46)
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(layer == .none || service.loading || !online)
                        } else {
                            Label("Для центрирования сетки сначала включите GPS", systemImage: "location.slash")
                                .foregroundStyle(.orange).font(.footnote)
                        }
                        if !online { Text("Строго офлайн: сетевые запросы отключены").foregroundStyle(.orange).font(.footnote) }
                        if service.loading { ProgressView() }
                        Text(service.status).font(.footnote)
                        if service.grid != nil {
                            HStack(spacing: 7) {
                                Image(systemName: "calendar")
                                Text("Загружено для: \(service.forecastLabel)")
                            }.font(.caption)
                            if service.cached || service.gridAgeWarning {
                                Label("Сохранённый или устаревший прогноз: проверьте время", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    Button("Убрать погодный слой", role: .destructive) {
                        layer = .none
                        dismiss()
                    }.frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Погодные слои")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear { hoursAhead = Double(service.chosenOffset) }
        }
    }

    private var legendUnit: String {
        switch layer { case .wind: return "км/ч"; case .pressure: return "гПа"; case .precipitation: return "мм/час"; case .none: return "" }
    }
    private var legend: [(String, Color)] {
        switch layer {
        case .wind: return [("<15", .teal), ("15–35", .yellow), (">35", .red)]
        case .pressure: return [("<1000", .blue), ("1000–1020", .green), (">1020", .orange)]
        case .precipitation: return [("<0,1", .clear), ("0,1–2", .blue), ("2–8", .purple), (">8", .red)]
        case .none: return []
        }
    }
    private var legendExplanation: String {
        switch layer {
        case .wind: return "Цвет показывает скорость на высоте 10 м. Стрелки показывают направление «куда дует». Порывы — в карточке погоды."
        case .pressure: return "Атмосферное давление на уровне моря, не давление у поверхности. Изобары рассчитаны по разреженной сетке модели (шаг 5 гПа)."
        case .precipitation: return "Прогнозное количество осадков за час. Это не метеорадар и не измерение на местности."
        case .none: return ""
        }
    }
}
