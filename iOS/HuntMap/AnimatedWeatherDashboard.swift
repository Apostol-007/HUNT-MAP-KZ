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
        switch self {
        case .sun: return night ? [Color(hex: "#101C38"), Color(hex: "#253958")] : [Color(hex: "#2879AF"), Color(hex: "#76BED7")]
        case .snow: return [Color(hex: "#658198"), Color(hex: "#283F55")]
        case .fog: return [Color(hex: "#657783"), Color(hex: "#293C48")]
        case .storm: return [Color(hex: "#353950"), Color(hex: "#121D32")]
        default: return [Color(hex: "#3B5068"), Color(hex: "#1B2C40")]
        }
    }
}

private struct SkyMotion: View {
    let scene: WeatherScene
    let night: Bool
    let windy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            LinearGradient(colors: scene.colors(night), startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || phase != .active)) { timeline in
                Canvas { context, size in
                    let t = reduceMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                    let w = Double(size.width)
                    let h = Double(size.height)
                    guard w > 0, h > 0 else { return }
                    if scene == .sun {
                        let r = w * (0.24 + 0.015 * sin(t))
                        let point = CGPoint(x: w * 0.77, y: h * 0.12)
                        let glow = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                        context.fill(glow, with: .radialGradient(Gradient(colors: [night ? Color.white.opacity(0.5) : Color.yellow.opacity(0.6), .clear]), center: point, startRadius: 0, endRadius: r))
                        if night {
                            for i in 0..<35 {
                                let x = Double((i * 137 + 19) % 997) / 997 * w
                                let y = Double((i * 91 + 43) % 997) / 997 * h
                                let opacity = 0.2 + 0.4 * (1 + sin(t + Double(i))) / 2
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(opacity)))
                            }
                        }
                    } else if scene != .unknown {
                        for i in 0..<10 {
                            let x = (Double(i) * w / 4 + t * 6).truncatingRemainder(dividingBy: w * 2) - w * 0.45
                            let y = Double(i % 5) * h / 5
                            let r = w * 0.7
                            let cloud = Path(ellipseIn: CGRect(x: x-r, y: y-r*0.5, width: r*2, height: r))
                            context.fill(cloud, with: .radialGradient(Gradient(colors: [.white.opacity(scene == .fog ? 0.23 : 0.12), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                        }
                    }
                    let snow = scene == .snow
                    let wet = scene == .rain || scene == .storm
                    if wet || snow || windy {
                        let count = snow ? 80 : (wet ? 130 : 32)
                        for i in 0..<count {
                            let seed = Double((i * 173 + 31) % 997) / 997
                            let offset = Double((i * 71 + 17) % 991) / 991
                            let speed = snow ? 20 + seed * 25 : 150 + seed * 180
                            let y = (offset * h + t * speed).truncatingRemainder(dividingBy: h + 24) - 12
                            let x = (seed * w + t * (windy ? 28 : 8)).truncatingRemainder(dividingBy: w)
                            if snow {
                                let r = 1 + seed * 2
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r*2, height: r*2)), with: .color(.white.opacity(0.48)))
                            } else {
                                var line = Path()
                                line.move(to: CGPoint(x: x, y: y))
                                line.addLine(to: CGPoint(x: x - (wet ? 4 : 18), y: y + (wet ? 10 + seed*15 : 2)))
                                context.stroke(line, with: .color(.white.opacity(0.12 + seed*0.17)), lineWidth: 1)
                            }
                        }
                    }
                    if scene == .storm && !reduceMotion {
                        let flash = max(0, 1 - abs(t.truncatingRemainder(dividingBy: 14) - 1.5) / 0.8) * 0.08
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(flash)))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AnimatedWeatherDashboard: View {
    @ObservedObject var service: WeatherService
    let coordinate: GeoPoint?
    let onMap: (WeatherMapLayer) -> Void
    let onDetails: () -> Void
    @State private var mode = ForecastMode.temperature
    @State private var selected: Date?
    private let cyan = Color(hex: "#58CDE7")
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
            .background(Color(hex: "#293E55").opacity(0.88), in: RoundedRectangle(cornerRadius: 19))
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
            VStack(spacing: 6) {
                Label("ПОГОДА ПО GPS", systemImage: "location.fill").font(.caption.bold())
                Text(String(format: "%.3f°, %.3f°", weather.latitude, weather.longitude)).font(.headline)
                Text(unit(weather.temperatureC, "°")).font(.system(size: 88, weight: .ultraLight)).monospacedDigit()
                Text(scene.name).font(.title3.bold())
                Text("Макс.: " + unit(today.compactMap(\.temperatureC).max(), "°") + " · мин.: " + unit(today.compactMap(\.temperatureC).min(), "°")).font(.subheadline)
                if service.isCached || Date().timeIntervalSince(weather.retrievedAt) > 10800 {
                    Label("Сохранённый прогноз", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.yellow)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
            hourly(upcoming)
            surface {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ПРОГНОЗ ПО ДНЯМ").font(.caption.bold()).foregroundStyle(.white.opacity(0.65))
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
            Text("Open-Meteo · UTC+5 · " + dateText(weather.retrievedAt, "dd.MM HH:mm")).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }.padding(12)
        .background { SkyMotion(scene: scene, night: weather.current.isDay == 0, windy: (weather.current.windSpeedKmh ?? 0) >= 25).clipShape(RoundedRectangle(cornerRadius: 24)) }
    }
    private func hourly(_ hours: [WeatherHour]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            hourlyHeading
            hourlyTimeline(hours)
            hourlySelection(hours)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#293E55").opacity(0.88), in: RoundedRectangle(cornerRadius: 19))
    }

    private var hourlyHeading: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.rawValue).font(.headline)
                Text(mode.subtitle).font(.caption2).foregroundStyle(Color.white.opacity(0.75))
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
        .background(Color.black.opacity(0.14), in: Capsule())
    }

    private func modeButton(_ item: ForecastMode) -> some View {
        let fill: Color = mode == item ? Color.white.opacity(0.18) : Color.clear
        return Button { mode = item } label: {
            Image(systemName: item.icon)
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
                    Text(unit(hour.precipitationProbabilityPercent, "%")).font(.caption2).foregroundStyle(cyan)
                    Text(unit(hour.temperatureC, "°")).font(.subheadline.bold())
                case .rain:
                    WeatherRainBar(value: hour.precipitationMm, maxValue: 5).frame(width: 26, height: 30)
                    Text(n(hour.precipitationMm, 1) + " мм").font(.caption2)
                    Text(unit(hour.precipitationProbabilityPercent, "%")).font(.caption).foregroundStyle(cyan)
                case .wind:
                    Text(n(hour.windSpeedKmh)).font(.title3.bold())
                    Text("км/ч").font(.caption2)
                    Text("↑ " + n(hour.windGustKmh)).font(.caption2).foregroundStyle(cyan)
                }
            }.frame(width: 60, height: 98)
                .background(selected == hour.timestamp ? Color.white.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
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
                    Text(unit(probability, "%")).font(.caption2).foregroundStyle(cyan)
                }.frame(width: 32)
                Text(unit(temperatures.min(), "°")).font(.caption).foregroundStyle(.white.opacity(0.65))
                WeatherTemperatureBand(low: temperatures.min(), high: temperatures.max(), minValue: minimum, maxValue: maximum).frame(height: 8)
                Text(unit(temperatures.max(), "°")).font(.caption.bold())
            case .rain:
                HStack(spacing: 2) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                        WeatherRainBar(value: hour.precipitationMm, maxValue: max(1, rain.max() ?? 1))
                    }
                }.frame(height: 26)
                Text(rain.count == hours.count && !hours.isEmpty ? n(rain.reduce(0, +), 1) + " мм" : "— мм").font(.caption)
                Text(unit(probability, "%")).font(.caption.bold()).foregroundStyle(cyan)
            case .wind:
                WeatherTrend(values: hours.map(\.windSpeedKmh), gusts: hours.map(\.windGustKmh)).frame(height: 34)
                Text(n(wind.min()) + "–" + n(wind.max()) + " км/ч").font(.caption.bold())
            }
        }.padding(.vertical, 12)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack { Label(title, systemImage: icon).foregroundStyle(.white.opacity(0.75)); Spacer(); Text(value).fontWeight(.semibold) }.font(.subheadline)
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
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#58CDE7"))
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
                    Capsule().fill(LinearGradient(colors: [Color(hex: "#58CDE7"), Color(hex: "#A3D68B")], startPoint: .leading, endPoint: .trailing))
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
            context.stroke(line(gusts), with: .color(Color(hex: "#58CDE7").opacity(0.3)), lineWidth: 3)
            context.stroke(line(values), with: .color(Color(hex: "#58CDE7")), lineWidth: 2)
        }
    }
}
