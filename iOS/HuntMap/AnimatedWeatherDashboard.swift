import SwiftUI
import HuntCore

private enum WeatherScene: Equatable {
    case unknown, sun, cloud, fog, rain, snow, storm
    init(_ code: Int?) {
        switch code {
        case 0?: self = .sun
        case 1?, 2?, 3?: self = .cloud
        case 45?, 48?: self = .fog
        case 51?, 53?, 55?, 56?, 57?, 61?, 63?, 65?, 66?, 67?, 80?, 81?, 82?: self = .rain
        case 71?, 73?, 75?, 77?, 85?, 86?: self = .snow
        case 95?, 96?, 99?: self = .storm
        default: self = .unknown
        }
    }
    var name: String {
        switch self {
        case .unknown: return "Условия неизвестны"
        case .sun: return "Ясно"
        case .cloud: return "Облачно"
        case .fog: return "Туман"
        case .rain: return "Осадки"
        case .snow: return "Снег"
        case .storm: return "Гроза"
        }
    }
    func icon(_ night: Bool) -> String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .sun: return night ? "moon.stars.fill" : "sun.max.fill"
        case .cloud: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .storm: return "cloud.bolt.rain.fill"
        }
    }
    func colors(_ night: Bool) -> [Color] {
        [HuntReference.card, HuntReference.background]
    }
}

