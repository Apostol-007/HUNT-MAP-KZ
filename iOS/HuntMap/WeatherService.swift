import Foundation
import HuntCore
import CoreLocation

/// A point forecast, never represented as a spatial weather overlay.
@MainActor final class WeatherService: ObservableObject {
    @Published private(set) var forecast: PointWeather?
    @Published private(set) var busy = false
    @Published private(set) var message = "Прогноз ещё не запрашивался"
    @Published private(set) var isCached = false
    private var task: Task<Void, Never>?
    private let cacheURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("hunt_weather_point.json")
    }()
    private var lastRequest: Date?
    private var lastCoordinate: CLLocationCoordinate2D?

    /// New forecasts replace the persisted snapshot only after a fully decoded response.
    /// Repeated GPS fixes never trigger a network storm.
    func updateIfNeeded(latitude: Double, longitude: Double, force: Bool = false) {
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        if !force, let at = lastRequest, let previous = lastCoordinate,
           Date().timeIntervalSince(at) < 1800,
           CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude)) < 10_000 { return }
        lastRequest = Date()
        lastCoordinate = point
        refresh(latitude: latitude, longitude: longitude, strictOffline: false)
    }

    init() {
        // Migrate the previous URLCache-backed version without losing existing forecasts.
        let oldURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hunt_weather_point.json")
        if !FileManager.default.fileExists(atPath: cacheURL.path),
           let oldData = try? Data(contentsOf: oldURL) {
            try? oldData.write(to: cacheURL, options: .atomic)
        }
        guard let data = try? Data(contentsOf: cacheURL),
              let saved = try? JSONDecoder().decode(PointWeather.self, from: data) else { return }
        forecast = saved
        isCached = true
        message = "Кэш прогноза · получен \(saved.retrievedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func refresh(latitude: Double, longitude: Double, strictOffline: Bool) {
        task?.cancel()
        guard !strictOffline else {
            message = forecast == nil ? "Нет сохранённого прогноза. Отключите строгий офлайн-режим для обновления" : "Офлайн · показан ранее загруженный прогноз"
            return
        }
        guard latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) else {
            message = "Некорректная точка прогноза"
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            self.busy = true
            defer { self.busy = false }
            do {
                var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                url.queryItems = [
                    URLQueryItem(name: "latitude", value: String(latitude)),
                    URLQueryItem(name: "longitude", value: String(longitude)),
                    URLQueryItem(name: "timezone", value: "UTC"),
                    URLQueryItem(name: "forecast_days", value: "7"),
                    URLQueryItem(name: "wind_speed_unit", value: "kmh"),
                    URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,surface_pressure,precipitation"),
                    URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,surface_pressure,precipitation,precipitation_probability")
                ]
                guard let target = url.url else { throw URLError(.badURL) }
                var request = URLRequest(url: target)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode != 200 {
                    AppDiagnosticLog.shared.recordHTTP(subsystem: "Погода",
                        operation: "Почасовой прогноз", code: http.statusCode,
                        responseData: data, path: "/v1/forecast", usedCache: self.forecast != nil)
                    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let reason = String(((payload?["reason"] as? String) ?? "Неверный ответ сервера").prefix(160))
                    throw NSError(domain: "OpenMeteoHTTP", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Open-Meteo HTTP \(http.statusCode): \(reason)"])
                }
                guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let result = try OpenMeteoDecoder.decode(data)
                guard !Task.isCancelled else { return }
                self.forecast = result
                self.isCached = false
                self.message = "Прогноз загружен · Open-Meteo"
                AppDiagnosticLog.shared.record(severity: "info", subsystem: "Погода",
                    operation: "Обновление точечного прогноза", code: "HTTP 200",
                    rootCause: "Данные получены", nextAction: "Не требуется",
                    details: "7 дней прогноза", endpoint: "/v1/forecast")
                if let encoded = try? JSONEncoder().encode(result) {
                    try? encoded.write(to: self.cacheURL, options: [.atomic])
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppDiagnosticLog.shared.recordError(subsystem: "Погода",
                    operation: "Точечный прогноз", error: error,
                    endpoint: "/v1/forecast", usedCache: self.forecast != nil)
                self.message = "Ошибка обновления: \(error.localizedDescription). \(self.forecast == nil ? "Нет данных" : "Показан кэш")"
                self.isCached = self.forecast != nil
            }
        }
    }
}