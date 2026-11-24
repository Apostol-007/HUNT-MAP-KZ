import Foundation

/// Forecast values are provider model estimates, not direct on-site measurements.
public struct WeatherHour: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let windSpeedKmh: Double?
    public let windDirectionFromDegrees: Double?
    public let windGustKmh: Double?
    public let pressureMSLHpa: Double?
    public let surfacePressureHpa: Double?
    public let precipitationMm: Double?
    public let precipitationProbabilityPercent: Double?

    public var temperatureC: Double? = nil
    public var weatherCode: Int? = nil
    public var isDay: Int? = nil

    public var windDirectionToDegrees: Double? {
        windDirectionFromDegrees.map { WeatherMath.normalizeDirection($0 + 180) }
    }
}

public struct PointWeather: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let retrievedAt: Date
    public let source: String
    public let temperatureC: Double?
    public let apparentTemperatureC: Double?
    public let humidityPercent: Double?
    public let current: WeatherHour
    public let hourly: [WeatherHour]
}

public enum WeatherMath {
    public static func normalizeDirection(_ angle: Double) -> Double {
        let result = angle.truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }
    public static func mmHg(_ pressureHpa: Double) -> Double {
        pressureHpa * 0.750061683
    }
}

public enum WeatherDecodeError: Error, Equatable {
    case invalidResponse, inconsistentHourlyArrays, emptyForecast, nonUTCInput
}

/// Open-Meteo request must explicitly use timezone=UTC, so local-time ambiguity
/// never enters the forecast timeline. Null values remain nil, never zero.
public enum OpenMeteoDecoder {
    private struct Payload: Decodable {
        let latitude: Double
        let longitude: Double
        let timezone: String
        let current: Current
        let hourly: Hourly
    }
    private struct Current: Decodable {
        let time: String
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let relative_humidity_2m: Double?
        let wind_speed_10m: Double?
        let wind_direction_10m: Double?
        let wind_gusts_10m: Double?
        let pressure_msl: Double?
        let surface_pressure: Double?
        let precipitation: Double?
        let weather_code: Int?
        let is_day: Int?
    }
    private struct Hourly: Decodable {
        let time: [String]
        let wind_speed_10m: [Double?]
        let wind_direction_10m: [Double?]
        let wind_gusts_10m: [Double?]
        let pressure_msl: [Double?]
        let surface_pressure: [Double?]
        let precipitation: [Double?]
        let precipitation_probability: [Double?]
        let temperature_2m: [Double?]?
        let weather_code: [Int?]?
        let is_day: [Int?]?
    }
    private static func parseUTC(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value + ":00Z")
    }

    public static func decode(_ data: Data, retrievedAt: Date = Date()) throws -> PointWeather {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.timezone == "GMT" || payload.timezone == "UTC" else { throw WeatherDecodeError.nonUTCInput }
        let h = payload.hourly
        let count = h.time.count
        guard count > 0 else { throw WeatherDecodeError.emptyForecast }
        guard [h.wind_speed_10m.count, h.wind_direction_10m.count,
               h.wind_gusts_10m.count, h.pressure_msl.count,
               h.surface_pressure.count, h.precipitation.count,
               h.precipitation_probability.count].allSatisfy({ $0 == count }) else {
            throw WeatherDecodeError.inconsistentHourlyArrays
        }
        for length in [h.temperature_2m?.count, h.weather_code?.count, h.is_day?.count].compactMap({ $0 }) {
            guard length == count else { throw WeatherDecodeError.inconsistentHourlyArrays }
        }
        guard let currentTime = parseUTC(payload.current.time) else { throw WeatherDecodeError.invalidResponse }
        var hours: [WeatherHour] = []
        for index in 0..<count {
            guard let time = parseUTC(h.time[index]) else { throw WeatherDecodeError.invalidResponse }
            hours.append(WeatherHour(timestamp: time,
                                     windSpeedKmh: h.wind_speed_10m[index],
                                     windDirectionFromDegrees: h.wind_direction_10m[index],
                                     windGustKmh: h.wind_gusts_10m[index],
                                     pressureMSLHpa: h.pressure_msl[index],
                                     surfacePressureHpa: h.surface_pressure[index],
                                     precipitationMm: h.precipitation[index],
                                     precipitationProbabilityPercent: h.precipitation_probability[index], temperatureC: h.temperature_2m?[index], weatherCode: h.weather_code?[index], isDay: h.is_day?[index]))
        }
        let current = WeatherHour(timestamp: currentTime,
                                  windSpeedKmh: payload.current.wind_speed_10m,
                                  windDirectionFromDegrees: payload.current.wind_direction_10m,
                                  windGustKmh: payload.current.wind_gusts_10m,
                                  pressureMSLHpa: payload.current.pressure_msl,
                                  surfacePressureHpa: payload.current.surface_pressure,
                                  precipitationMm: payload.current.precipitation,
                                  precipitationProbabilityPercent: nil, temperatureC: payload.current.temperature_2m, weatherCode: payload.current.weather_code, isDay: payload.current.is_day)
        return PointWeather(latitude: payload.latitude, longitude: payload.longitude,
                            retrievedAt: retrievedAt, source: "Open-Meteo Forecast API",
                            temperatureC: payload.current.temperature_2m,
                            apparentTemperatureC: payload.current.apparent_temperature,
                            humidityPercent: payload.current.relative_humidity_2m,
                            current: current, hourly: hours)
    }
}
