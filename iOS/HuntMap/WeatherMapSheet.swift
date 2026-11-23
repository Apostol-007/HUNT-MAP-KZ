import SwiftUI
import HuntCore

/// The sheet is a controller for an actual gridded model forecast, not a radar image.
struct WeatherMapSheet: View {
    @ObservedObject var service: WeatherGridService
    @Binding var layer: WeatherMapLayer
    let coordinate: GeoPoint?
    let online: Bool
    var onShowKazakhstan: () -> Void = {}
    @State private var hoursAhead = 0.0
    @State private var forecastMode = 0
    @State private var selectedDay = 0
    @State private var selectionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var maximumHour: Double { 167 }
    private var baseHour: Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
    }
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
                            Picker("Период", selection: $forecastMode) {
                                Text("По часам").tag(0)
                                Text("По дням").tag(1)
                                Text("Неделя").tag(2)
                            }.pickerStyle(.segmented)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 7) {
                                    ForEach(0..<7, id: \.self) { day in
                                        let date = baseHour.addingTimeInterval(Double(day * 24) * 3600)
                                        Button {
                                            selectedDay = day
                                            hoursAhead = Double(min(167, day * 24))
                                        } label: {
                                            Text(date.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "ru_RU"))))
                                                .font(.caption.bold()).padding(.vertical, 9).padding(.horizontal, 12)
                                                .background(selectedDay == day ? FBTheme.green.opacity(0.24) : Color.secondary.opacity(0.12), in: Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            Text(timeDescription.capitalized).font(.subheadline.bold())
                            if forecastMode == 0 {
                                HStack(spacing: 12) {
                                    Button { hoursAhead = max(0, hoursAhead - 1); selectedDay = Int(hoursAhead) / 24 } label: {
                                        Image(systemName: "minus").frame(width: 44, height: 44)
                                    }.disabled(hoursAhead == 0)
                                    Slider(value: $hoursAhead, in: 0...maximumHour, step: 1).tint(FBTheme.green)
                                        .accessibilityLabel("Час прогноза")
                                        .onChange(of: hoursAhead) { _, value in selectedDay = Int(value) / 24 }
                                    Button { hoursAhead = min(maximumHour, hoursAhead + 1); selectedDay = Int(hoursAhead) / 24 } label: {
                                        Image(systemName: "plus").frame(width: 44, height: 44)
                                    }.disabled(hoursAhead == maximumHour)
                                }
                            } else if forecastMode == 1 {
                                Text("Выбран день \(selectedDay + 1). Час для карты: \(Int(hoursAhead) % 24):00 от начала прогноза. Для точного выбора переключись на «По часам».")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Недельный обзор. Выбери день выше для просмотра погодного слоя на карте.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Прогноз до 7 дней (168 часов). Отображаемая сетка загружается отдельно для выбранного часа.")
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
                        Label("Прогноз · Open-Meteo", systemImage: "cloud.sun.fill").font(.headline)
                        Text("Слой появляется автоматически при выборе, а при изменении часа и масштаба данные обновляются без кнопок. Без интернета доступен сохранённый кеш.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            onShowKazakhstan()
                            dismiss()
                        } label: {
                            Label("Весь Казахстан на карте", systemImage: "globe.europe.africa.fill")
                                .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent).tint(FBTheme.green)
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
            .fbScreenBackground()
            .navigationTitle("Погодные слои")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear {
                hoursAhead = Double(service.chosenOffset)
                selectedDay = service.chosenOffset / 24
                if layer != .none { service.load(hourOffset: service.chosenOffset) }
            }
            .onChange(of: layer) { _, value in
                selectionTask?.cancel()
                if value != .none { service.load(hourOffset: Int(hoursAhead)) }
            }
            .onChange(of: hoursAhead) { _, value in
                guard layer != .none else { return }
                selectionTask?.cancel()
                selectionTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    service.load(hourOffset: Int(value))
                }
            }
            .onDisappear { selectionTask?.cancel() }
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