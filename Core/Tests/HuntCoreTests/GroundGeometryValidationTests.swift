import XCTest
@testable import HuntCore
final class GroundGeometryValidationTests: XCTestCase {
    func testHoleAndInvalidGeometry() throws {
        let outer=[GeoPoint(43,76),GeoPoint(43.01,76),GeoPoint(43.01,76.01),GeoPoint(43,76.01)]
        let hole=[GeoPoint(43.002,76.002),GeoPoint(43.004,76.002),GeoPoint(43.004,76.004),GeoPoint(43.002,76.004)]
        XCTAssertNoThrow(try GroundGeometryValidation.validate([[outer,hole]]))
        XCTAssertThrowsError(try GroundGeometryValidation.validate([[outer,outer]]))
        XCTAssertThrowsError(try GroundGeometryValidation.validate([[outer],[outer]]))
        XCTAssertThrowsError(try GroundGeometryValidation.validate([[Array(outer.prefix(2))]]))
    }
}
