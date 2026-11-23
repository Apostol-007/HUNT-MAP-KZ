import Foundation
import SwiftUI
import HuntCore

/// Forecast GRID, not radar, not a real-time measurement. Sampled 3x3 forecast points.
/// Disabled until an operator configures a trusted HTTPS backend serving /v1/weather/grid.
enum WeatherMapLayer: String, CaseIterable, Identifiable {
    case none = "Без слоя", wind = "Ветер", pressure = "Давление", precipitation = "Осадки"
    var id: Self { self }
}

struct ForecastGrid: Decodable {
    struct Bounds: Decodable { let west: Double; let south: Double; let east: Double; let north: Double }
    struct Point: Decodable {
        let latitude: Double
        let longitude: Double
        let windSpeed: Double?
        let direction: Double?
        let pressure: Double?
        let precipitation: Double?
        enum CodingKeys: String, CodingKey {
            case latitude, longitude
            case windSpeed = "wind_speed_10m"
            case direction = "wind_direction_10m"
            case pressure = "pressure_msl"
            case precipitation
        }
    }
    let schema: String
    let kind: String
    let forecastTimeUTC: String
    let gridWidth: Int
    let gridHeight: Int
    let bounds: Bounds
    let points: [Point]
    var forecastDate: Date? { ISO8601DateFormatter().date(from: forecastTimeUTC) }
    enum CodingKeys: String, CodingKey {
        case schema, kind, bounds, points
        case forecastTimeUTC = "forecast_time_utc"
        case gridWidth = "grid_width"
        case gridHeight = "grid_height"
    }
    func validated() -> Bool {
        guard schema == "hunt-weather-grid-v1", kind == "model_forecast_not_radar",
              (2...4).contains(gridWidth), (2...4).contains(gridHeight),
              points.count == gridWidth * gridHeight, forecastDate != nil,
              bounds.west < bounds.east, bounds.south < bounds.north,
              bounds.west >= -180, bounds.east <= 180, bounds.south >= -90, bounds.north <= 90,
              bounds.east - bounds.west <= 3.001, bounds.north - bounds.south <= 3.001 else { return false }
        // Check that every coordinate really matches its declared row/column.
        // Misordered or shifted provider points must not be rendered as a false spatial field.
        for row in 0..<gridHeight {
            for col in 0..<gridWidth {
                let point = points[row * gridWidth + col]
                let expectedLatitude = bounds.south + (bounds.north - bounds.south) * Double(row) / Double(gridHeight - 1)
                let expectedLongitude = bounds.west + (bounds.east - bounds.west) * Double(col) / Double(gridWidth - 1)
                guard abs(point.latitude - expectedLatitude) < 0.0001,
                      abs(point.longitude - expectedLongitude) < 0.0001 else { return false }
            }
        }
        return points.allSatisfy { p in
            p.latitude.isFinite && p.longitude.isFinite &&
            (-90...90).contains(p.latitude) && (-180...180).contains(p.longitude) &&
            [p.windSpeed, p.direction, p.pressure, p.precipitation].allSatisfy { $0 == nil || $0!.isFinite } &&
            (p.windSpeed == nil || p.windSpeed! >= 0) &&
            (p.direction == nil || (0...360).contains(p.direction!)) &&
            (p.pressure == nil || (800...1200).contains(p.pressure!)) &&
            (p.precipitation == nil || p.precipitation! >= 0)
        }
    }
}

@MainActor final class WeatherGridService: ObservableObject {
    @Published private(set) var grid: ForecastGrid?
    @Published private(set) var loading = false
    @Published private(set) var status = "Погодная карта выключена"
    @Published private(set) var cached = false
    @Published private(set) var chosenOffset = 0
    var forecastLabel: String {
        guard let date = grid?.forecastDate else { return "Время прогноза неизвестно" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
    }
    var gridAgeWarning: Bool {
        guard let date = grid?.forecastDate else { return true }
        return date < Date().addingTimeInterval(-3600)
    }
    private var task: Task<Void, Never>?
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("hunt_weather_grid.json")
    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let value = try? JSONDecoder().decode(ForecastGrid.self, from: data), value.validated() {
            grid = value
            cached = true
            status = "Сохранённая сетка прогноза: \(value.forecastTimeUTC) · проверьте актуальность"
        }
    }
    func stop() { task?.cancel(); loading = false }
    func clear() { stop(); grid = nil; cached = false; status = "Погодная карта выключена" }
    func load(server: String, latitude: Double, longitude: Double, hourOffset: Int, strictOffline: Bool) {
        stop()
        chosenOffset = hourOffset
        guard !strictOffline else {
            status = grid == nil ? "Офлайн: сохранённой сетки нет" : "Офлайн: сохранённая сетка, не текущая погода"
            return
        }
        guard latitude.isFinite, longitude.isFinite, (-89...89).contains(latitude), (-179...179).contains(longitude),
              (0...48).contains(hourOffset) else { status = "Некорректные координаты или час прогноза"; return }
        guard let base = URL(string: server), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil else {
            status = "Укажи HTTPS-адрес своего сервера погоды"; return
        }
        // The backend enforces bbox <= 3 degrees, 3x3 sampling and upstream quotas.
        let halfSize = 0.45
        let url = base.appendingPathComponent("v1/weather/grid")
        let utcHour = Calendar(identifier: .gregorian).date(byAdding: .hour, value: hourOffset,
            to: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)) ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bbox", value: "\(longitude-halfSize),\(latitude-halfSize),\(longitude+halfSize),\(latitude+halfSize)"),
            URLQueryItem(name: "at", value: formatter.string(from: utcHour)),
            URLQueryItem(name: "steps", value: "4")
        ]
        guard let target = components.url else { status = "Ошибка адреса погодной карты"; return }
        task = Task { [weak self] in
            guard let self else { return }
            self.loading = true
            defer { self.loading = false }
            do {
                var request = URLRequest(url: target)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count < 200_000 else { throw URLError(.badServerResponse) }
                let decoded = try JSONDecoder().decode(ForecastGrid.self, from: data)
                guard decoded.validated(), let forecastDate = decoded.forecastDate,
                      abs(forecastDate.timeIntervalSince(utcHour)) < 60 else {
                    throw URLError(.cannotParseResponse)
                }
                guard !Task.isCancelled else { return }
                self.grid = decoded
                self.cached = false
                self.status = "Модельный прогноз Open-Meteo · \(decoded.forecastTimeUTC) (не радар)"
                try? data.write(to: self.cacheURL, options: .atomic)
            } catch {
                guard !Task.isCancelled else { return }
                self.cached = self.grid != nil
                self.status = "Сетка недоступна: \(error.localizedDescription)" + (self.cached ? " · показан кэш" : "")
            }
        }
    }
}
