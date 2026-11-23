import Foundation
import SwiftUI
import HuntCore

/// Forecast GRID, not radar, not a real-time measurement. Sampled 3x3 forecast points.
/// Fetched directly from Open-Meteo; never asks the user to configure a weather server.
enum WeatherMapLayer: String, CaseIterable, Identifiable {
    case none = "Без слоя", wind = "Ветер", pressure = "Давление", precipitation = "Осадки"
    var id: Self { self }
}

struct ForecastGrid: Codable {
    struct Bounds: Codable { let west: Double; let south: Double; let east: Double; let north: Double }
    struct Point: Codable {
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
    private struct OpenMeteoHour: Decodable {
        let time: [String]
        let wind_speed_10m: [Double?]
        let wind_direction_10m: [Double?]
        let pressure_msl: [Double?]
        let precipitation: [Double?]
    }
    private struct OpenMeteoGridPoint: Decodable { let hourly: OpenMeteoHour }

    func load(latitude: Double, longitude: Double, hourOffset: Int, allowNetwork: Bool = true) {
        stop()
        guard latitude.isFinite, longitude.isFinite, (-89...89).contains(latitude),
              (-179...179).contains(longitude), (0...167).contains(hourOffset) else {
            status = "Некорректные координаты или час прогноза"
            return
        }
        chosenOffset = hourOffset
        let baseHour = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
        let utcHour = baseHour.addingTimeInterval(Double(hourOffset) * 3600)
        if let stored = cachedGrid(latitude: latitude, longitude: longitude, target: utcHour) {
            grid = stored; cached = true
            status = "Кеш прогноза · \(stored.forecastTimeUTC)"
        } else {
            // A grid from another hour or another location must never be passed off as current.
            grid = nil; cached = false
        }
        guard allowNetwork else {
            status = grid == nil ? "Нет сохранённого прогноза для выбранного часа" : "Офлайн · сохранённый прогноз"
            return
        }
        // 4x4 actual sampled points over a local bounding box; visual interpolation stays
        // inside this envelope and is not a substitute for mountain-scale observations.
        let half = 0.45, steps = 4
        let west = longitude - half, east = longitude + half
        let south = latitude - half, north = latitude + half
        var coordinates: [(Double, Double)] = []
        for row in 0..<steps {
            for column in 0..<steps {
                coordinates.append((south + (north - south) * Double(row) / Double(steps - 1),
                                    west + (east - west) * Double(column) / Double(steps - 1)))
            }
        }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: coordinates.map { String(format: "%.5f", $0.0) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: coordinates.map { String(format: "%.5f", $0.1) }.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,pressure_msl,precipitation"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "forecast_days", value: "8")
        ]
        guard let url = parts.url else { status = "Ошибка формирования погодного запроса"; return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let hourKey = formatter.string(from: utcHour)
        let shortHour = String(hourKey.prefix(13)) + ":00"
        task = Task { [weak self] in
            guard let self else { return }
            loading = true
            defer { loading = false }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 25
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count < 1_500_000 else { throw URLError(.badServerResponse) }
                let responsePoints = try JSONDecoder().decode([OpenMeteoGridPoint].self, from: data)
                guard responsePoints.count == coordinates.count else { throw URLError(.cannotParseResponse) }
                let samples: [ForecastGrid.Point] = try responsePoints.enumerated().map { index, response in
                    let hours = response.hourly
                    guard let hourIndex = hours.time.firstIndex(of: shortHour),
                          hours.wind_speed_10m.indices.contains(hourIndex),
                          hours.wind_direction_10m.indices.contains(hourIndex),
                          hours.pressure_msl.indices.contains(hourIndex),
                          hours.precipitation.indices.contains(hourIndex) else { throw URLError(.cannotParseResponse) }
                    let position = coordinates[index]
                    return ForecastGrid.Point(latitude: position.0, longitude: position.1,
                        windSpeed: hours.wind_speed_10m[hourIndex],
                        direction: hours.wind_direction_10m[hourIndex],
                        pressure: hours.pressure_msl[hourIndex],
                        precipitation: hours.precipitation[hourIndex])
                }
                let decoded = ForecastGrid(schema: "hunt-weather-grid-v1", kind: "model_forecast_not_radar",
                    forecastTimeUTC: hourKey, gridWidth: steps, gridHeight: steps,
                    bounds: .init(west: west, south: south, east: east, north: north), points: samples)
                guard decoded.validated(), !Task.isCancelled else { throw URLError(.cannotParseResponse) }
                self.grid = decoded
                self.cached = false
                self.status = "Обновлено автоматически · Open-Meteo · \(decoded.forecastTimeUTC)"
                try? JSONEncoder().encode(decoded).write(
                    to: self.cachePath(latitude: latitude, longitude: longitude, target: utcHour), options: .atomic)
            } catch {
                guard !Task.isCancelled else { return }
                self.cached = self.grid != nil
                self.status = self.cached ? "Нет связи · показан сохранённый прогноз" : "Нет данных для выбранного часа: \(error.localizedDescription)"
            }
        }
    }

}