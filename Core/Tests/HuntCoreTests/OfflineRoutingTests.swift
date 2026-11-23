import XCTest
@testable import HuntCore

final class OfflineRoutingTests: XCTestCase {
    private let network = """
    {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"LineString","coordinates":[[76.90,43.20],[76.91,43.20],[76.92,43.20]]}}, {"type":"Feature","geometry":{"type":"LineString","coordinates":[[76.91,43.20],[76.91,43.21]]}}]}
    """.data(using: .utf8)!
    func testGraphRouteThroughJunction() throws {
        let graph = try OfflineRouteGraph(geoJSON: network)
        let route = try graph.path(from: GeoPoint(43.2,76.9), to: GeoPoint(43.21,76.91))
        XCTAssertEqual(route.count, 5)
        XCTAssertEqual(route[2], GeoPoint(43.2,76.91))
    }
    func testNoFakeConnection() throws {
        let data = """
        {"type":"FeatureCollection","features":[{"geometry":{"type":"LineString","coordinates":[[76.90,43.2],[76.91,43.2]]}},{"geometry":{"type":"LineString","coordinates":[[76.92,43.2],[76.93,43.2]]}}]}
        """.data(using: .utf8)!
        let graph = try OfflineRouteGraph(geoJSON: data)
        XCTAssertThrowsError(try graph.path(from: GeoPoint(43.2, 76.90), to: GeoPoint(43.2, 76.93)))
    }
    func testRejectsTooFarFromGraph() throws {
        let graph = try OfflineRouteGraph(geoJSON: network)
        XCTAssertThrowsError(try graph.path(from: GeoPoint(42,75), to: GeoPoint(43.21,76.91)))
    }
}