private struct SkyMotion: View {
    let scene: WeatherScene
    let night: Bool
    let windy: Bool
    var precipitation: Double? = nil
    var windSpeed: Double? = nil
    var windDirection: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            LinearGradient(colors: scene.colors(night), startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || phase != .active)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    let painter = NaturalWeatherPainter(size: size, time: time, night: night,
                        rainRate: precipitation ?? 0, windSpeed: windSpeed ?? 0,
                        windDirection: windDirection ?? 0, motion: !reduceMotion)
                    if scene == .sun { painter.celestial(context) }
                    if scene == .cloud || scene == .rain || scene == .snow || scene == .storm || scene == .fog {
                        painter.clouds(context, fog: scene == .fog, storm: scene == .storm)
                    }
                    if scene == .rain || scene == .storm { painter.rain(context) }
                    if scene == .snow { painter.snow(context) }
                    if windy && scene != .rain && scene != .storm && scene != .snow { painter.wind(context) }
                    if scene == .storm { painter.lightning(context) }
                }
            }
            // Maintain readable foreground text without changing the application's palette.
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AnimatedWeatherDashboard: View {
    @ObservedObject var service: WeatherService
    let coordinate: GeoPoint?
    let onMap: (WeatherMapLayer) -> Void
    let onDetails: () -> Void
    var locationTitle = "Текущая GPS-позиция"
    @State private var mode = ForecastMode.temperature
    @State private var selected: Date?
    private let accent = HuntReference.green
    private enum ForecastMode: String, CaseIterable {
        case temperature = "Погодные условия", rain = "Осадки", wind = "Ветер"
        var icon: String {
            switch self { case .temperature: return "cloud.sun.fill"; case .rain: return "drop.fill"; case .wind: return "wind" }
        }
        var subtitle: String {
            switch self { case .temperature: return "Температура · °C"; case .rain: return "Интенсивность · вероятность"; case .wind: return "Скорость · порывы · км/ч" }
        }
    }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Almaty") ?? .current
        return c
    }
    private func dateText(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_KZ")
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
    private func n(_ value: Double?, _ digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", digits, value)
    }
    private func unit(_ value: Double?, _ suffix: String) -> String { value == nil ? "—" : n(value) + suffix }
    private func surface<C: View>(@ViewBuilder content: () -> C) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
    }
    var body: some View {
        VStack(spacing: 12) {
            if let weather = service.forecast {
                dashboard(weather)
            } else {
                ContentUnavailableView("Нет прогноза", systemImage: "cloud.sun", description: Text("Включите GPS и интернет. Ранее загруженный прогноз доступен офлайн."))
            }
            if let point = coordinate {
                HuntAction(title: service.busy ? "Обновляется…" : "Обновить прогноз", symbol: "arrow.clockwise") {
                    service.refresh(latitude: point.latitude, longitude: point.longitude, strictOffline: false)
                }.disabled(service.busy)
            }
            Text(service.message).font(.caption).foregroundStyle(HuntReference.muted)
        }
        .onAppear { if let point = coordinate { service.updateIfNeeded(latitude: point.latitude, longitude: point.longitude) } }
    }
    private func dashboard(_ weather: PointWeather) -> some View {
        let now = weather.current.timestamp
        let hours = weather.hourly.sorted { $0.timestamp < $1.timestamp }
        let upcoming = [weather.current] + Array(hours.filter { $0.timestamp > now }.prefix(48))
        let groups = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.timestamp) }
        let days = Array(groups.keys.sorted().filter { $0 >= calendar.startOfDay(for: now) }.prefix(7))
        let today = groups[calendar.startOfDay(for: now)] ?? []
        let temps = hours.compactMap(\.temperatureC)
        let scene = WeatherScene(weather.current.weatherCode)
        return VStack(spacing: 12) {
            ReferencePageHeader(title: "Погода")
            Label(locationTitle, systemImage: "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(HuntReference.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "Точка прогноза: %.4f, %.4f", weather.latitude, weather.longitude)).font(.caption2).foregroundStyle(HuntReference.muted)
            currentConditions(weather, today: today, scene: scene)
            hourly(upcoming)
            surface {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ПРОГНОЗ ПО ДНЯМ").font(.caption.bold()).foregroundStyle(HuntReference.muted)
                    ForEach(days, id: \.self) { day in
                        daily(day, hours: groups[day] ?? [], now: now, minimum: temps.min() ?? 0, maximum: temps.max() ?? 0)
                        if day != days.last { Divider() }
                    }
                }
            }
            surface {
                VStack(spacing: 10) {
                    metric("Ощущается", unit(weather.apparentTemperatureC, "°"), "thermometer")
                    metric("Влажность", unit(weather.humidityPercent, "%"), "humidity")
                    metric("Ветер", n(weather.current.windSpeedKmh, 1) + " км/ч", "wind")
                    metric("Порывы", n(weather.current.windGustKmh, 1) + " км/ч", "wind")
                    metric("Давление", n(weather.current.pressureMSLHpa) + " гПа", "barometer")
                    metric("Осадки", n(weather.current.precipitationMm, 1) + " мм", "drop")
                    metric("Вероятность осадков", unit(weather.current.precipitationProbabilityPercent, "%"), "umbrella")
                    metric("Облачность", unit(weather.current.cloudCoverPercent, "%"), "cloud")
                    metric("Видимость", unit(weather.current.visibilityMeters.map { $0 / 1000 }, " км"), "eye")
                    metric("УФ-индекс", n(weather.current.uvIndex, 1), "sun.max")
                    metric("Направление ветра (откуда)", unit(weather.current.windDirectionFromDegrees, "°"), "location.north.line")
                }
            }
            surface {
                VStack(spacing: 8) {
                    HuntAction(title: "Карта ветра", symbol: "wind") { onMap(.wind) }
                    HuntAction(title: "Карта осадков", symbol: "drop") { onMap(.precipitation) }
                    HuntAction(title: "Карта давления", symbol: "barometer") { onMap(.pressure) }
                    HuntAction(title: "Подробный прогноз", symbol: "calendar") { onDetails() }
                }
            }
            Text("Open-Meteo · UTC+5 · " + dateText(weather.retrievedAt, "dd.MM HH:mm")).font(.caption2).foregroundStyle(HuntReference.muted)
        }
    }

    private func currentConditions(_ weather: PointWeather, today: [WeatherHour], scene: WeatherScene) -> some View {
        let temperatures = today.compactMap(\.temperatureC)
        let maxLabel = unit(temperatures.max(), "°")
        let minLabel = unit(temperatures.min(), "°")
        let nighttime = weather.current.isDay == 0
        let windy = (weather.current.windSpeedKmh ?? 0) >= 25
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: scene.icon(nighttime))
                        .font(.system(size: 36))
                        .foregroundStyle(HuntReference.mint)
                    Text(unit(weather.temperatureC, "°"))
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(scene.name).font(.subheadline.bold())
                }
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 12) {
                    currentMetric("Ветер", n(weather.current.windSpeedKmh, 1) + " км/ч", "wind")
                    currentMetric("Давление", n(weather.current.pressureMSLHpa) + " гПа", "barometer")
                    currentMetric("Осадки", n(weather.current.precipitationMm, 1) + " мм", "cloud.rain")
                }
            }
            Text("Макс.: " + maxLabel + " · мин.: " + minLabel)
                .font(.caption)
                .foregroundStyle(HuntReference.muted)
            if service.isCached || Date().timeIntervalSince(weather.retrievedAt) > 10800 {
                Label("Сохранённый прогноз", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            SkyMotion(scene: scene, night: nighttime, windy: windy,
                      precipitation: weather.current.precipitationMm,
                      windSpeed: weather.current.windSpeedKmh,
                      windDirection: weather.current.windDirectionToDegrees)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        }
    }

    private func currentMetric(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(HuntReference.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(HuntReference.muted)
                Text(value).font(.caption.bold())
            }
        }
    }
    private func hourly(_ hours: [WeatherHour]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            hourlyHeading
            hourlyTimeline(hours)
            hourlySelection(hours)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
    }

    private var hourlyHeading: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.rawValue).font(.headline)
                Text(mode.subtitle).font(.caption2).foregroundStyle(HuntReference.muted)
            }
            Spacer(minLength: 0)
            modeControls
        }
    }

    private var modeControls: some View {
        HStack(spacing: 2) {
            ForEach(ForecastMode.allCases, id: \.self) { item in
                modeButton(item)
            }
        }
        .background(HuntReference.background, in: Capsule())
    }

    private func modeButton(_ item: ForecastMode) -> some View {
        let fill: Color = mode == item ? HuntReference.green : Color.clear
        return Button { mode = item } label: {
            Image(systemName: item.icon)
                .foregroundStyle(mode == item ? Color.black : HuntReference.green)
                .frame(width: 36, height: 40)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.rawValue)
    }

    private func hourlyTimeline(_ hours: [WeatherHour]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    ForEach(hours.indices, id: \.self) { index in
                        hourCell(hours[index], first: index == 0)
                    }
                }
                if mode == .wind { hourlyWindTrend(hours) }
            }
        }
    }

    private func hourlyWindTrend(_ hours: [WeatherHour]) -> some View {
        let speeds: [Double?] = hours.map(\.windSpeedKmh)
        let gusts: [Double?] = hours.map(\.windGustKmh)
        let width: CGFloat = CGFloat(hours.count) * 60
        return WeatherTrend(values: speeds, gusts: gusts)
            .frame(width: width, height: 38)
    }

    @ViewBuilder
    private func hourlySelection(_ hours: [WeatherHour]) -> some View {
        if let selected, let hour = hours.first(where: { $0.timestamp == selected }) {
            Text(hourSummary(hour)).font(.caption)
        }
    }

    private func hourSummary(_ hour: WeatherHour) -> String {
        let time = dateText(hour.timestamp, "dd.MM HH:mm")
        let temperature = unit(hour.temperatureC, "°")
        let wind = n(hour.windSpeedKmh) + " км/ч"
        let rain = n(hour.precipitationMm, 1) + " мм"
        return [time, temperature, wind, rain].joined(separator: " · ")
    }

    private func hourCell(_ hour: WeatherHour, first: Bool) -> some View {
        Button { selected = hour.timestamp } label: {
            VStack(spacing: 7) {
                Text(first ? "Сейчас" : dateText(hour.timestamp, "HH")).font(.caption.bold())
                switch mode {
                case .temperature:
                    Image(systemName: WeatherScene(hour.weatherCode).icon(hour.isDay == 0)).font(.title2)
                    Text(unit(hour.precipitationProbabilityPercent, "%")).font(.caption2).foregroundStyle(accent)
                    Text(unit(hour.temperatureC, "°")).font(.subheadline.bold())
                case .rain:
                    WeatherRainBar(value: hour.precipitationMm, maxValue: 5).frame(width: 26, height: 30)
                    Text(n(hour.precipitationMm, 1) + " мм").font(.caption2)
                    Text(unit(hour.precipitationProbabilityPercent, "%")).font(.caption).foregroundStyle(accent)
                case .wind:
                    Text(n(hour.windSpeedKmh)).font(.title3.bold())
                    Text("км/ч").font(.caption2)
                    Text("↑ " + n(hour.windGustKmh)).font(.caption2).foregroundStyle(accent)
                }
            }.frame(width: 60, height: 98)
                .background(selected == hour.timestamp ? HuntReference.green.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func daily(_ date: Date, hours: [WeatherHour], now: Date, minimum: Double, maximum: Double) -> some View {
        let temperatures = hours.compactMap(\.temperatureC)
        let rain = hours.compactMap(\.precipitationMm)
        let wind = hours.compactMap(\.windSpeedKmh)
        let probability = hours.compactMap(\.precipitationProbabilityPercent).max()
        let code = hours.compactMap(\.weatherCode).max()
        return HStack(spacing: 8) {
            Text(calendar.isDate(date, inSameDayAs: now) ? "Сегодня" : dateText(date, "EEE").capitalized).font(.subheadline.bold()).frame(width: 62, alignment: .leading)
            switch mode {
            case .temperature:
                VStack(spacing: 3) {
                    Image(systemName: WeatherScene(code).icon(false))
                    Text(unit(probability, "%")).font(.caption2).foregroundStyle(accent)
                }.frame(width: 32)
                Text(unit(temperatures.min(), "°")).font(.caption).foregroundStyle(HuntReference.muted)
                WeatherTemperatureBand(low: temperatures.min(), high: temperatures.max(), minValue: minimum, maxValue: maximum).frame(height: 8)
                Text(unit(temperatures.max(), "°")).font(.caption.bold())
            case .rain:
                HStack(spacing: 2) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                        WeatherRainBar(value: hour.precipitationMm, maxValue: max(1, rain.max() ?? 1))
                    }
                }.frame(height: 26)
                Text(rain.count == hours.count && !hours.isEmpty ? n(rain.reduce(0, +), 1) + " мм" : "— мм").font(.caption)
                Text(unit(probability, "%")).font(.caption.bold()).foregroundStyle(accent)
            case .wind:
                WeatherTrend(values: hours.map(\.windSpeedKmh), gusts: hours.map(\.windGustKmh)).frame(height: 34)
                Text(n(wind.min()) + "–" + n(wind.max()) + " км/ч").font(.caption.bold())
            }
        }.padding(.vertical, 12)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack { Label(title, systemImage: icon).foregroundStyle(HuntReference.muted); Spacer(); Text(value).fontWeight(.semibold) }.font(.subheadline)
    }
}

