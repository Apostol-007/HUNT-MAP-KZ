import XCTest
@testable import HuntCore

final class FieldAstronomyTests: XCTestCase {
    func testEquinoxAtGreenwich() throws {
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-03-20T12:00:00Z"))
        let zone=try XCTUnwrap(TimeZone(secondsFromGMT:0))
        let result=try XCTUnwrap(FieldAstronomy.calculate(date:date,point:GeoPoint(0,0),timeZone:zone))
        let rise=try XCTUnwrap(result.sunrise)
        let set=try XCTUnwrap(result.sunset)
        let dawn=try XCTUnwrap(result.dawn)
        let dusk=try XCTUnwrap(result.dusk)
        XCTAssertLessThan(dawn,rise)
        XCTAssertLessThan(rise,set)
        XCTAssertLessThan(set,dusk)
        XCTAssertEqual(result.daylightSeconds,43590,accuracy:180)
        XCTAssertTrue((0...1).contains(result.illumination))
    }
    func testPolarDayAndInvalidPoint() throws {
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-06-21T12:00:00Z"))
        let zone=try XCTUnwrap(TimeZone(secondsFromGMT:0))
        let result=try XCTUnwrap(FieldAstronomy.calculate(date:date,point:GeoPoint(89,0),timeZone:zone))
        XCTAssertNil(result.sunrise)
        XCTAssertNil(result.sunset)
        XCTAssertEqual(result.daylightSeconds,86400,accuracy:1)
        XCTAssertNil(FieldAstronomy.calculate(date:date,point:GeoPoint(100,0),timeZone:zone))
    }
}
