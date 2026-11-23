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
    private let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HuntWeatherGrids", isDirectory: true)
    private func cachePath(latitude: Double, longitude: Double, target: Date) -> URL {
        let latitudeBucket = Int((latitude * 10).rounded())
        let longitudeBucket = Int((longitude * 10).rounded())
        let hour = Int(target.timeIntervalSince1970 / 3600)
        return cacheDirectory.appendingPathComponent("grid_\(latitudeBucket)_\(longitudeBucket)_\(hour).json")
    }
    private func cachedGrid(latitude: Double, longitude: Double, target: Date) -> ForecastGrid? {
        let file = cachePath(latitude: latitude, longitude: longitude, target: target)
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(ForecastGrid.self, from: data), decoded.validated(),
              let time = decoded.forecastDate, abs(time.timeIntervalSince(target)) < 60,
              abs((decoded.bounds.west + decoded.bounds.east) / 2 - longitude) < 0.06,
              abs((decoded.bounds.south + decoded.bounds.north) / 2 - latitude) < 0.06 else { return nil }
        return decoded
    }
    init() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    func stop() { task?.cancel(); loading = false }
    func clear() { stop(); grid = nil; cached = false; status = "Погодная карта выключена" }
    func load(server: String, latitude: Double, longitude: Double, hourOffset: Int, strictOffline: Bool) {
        stop()
        guard latitude.isFinite, longitude.isFinite, (-89...89).contains(latitude), (-179...179).contains(longitude),
              (0...167).contains(hourOffset) else { status = "Некорректные координаты или час прогноза"; return }
        chosenOffset = hourOffset
        let baseHour = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
        let utcHour = baseHour.addingTimeInterval(Double(hourOffset) * 3600)
        // Never reuse a forecast for a different hour or a different map location.
        if let stored = cachedGrid(latitude: latitude, longitude: longitude, target: utcHour) {
            grid = stored
            cached = true
            status = "Кэш · \(stored.forecastTimeUTC)"
        } else {
            grid = nil
            cached = false
        }
        guard !strictOffline else {
            status = grid == nil ? "Офлайн: для выбранного часа нет данных" : "Офлайн: сохранённый прогноз · проверьте актуальность"
            return
        }
        guard let base = URL(string: server), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil else {
            status = grid == nil ? "Укажи HTTPS-адрес своего сервера погоды" : "Показан локальный кэш"
            return
        }
        let halfSize = 0.45
        let url = base.appendingPathComponent("v1/weather/grid")
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
                self.status = "Модельный прогноз · \(decoded.forecastTimeUTC)"
                try? data.write(to: self.cachePath(latitude: latitude, longitude: longitude, target: utcHour), options: .atomic)
            } catch {
                guard !Task.isCancelled else { return }
                self.cached = self.grid != nil
                self.status = "Сетка недоступна: \(error.localizedDescription)" + (self.cached ? " · показан кэш" : "")
            }
        }
    }

}