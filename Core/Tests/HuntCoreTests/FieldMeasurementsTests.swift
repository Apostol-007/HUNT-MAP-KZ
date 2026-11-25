import XCTest
@testable import HuntCore
final class FieldMeasurementsTests: XCTestCase {
    func testDistanceBearingArea() throws {
        let a=GeoPoint(43,76), b=GeoPoint(43.001,76), c=GeoPoint(43.001,76.001), d=GeoPoint(43,76.001)
        XCTAssertEqual(FieldMeasurements.distance([a,b]),111,accuracy:2)
        XCTAssertEqual(try XCTUnwrap(FieldMeasurements.bearing(a,b)),0,accuracy:0.01)
        XCTAssertGreaterThan(try XCTUnwrap(FieldMeasurements.area([a,b,c,d])),8000)
        XCTAssertNil(FieldMeasurements.area([a,c,b,d]))
        XCTAssertNil(FieldMeasurements.area([a,a,b]))
    }
}
