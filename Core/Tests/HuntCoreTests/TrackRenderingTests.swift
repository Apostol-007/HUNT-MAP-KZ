import Foundation
import Testing
@testable import HuntCore

@Test func renderingKeepsEndpointsAndCorners() {
    let points = [GeoPoint(43, 77), GeoPoint(43, 77.001), GeoPoint(43.002, 77.001), GeoPoint(43.002, 77.003)]
    let output = TrackRendering.simplified(points, toleranceMeters: 1)
    #expect(output.first == points.first)
    #expect(output.last == points.last)
    #expect(output.contains(points[1]))
    #expect(output.contains(points[2]))
}
@Test func renderingCapsLargeStraightTrackWithoutChangingInput() {
    let points = (0..<50000).map { GeoPoint(43, 76 + Double($0) * 0.000001) }
    let output = TrackRendering.simplified(points)
    #expect(output.count <= 2500)
    #expect(output.first == points.first)
    #expect(output.last == points.last)
    #expect(points.count == 50000)
}
@Test func renderingHandlesTinySegments() {
    #expect(TrackRendering.simplified([]).isEmpty)
    #expect(TrackRendering.simplified([GeoPoint(43,77)]).count == 1)
}
