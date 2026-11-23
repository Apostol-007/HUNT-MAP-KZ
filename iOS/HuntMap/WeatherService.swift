import Foundation
import HuntCore

/// A point forecast, never represented as a spatial weather overlay.
@MainActor final class WeatherService: ObservableObject {
    @Published private(set) var forecast: PointWeather?
    @Published private(set) var busy = false
    @Published private(set) var message = "Прогноз ещё не запрашивался"
    @Published private(set) var isCached = false
    private var task: Task<Void, Never>?
    private let cacheURL: URL = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("hunt_weather_point.json")
    }()

    init() {
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
                    URLQueryItem(name: "forecast_days", value: "5"),
                    URLQueryItem(name: "wind_speed_unit", value: "kmh"),
                    URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,surface_pressure,precipitation"),
                    URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,surface_pressure,precipitation,precipitation_probability")
                ]
                guard let target = url.url else { throw URLError(.badURL) }
                var request = URLRequest(url: target)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let result = try OpenMeteoDecoder.decode(data)
                guard !Task.isCancelled else { return }
                self.forecast = result
                self.isCached = false
                self.message = "Прогноз загружен · Open-Meteo"
                if let encoded = try? JSONEncoder().encode(result) {
                    try? encoded.write(to: self.cacheURL, options: [.atomic])
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.message = "Ошибка обновления: \(error.localizedDescription). \(self.forecast == nil ? "Нет данных" : "Показан кэш")"
                self.isCached = self.forecast != nil
            }
        }
    }
}
