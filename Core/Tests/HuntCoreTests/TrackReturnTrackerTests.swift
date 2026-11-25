import XCTest
@testable import HuntCore

final class TrackReturnTrackerTests: XCTestCase {
    func testNoTeleportAtCrossing() throws {
        let a = GeoPoint(43,76)
        let b = GeoPoint(43.001,76)
        let c = GeoPoint(43.001,76.001)
        var tracker = try XCTUnwrap(TrackReturnTracker(points:[a,b,c,a]))
        let now = Date()
        let first = tracker.update(position:a,accuracy:5,timestamp:now)
        XCTAssertGreaterThan(first.remaining,100)
        XCTAssertFalse(first.arrived)
        let repeatFix = tracker.update(position:a,accuracy:5,timestamp:now)
        XCTAssertEqual(first.remaining,repeatFix.remaining)
    }
    func testRejectShortAndConfirmDeviation() throws {
        let a = GeoPoint(43,76)
        let b = GeoPoint(43.001,76)
        XCTAssertNil(TrackReturnTracker(points:[a,a]))
        var tracker = try XCTUnwrap(TrackReturnTracker(points:[a,b]))
        let far = GeoPoint(43,76.003)
        let now = Date()
        XCTAssertNotEqual(tracker.update(position:far,accuracy:5,timestamp:now).status,.offTrack)
        XCTAssertNotEqual(tracker.update(position:far,accuracy:5,timestamp:now.addingTimeInterval(1)).status,.offTrack)
        XCTAssertEqual(tracker.update(position:far,accuracy:5,timestamp:now.addingTimeInterval(2)).status,.offTrack)
    }
}
