import XCTest
@testable import HuntCore

final class OfflineRoutingTests: XCTestCase {
    private func feature(_ coordinates: [[Double]], _ tags: [String: String]) -> [String: Any] {
        ["type": "Feature", "geometry": ["type": "LineString", "coordinates": coordinates], "properties": tags]
    }
    private func json(_ features: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    func testWalkingRouteFollowsJunctionNotStraightLine() throws {
        let data = try json([
            feature([[76.90,43.20],[76.91,43.20],[76.92,43.20]], ["highway":"path"]),
            feature([[76.91,43.20],[76.91,43.21]], ["highway":"footway"])
        ])
        let graph = try OfflineRouteGraph(geoJSON: data)
        let route = try graph.path(from: GeoPoint(43.20, 76.90), to: GeoPoint(43.21, 76.91))
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[1], GeoPoint(43.20, 76.91))
    }

    func testSnapsToMiddleOfRoadWithoutOffroadConnector() throws {
        let data = try json([feature([[76.90,43.20],[76.92,43.20]], ["highway":"path"])])
        let graph = try OfflineRouteGraph(geoJSON: data)
        let route = try graph.path(from: GeoPoint(43.2001,76.905), to: GeoPoint(43.2001,76.915))
        XCTAssertEqual(route.count, 2)
        XCTAssertEqual(route[0].latitude, 43.20, accuracy: 0.000001)
        XCTAssertEqual(route[1].latitude, 43.20, accuracy: 0.000001)
    }

    func testNoFakeConnection() throws {
        let data = try json([
            feature([[76.90,43.2],[76.91,43.2]], ["highway":"track"]),
            feature([[76.92,43.2],[76.93,43.2]], ["highway":"track"])
        ])
        let graph = try OfflineRouteGraph(geoJSON: data)
        XCTAssertThrowsError(try graph.path(from: GeoPoint(43.2,76.90), to: GeoPoint(43.2,76.93)))
    }

    func testOffroadDestinationRejected() throws {
        let data = try json([feature([[76.90,43.20],[76.91,43.20]], ["highway":"path"])])
        let graph = try OfflineRouteGraph(geoJSON: data)
        XCTAssertThrowsError(try graph.path(from: GeoPoint(43.20,76.90), to: GeoPoint(43.21,76.91)))
    }

    func testVehicleNotAllowedOnFootway() throws {
        let data = try json([feature([[76.90,43.20],[76.91,43.20]], ["highway":"footway"])])
        XCTAssertThrowsError(try OfflineRouteGraph(geoJSON: data, mode: .car))
        XCTAssertNoThrow(try OfflineRouteGraph(geoJSON: data, mode: .foot))
    }

    func testPrivateAccessRejected() throws {
        let data = try json([feature([[76.90,43.20],[76.91,43.20]], ["highway":"track","access":"private"])])
        XCTAssertThrowsError(try OfflineRouteGraph(geoJSON: data, mode: .foot))
        XCTAssertThrowsError(try OfflineRouteGraph(geoJSON: data, mode: .car))
    }

    func testUntaggedGeometryRejected() throws {
        let data = try json([feature([[76.90,43.20],[76.91,43.20]], [:])])
        XCTAssertThrowsError(try OfflineRouteGraph(geoJSON: data))
    }

    func testCarOnewayDirection() throws {
        let data = try json([feature([[76.90,43.20],[76.91,43.20]], ["highway":"residential","oneway":"yes"])])
        let car = try OfflineRouteGraph(geoJSON: data, mode: .car)
        XCTAssertNoThrow(try car.path(from: GeoPoint(43.20,76.90), to: GeoPoint(43.20,76.91)))
        XCTAssertThrowsError(try car.path(from: GeoPoint(43.20,76.91), to: GeoPoint(43.20,76.90)))
        let foot = try OfflineRouteGraph(geoJSON: data, mode: .foot)
        XCTAssertNoThrow(try foot.path(from: GeoPoint(43.20,76.91), to: GeoPoint(43.20,76.90)))
    }

    func testWalkAndDriveChooseDifferentRoads() throws {
        let data = try json([
            feature([[76.90,43.20],[76.91,43.20]], ["highway":"footway"]),
            feature([[76.90,43.21],[76.91,43.21]], ["highway":"residential", "foot":"no"])
        ])
        let foot = try OfflineRouteGraph(geoJSON: data, mode: .foot)
        let car = try OfflineRouteGraph(geoJSON: data, mode: .car)
        XCTAssertNoThrow(try foot.path(from: GeoPoint(43.20,76.90), to: GeoPoint(43.20,76.91)))
        XCTAssertNoThrow(try car.path(from: GeoPoint(43.21,76.90), to: GeoPoint(43.21,76.91)))
        XCTAssertThrowsError(try car.path(from: GeoPoint(43.20,76.90), to: GeoPoint(43.20,76.91)))
    }
}
