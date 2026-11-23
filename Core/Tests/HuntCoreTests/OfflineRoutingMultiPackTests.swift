import XCTest
@testable import HuntCore

final class OfflineRoutingMultiPackTests: XCTestCase {
    private func json(_ points: [[Double]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "FeatureCollection",
            "features": [["type": "Feature",
                          "geometry": ["type": "LineString", "coordinates": points],
                          "properties": ["highway": "track"]]]
        ])
    }

    func testAdjacentPacksConnectOnSharedNode() throws {
        let a = try json([[76.90, 43.20], [76.901, 43.20]])
        let b = try json([[76.901, 43.20], [76.902, 43.20]])
        let graph = try OfflineRouteGraph(geoJSONParts: [a, b])
        let path = try graph.path(from: GeoPoint(43.20, 76.90), to: GeoPoint(43.20, 76.902))
        XCTAssertEqual(path.count, 3)
    }

    func testDisconnectedPacksNotInventedAsConnected() throws {
        let a = try json([[76.90, 43.20], [76.901, 43.20]])
        let b = try json([[76.903, 43.20], [76.904, 43.20]])
        let graph = try OfflineRouteGraph(geoJSONParts: [a, b])
        XCTAssertThrowsError(try graph.path(from: GeoPoint(43.20, 76.90), to: GeoPoint(43.20, 76.904)))
    }
}
