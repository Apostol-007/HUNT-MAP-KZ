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
              (2...16).contains(gridWidth), (2...16).contains(gridHeight),
              points.count == gridWidth * gridHeight, forecastDate != nil,
              bounds.west < bounds.east, bounds.south < bounds.north,
              bounds.west >= -180, bounds.east <= 180, bounds.south >= -90, bounds.north <= 90,
              bounds.east - bounds.west <= 50.0, bounds.north - bounds.south <= 22.0 else { return false }
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
    private var viewportTask: Task<Void, Never>?
    private var visibleBounds: [Double] = [46, 40, 88, 56]
    private var lastRequestedKey = ""
    private var lastSuccessfulRefresh = Date.distantPast
    private let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HuntWeatherGrids", isDirectory: true)

    private struct OpenMeteoHour: Decodable {
        let time: [String]
        let wind_speed_10m: [Double?]
        let wind_direction_10m: [Double?]
        let pressure_msl: [Double?]
        let precipitation: [Double?]
    }
    private struct OpenMeteoGridPoint: Decodable { let hourly: OpenMeteoHour }
    private struct Region {
        var west: Double
        var south: Double
        var east: Double
        var north: Double
        var width: Int = 12
        var height: Int = 8
        var bbox: ForecastGrid.Bounds { .init(west: west, south: south, east: east, north: north) }
        var key: String { "\(Int(west * 100))_\(Int(south * 100))_\(Int(east * 100))_\(Int(north * 100))" }
    }
    init() { try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) }

    private func regionForViewport() -> Region {
        // Entire Kazakhstan in overview zoom. Intermediate/close zooms use the actual camera
        // viewport; weather therefore stays aligned with map scale instead of GPS position.
        let v = visibleBounds
        guard v.count == 4, v.allSatisfy({ $0.isFinite }), v[2] > v[0], v[3] > v[1] else {
            return Region(west: 46, south: 40, east: 88, north: 56)
        }
        let dx = v[2] - v[0], dy = v[3] - v[1]
        if dx >= 11 || dy >= 6 {
            return Region(west: 46, south: 40, east: 88, north: 56)
        }
        let mx = max(0.08, dx * 0.35), my = max(0.07, dy * 0.35)
        // Snap to stable steps so a small pan doesn't invalidate every local cache.
        let step = dx > 2 ? 0.5 : dx > 0.4 ? 0.1 : 0.025
        func down(_ a: Double) -> Double { floor(a / step) * step }
        func up(_ a: Double) -> Double { ceil(a / step) * step }
        let west = max(46, down(v[0] - mx)), east = min(88, up(v[2] + mx))
        let south = max(40, down(v[1] - my)), north = min(56, up(v[3] + my))
        guard east - west >= 0.02, north - south >= 0.02 else {
            return Region(west: 46, south: 40, east: 88, north: 56)
        }
        return Region(west: west, south: south, east: east, north: north)
    }
    private func cachePath(region: Region, date: Date) -> URL {
        cacheDirectory.appendingPathComponent("v2_\(region.key)_\(Int(date.timeIntervalSince1970 / 3600)).json")
    }
    private func cachedGrid(region: Region, date: Date) -> ForecastGrid? {
        let file = cachePath(region: region, date: date)
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(ForecastGrid.self, from: data),
              value.validated(), let time = value.forecastDate,
              abs(time.timeIntervalSince(date)) < 60 else { return nil }
        return value
    }
    func stop() {
        task?.cancel()
        loading = false
    }
    func clear() {
        stop()
        grid = nil; cached = false; status = "Погодная карта выключена"
        lastRequestedKey = ""
    }
    func updateViewport(_ bounds: [Double], active: Bool) {
        guard bounds.count == 4, bounds.allSatisfy({ $0.isFinite }),
              bounds[0] < bounds[2], bounds[1] < bounds[3] else { return }
        let old = regionForViewport().key
        visibleBounds = bounds
        guard active, regionForViewport().key != old else { return }
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.load(hourOffset: self.chosenOffset)
        }
    }
    func load(latitude: Double = 48, longitude: Double = 70, hourOffset: Int, allowNetwork: Bool = true) {
        load(hourOffset: hourOffset, allowNetwork: allowNetwork)
    }
    func load(hourOffset: Int, allowNetwork: Bool = true) {
        guard (0...167).contains(hourOffset) else { return }
        chosenOffset = hourOffset
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
            .addingTimeInterval(TimeInterval(hourOffset * 3600))
        let region = regionForViewport()
        let key = region.key + ":" + String(Int(date.timeIntervalSince1970 / 3600))
        // Avoid restarting an identical in-flight request due to SwiftUI rerenders.
        if loading && lastRequestedKey == key { return }
        if !loading && lastRequestedKey == key && !cached &&
            Date().timeIntervalSince(lastSuccessfulRefresh) < 900 { return }
        stop()
        lastRequestedKey = key
        if let saved = cachedGrid(region: region, date: date) {
            grid = saved; cached = true
            status = "Кеш прогноза: \(saved.forecastTimeUTC)"
        } else {
            grid = nil; cached = false
        }
        guard allowNetwork else {
            status = cached ? "Офлайн · сохранённая погодная карта" : "Нет сохранённой сетки для этого времени и масштаба"
            return
        }
        let points: [(Double, Double)] = (0..<region.height).flatMap { row in
            (0..<region.width).map { col in
                (region.south + (region.north - region.south) * Double(row) / Double(region.height - 1),
                 region.west + (region.east - region.west) * Double(col) / Double(region.width - 1))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let targetHour = String(iso.string(from: date).prefix(13)) + ":00"
        let timestamp = iso.string(from: date)
        task = Task { [weak self] in
            guard let self else { return }
            self.loading = true
            self.status = self.cached ? "Обновление погодной карты… показан кеш" : "Загружаю ветер по всей видимой области…"
            defer { self.loading = false }
            do {
                // Only the chosen forecast hour is downloaded. Batches keep URL/request sizes small.
                let slices = stride(from: 0, to: points.count, by: 24).map {
                    Array(points[$0..<min($0 + 24, points.count)])
                }
                let arrays = try await withThrowingTaskGroup(of: (Int, [OpenMeteoGridPoint]).self) { group in
                    for (i, batch) in slices.enumerated() {
                        group.addTask {
                            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                            url.queryItems = [
                                URLQueryItem(name: "latitude", value: batch.map { String(format: "%.5f", $0.0) }.joined(separator: ",")),
                                URLQueryItem(name: "longitude", value: batch.map { String(format: "%.5f", $0.1) }.joined(separator: ",")),
                                URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,pressure_msl,precipitation"),
                                URLQueryItem(name: "timezone", value: "UTC"),
                                URLQueryItem(name: "wind_speed_unit", value: "kmh"),
                                URLQueryItem(name: "forecast_days", value: "8"),
                                URLQueryItem(name: "start_hour", value: targetHour),
                                URLQueryItem(name: "end_hour", value: targetHour)
                            ]
                            guard let endpoint = url.url else { throw URLError(.badURL) }
                            var request = URLRequest(url: endpoint)
                            request.timeoutInterval = 22
                            let (data, response) = try await URLSession.shared.data(for: request)
                            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                                  data.count < 500_000 else { throw URLError(.badServerResponse) }
                            let result = try JSONDecoder().decode([OpenMeteoGridPoint].self, from: data)
                            guard result.count == batch.count else { throw URLError(.cannotParseResponse) }
                            return (i, result)
                        }
                    }
                    var all = Array(repeating: [OpenMeteoGridPoint](), count: slices.count)
                    for try await (index, result) in group { all[index] = result }
                    return all.flatMap { $0 }
                }
                let samples: [ForecastGrid.Point] = try arrays.enumerated().map { index, response in
                    let hour = response.hourly
                    guard let hourIndex = hour.time.firstIndex(of: targetHour),
                          hour.wind_speed_10m.indices.contains(hourIndex),
                          hour.wind_direction_10m.indices.contains(hourIndex),
                          hour.pressure_msl.indices.contains(hourIndex),
                          hour.precipitation.indices.contains(hourIndex) else { throw URLError(.cannotParseResponse) }
                    return ForecastGrid.Point(latitude: points[index].0, longitude: points[index].1,
                        windSpeed: hour.wind_speed_10m[hourIndex],
                        direction: hour.wind_direction_10m[hourIndex],
                        pressure: hour.pressure_msl[hourIndex],
                        precipitation: hour.precipitation[hourIndex])
                }
                let value = ForecastGrid(schema: "hunt-weather-grid-v1", kind: "model_forecast_not_radar",
                    forecastTimeUTC: timestamp, gridWidth: region.width, gridHeight: region.height,
                    bounds: region.bbox, points: samples)
                guard value.validated(), !Task.isCancelled, self.lastRequestedKey == key else { return }
                self.grid = value
                self.cached = false
                self.lastSuccessfulRefresh = Date()
                self.status = "Прогноз Open-Meteo · вся видимая область · \(targetHour) UTC"
                try? JSONEncoder().encode(value).write(to: self.cachePath(region: region, date: date), options: .atomic)
            } catch {
                guard !Task.isCancelled else { return }
                self.cached = self.grid != nil
                self.status = self.cached ? "Сеть недоступна: сохранённый прогноз" : "Не удалось загрузить погодную сетку: \(error.localizedDescription)"
            }
        }
    }

}