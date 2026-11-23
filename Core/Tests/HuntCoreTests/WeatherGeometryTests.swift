import XCTest
@testable import HuntCore

final class WeatherGeometryTests: XCTestCase {
    func testWestWindPointsEast() {
        let arrow = WeatherGeometry.windArrow(latitude: 43, longitude: 77, fromDegrees: 270, speedKmh: 24, lengthDegrees: 0.04)
        XCTAssertEqual(arrow.count, 3)
        XCTAssertGreaterThan(arrow[0].b.longitude, arrow[0].a.longitude)
    }
    func testNoFakeArrowOnMissingDirection() {
        XCTAssertTrue(WeatherGeometry.windArrow(latitude: 43, longitude: 77, fromDegrees: .nan, speedKmh: 12, lengthDegrees: 0.04).isEmpty)
    }
    func testBilinearConstantAndMissingSamples() {
        let samples = [WeatherGeometry.Sample(latitude: 0, longitude: 0, value: 4), WeatherGeometry.Sample(latitude: 0, longitude: 1, value: 4),
                       WeatherGeometry.Sample(latitude: 1, longitude: 0, value: 4), WeatherGeometry.Sample(latitude: 1, longitude: 1, value: 4)]
        let cells = WeatherGeometry.shade(samples: samples, width: 2, height: 2)
        XCTAssertEqual(cells.count, 16)
        XCTAssertTrue(cells.allSatisfy { $0.value == 4 })
        let absent = [samples[0], samples[1], samples[2], WeatherGeometry.Sample(latitude: 1, longitude: 1, value: nil)]
        XCTAssertTrue(WeatherGeometry.shade(samples: absent, width: 2, height: 2).isEmpty)
    }
    func testIsobarCrossesCell() {
        let samples = [WeatherGeometry.Sample(latitude: 0, longitude: 0, value: 1000), WeatherGeometry.Sample(latitude: 0, longitude: 1, value: 1010),
                       WeatherGeometry.Sample(latitude: 1, longitude: 0, value: 1000), WeatherGeometry.Sample(latitude: 1, longitude: 1, value: 1010)]
        let lines = WeatherGeometry.isolines(samples: samples, width: 2, height: 2, levels: [1005])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].a.longitude, 0.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].b.longitude, 0.5, accuracy: 0.001)
    }
    func testNoExtrapolationWhenContourCornerMissing() {
        let samples = [WeatherGeometry.Sample(latitude: 0, longitude: 0, value: 1000), WeatherGeometry.Sample(latitude: 0, longitude: 1, value: nil),
                       WeatherGeometry.Sample(latitude: 1, longitude: 0, value: 1010), WeatherGeometry.Sample(latitude: 1, longitude: 1, value: 1010)]
        XCTAssertTrue(WeatherGeometry.isolines(samples: samples, width: 2, height: 2, levels: [1005]).isEmpty)
    }
}