private struct WeatherRainBar: View {
    let value: Double?
    let maxValue: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08))
                if let value, value.isFinite, value > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(HuntReference.green)
                        .frame(height: max(2, proxy.size.height * CGFloat(min(1, value / maxValue))))
                }
            }
        }
    }
}
private struct WeatherTemperatureBand: View {
    let low: Double?
    let high: Double?
    let minValue: Double
    let maxValue: Double
    var body: some View {
        GeometryReader { geo in
            let span = max(1, maxValue - minValue)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.2))
                if let low, let high {
                    Capsule().fill(LinearGradient(colors: [HuntReference.green, HuntReference.mint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * CGFloat((high - low) / span)))
                        .offset(x: geo.size.width * CGFloat((low - minValue) / span))
                }
            }
        }.clipped()
    }
}
private struct WeatherTrend: View {
    let values: [Double?]
    let gusts: [Double?]
    var body: some View {
        Canvas { context, size in
            let maximum = max(1, (values + gusts).compactMap { $0 }.max() ?? 1)
            func line(_ data: [Double?]) -> Path {
                var path = Path()
                var started = false
                for (i, v) in data.enumerated() {
                    guard let v, v.isFinite else { started = false; continue }
                    let x = CGFloat(i) / CGFloat(max(1, data.count - 1)) * size.width
                    let y = size.height * CGFloat(1 - min(1, max(0, v / maximum)))
                    let point = CGPoint(x: x, y: y)
                    if started { path.addLine(to: point) } else { path.move(to: point) }
                    started = true
                }
                return path
            }
            context.stroke(line(gusts), with: .color(HuntReference.green.opacity(0.3)), lineWidth: 3)
            context.stroke(line(values), with: .color(HuntReference.green), lineWidth: 2)
        }
    }
}
