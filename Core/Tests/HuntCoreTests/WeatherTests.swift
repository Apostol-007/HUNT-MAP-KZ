import XCTest
@testable import HuntCore

final class WeatherTests: XCTestCase {
    private let fixture = """
    {"latitude":43.25,"longitude":76.9,"timezone":"GMT",
    "current":{"time":"2026-11-23T08:00","temperature_2m":4.2,"apparent_temperature":1.2,"relative_humidity_2m":63,"wind_speed_10m":18,"wind_direction_10m":270,"wind_gusts_10m":30,"pressure_msl":1012,"surface_pressure":880,"precipitation":0},
    "hourly":{"time":["2026-11-23T08:00","2026-11-23T09:00"],"wind_speed_10m":[18,20],"wind_direction_10m":[270,275],"wind_gusts_10m":[30,null],"pressure_msl":[1012,1013],"surface_pressure":[880,881],"precipitation":[0,1.2],"precipitation_probability":[10,70]}}
    """
    func testDecodesPointAndHourlyData() throws {
        let result = try OpenMeteoDecoder.decode(Data(fixture.utf8))
        XCTAssertEqual(result.temperatureC, 4.2)
        XCTAssertEqual(result.hourly.count, 2)
        XCTAssertNil(result.hourly[1].windGustKmh)
        XCTAssertEqual(result.hourly[1].precipitationMm, 1.2)
    }
    func testDirectionIsFromNotTo() throws {
        let result = try OpenMeteoDecoder.decode(Data(fixture.utf8))
        XCTAssertEqual(result.current.windDirectionFromDegrees, 270)
        XCTAssertEqual(result.current.windDirectionToDegrees, 90)
        XCTAssertEqual(WeatherMath.normalizeDirection(-90), 270)
    }
    func testPressureConversion() {
        XCTAssertEqual(WeatherMath.mmHg(1013.25), 760.0, accuracy: 0.05)
    }
    func testRejectsNonUTCForecast() {
        XCTAssertThrowsError(try OpenMeteoDecoder.decode(Data(fixture.replacingOccurrences(of: "GMT", with: "Asia/Almaty").utf8)))
    }
    func testRejectsInconsistentArrays() {
        let bad = fixture.replacingOccurrences(of: "[10,70]", with: "[10]")
        XCTAssertThrowsError(try OpenMeteoDecoder.decode(Data(bad.utf8)))
    }
}
