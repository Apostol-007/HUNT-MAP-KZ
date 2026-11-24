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
    private var lastFailedKey = ""
    private var lastFailedAt = Date.distantPast
    private let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HuntWeatherGrids", isDirectory: true)

    private struct ProviderFailure: LocalizedError {
        let code: Int
        let reason: String
        var errorDescription: String? { "Open-Meteo HTTP \(code): \(reason)" }
    }
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
        var width: Int = 6
        var height: Int = 4
        var bbox: ForecastGrid.Bounds { .init(west: west, south: south, east: east, north: north) }
        var key: String { "\(Int(west * 100))_\(Int(south * 100))_\(Int(east * 100))_\(Int(north * 100))_\(width)x\(height)" }
    }
    init() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let directory = cacheDirectory
        // Cache retention is disk housekeeping, not launch-critical work.
        Task.detached(priority: .background) { Self.pruneCache(directory) }
    }

    nonisolated private static func pruneCache(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let candidates = files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("v2_")
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in candidates.dropFirst(256) {
            try? FileManager.default.removeItem(at: file)
        }
    }

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
    /// Retain the latest successfully saved forecast when the requested hour is not cached.
    /// A stale forecast is explicitly labelled; it is never presented as current weather.
    private func latestCachedGrid(region: Region) -> ForecastGrid? {
        let prefix = "v2_\(region.key)_"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil) else { return nil }
        var latest: (Date, ForecastGrid)?
        // Never decode every historic hourly grid on the main actor.
        // Filenames end in an epoch-hour suffix, so descending order picks
        // the newest cached forecast with a bounded number of file reads.
        let recentFiles = files.filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json"
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(8)
        for file in recentFiles {
            guard let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(ForecastGrid.self, from: data),
                  value.validated(), let date = value.forecastDate else { continue }
            if latest == nil || date > latest!.0 { latest = (date, value) }
        }
        return latest?.1
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
    /// Starts with a 3x3 request, then refines to 6x4 asynchronously.
    /// A forecast is model data, not real-time sensor measurements.
    private func fetchGrid(region: Region, at date: Date) async throws -> ForecastGrid {
        var points: [(Double, Double)] = []
        points.reserveCapacity(region.width * region.height)
        let latStep = (region.north - region.south) / Double(region.height - 1)
        let lonStep = (region.east - region.west) / Double(region.width - 1)
        for row in 0..<region.height {
            for column in 0..<region.width {
                points.append((region.south + Double(row) * latStep,
                               region.west + Double(column) * lonStep))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let timestamp = iso.string(from: date)
        let targetHour = String(timestamp.prefix(13)) + ":00"
        let slices = stride(from: 0, to: points.count, by: 24).map {
            Array(points[$0..<min($0 + 24, points.count)])
        }
        let arrays = try await withThrowingTaskGroup(of: (Int, [OpenMeteoGridPoint]).self) { group in
            for (index, batch) in slices.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                    url.queryItems = [
                        URLQueryItem(name: "latitude", value: batch.map { String(format: "%.5f", $0.0) }.joined(separator: ",")),
                        URLQueryItem(name: "longitude", value: batch.map { String(format: "%.5f", $0.1) }.joined(separator: ",")),
                        URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,pressure_msl,precipitation"),
                        URLQueryItem(name: "timezone", value: "UTC"),
                        URLQueryItem(name: "wind_speed_unit", value: "kmh"),
                        URLQueryItem(name: "start_hour", value: targetHour),
                        URLQueryItem(name: "end_hour", value: targetHour)
                    ]
                    guard let endpoint = url.url else { throw URLError(.badURL) }
                    var request = URLRequest(url: endpoint)
                    request.timeoutInterval = 16
                    var (data, response) = try await URLSession.shared.data(for: request)
                    guard var http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if http.statusCode == 400 {
                        // Some provider versions reject explicit start_hour/end_hour.
                        // Fall back to the full UTC forecast, but never mix the two
                        // mutually exclusive ways of choosing a time range.
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let reason = (json?["reason"] as? String ?? "").lowercased()
                        if reason.contains("start_hour") || reason.contains("end_hour") ||
                           reason.contains("forecast_days") {
                            var fallback = url
                            fallback.queryItems?.removeAll {
                                $0.name == "start_hour" || $0.name == "end_hour"
                            }
                            fallback.queryItems?.append(URLQueryItem(name: "forecast_days", value: "8"))
                            guard let fallbackURL = fallback.url else { throw URLError(.badURL) }
                            var retry = URLRequest(url: fallbackURL)
                            retry.timeoutInterval = 20
                            (data, response) = try await URLSession.shared.data(for: retry)
                            guard let fallbackHTTP = response as? HTTPURLResponse else {
                                throw URLError(.badServerResponse)
                            }
                            http = fallbackHTTP
                        }
                    }
                    if http.statusCode != 200 {
                        await AppDiagnosticLog.shared.recordHTTP(
                            subsystem: "Погода", operation: "Сетка Open-Meteo",
                            code: http.statusCode, responseData: data,
                            path: "/v1/forecast", usedCache: false)
                        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let reason = String(((json?["reason"] as? String) ?? "Ответ провайдера отклонён").prefix(180))
                        throw ProviderFailure(code: http.statusCode, reason: reason)
                    }
                    guard data.count < 2_000_000 else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    let result = try JSONDecoder().decode([OpenMeteoGridPoint].self, from: data)
                    guard result.count == batch.count else { throw URLError(.cannotParseResponse) }
                    return (index, result)
                }
            }
            var ordered = Array(repeating: [OpenMeteoGridPoint](), count: slices.count)
            for try await (index, result) in group { ordered[index] = result }
            return ordered.flatMap { $0 }
        }
        var samples: [ForecastGrid.Point] = []
        samples.reserveCapacity(points.count)
        for index in points.indices {
            let hour = arrays[index].hourly
            guard let hourIndex = hour.time.firstIndex(of: targetHour),
                  hour.wind_speed_10m.indices.contains(hourIndex),
                  hour.wind_direction_10m.indices.contains(hourIndex),
                  hour.pressure_msl.indices.contains(hourIndex),
                  hour.precipitation.indices.contains(hourIndex) else { throw URLError(.cannotParseResponse) }
            samples.append(ForecastGrid.Point(latitude: points[index].0, longitude: points[index].1,
                windSpeed: hour.wind_speed_10m[hourIndex], direction: hour.wind_direction_10m[hourIndex],
                pressure: hour.pressure_msl[hourIndex], precipitation: hour.precipitation[hourIndex]))
        }
        let value = ForecastGrid(schema: "hunt-weather-grid-v1", kind: "model_forecast_not_radar",
                                 forecastTimeUTC: timestamp, gridWidth: region.width,
                                 gridHeight: region.height, bounds: region.bbox, points: samples)
        guard value.validated() else { throw URLError(.cannotParseResponse) }
        return value
    }

    func load(hourOffset: Int, allowNetwork: Bool = true) {
        guard (0...167).contains(hourOffset) else { return }
        chosenOffset = hourOffset
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
            .addingTimeInterval(TimeInterval(hourOffset * 3600))
        let detailed = regionForViewport()
        var coarse = detailed
        coarse.width = 3
        coarse.height = 3
        let key = detailed.key + ":" + String(Int(date.timeIntervalSince1970 / 3600))
        if loading && lastRequestedKey == key { return }
        // Avoid hammering the provider on every SwiftUI redraw after a temporary error.
        if lastFailedKey == key && Date().timeIntervalSince(lastFailedAt) < 40 { return }
        if !loading && lastRequestedKey == key && !cached &&
           Date().timeIntervalSince(lastSuccessfulRefresh) < 900 { return }
        stop()
        lastRequestedKey = key
        if let detailedCache = cachedGrid(region: detailed, date: date) {
            grid = detailedCache
            cached = true
            status = "Кеш подробного прогноза · обновляем в сети"
        } else if let coarseCache = cachedGrid(region: coarse, date: date) {
            grid = coarseCache
            cached = true
            status = "Кеш быстрого прогноза · уточняем"
        } else if let previous = grid, let previousTime = previous.forecastDate,
                  abs(previousTime.timeIntervalSince(date)) < 60,
                  previous.bounds.west < detailed.east,
                  previous.bounds.east > detailed.west,
                  previous.bounds.south < detailed.north,
                  previous.bounds.north > detailed.south {
            // Show the overlapping previous region while new viewport data arrives.
            cached = true
            status = "Предыдущий участок виден · обновляем новую область"
        } else if let saved = latestCachedGrid(region: detailed) ?? latestCachedGrid(region: coarse) {
            grid = saved
            cached = true
            status = "Сохранённый прогноз за \(saved.forecastTimeUTC) · обновляем"
        } else {
            grid = nil
            cached = false
        }
        guard allowNetwork else {
            status = cached ? "Офлайн · сохранённый прогноз" : "Нет прогноза для этого района и часа"
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            self.loading = true
            defer { self.loading = false }
            do {
                // Replace a stale fallback immediately with the correct target hour.
                let currentHourAvailable = self.grid?.forecastDate.map { abs($0.timeIntervalSince(date)) < 60 } ?? false
                if !currentHourAvailable {
                    let value = try await self.fetchGrid(region: coarse, at: date)
                    guard !Task.isCancelled, self.lastRequestedKey == key else { return }
                    self.grid = value
                    self.cached = false
                    self.status = "Ветер отображается · уточняем детализацию…"
                    try? JSONEncoder().encode(value).write(to: self.cachePath(region: coarse, date: date), options: .atomic)
                }
                let value = try await self.fetchGrid(region: detailed, at: date)
                guard !Task.isCancelled, self.lastRequestedKey == key else { return }
                self.grid = value
                self.cached = false
                self.lastSuccessfulRefresh = Date()
                self.lastFailedKey = ""
                AppDiagnosticLog.shared.record(severity: "info", subsystem: "Погода",
                    operation: "Обновление погодной сетки", code: "HTTP 200",
                    rootCause: "Прогноз получен и сохранён",
                    nextAction: "Не требуется",
                    details: "Detailed grid: \(detailed.width)x\(detailed.height); time: \(value.forecastTimeUTC)",
                    endpoint: "/v1/forecast")
                self.status = "Прогноз обновлён · Open-Meteo · \(value.forecastTimeUTC)"
                try? JSONEncoder().encode(value).write(to: self.cachePath(region: detailed, date: date), options: .atomic)
            } catch {
                guard !Task.isCancelled, self.lastRequestedKey == key else { return }
                self.cached = self.grid != nil
                self.lastFailedKey = key
                self.lastFailedAt = Date()
                AppDiagnosticLog.shared.recordError(subsystem: "Погода",
                    operation: "Загрузка карты ветра", error: error,
                    endpoint: "/v1/forecast", usedCache: self.grid != nil)
                self.status = self.grid == nil
                    ? "Прогноз недоступен: \(error.localizedDescription)"
                    : "Отображается полученный прогноз · подробная сетка недоступна"
            }
        }
    }
}
