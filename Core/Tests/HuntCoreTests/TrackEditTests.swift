import Foundation
import XCTest
@testable import HuntCore

final class TrackEditTests: XCTestCase {
    func testTrimAndSplitPreserveOriginalPoints() {
        let original = Array(0...9)
        XCTAssertEqual(TrackEdit.trim(original, start: 2, end: 6), [2,3,4,5,6])
        XCTAssertNil(TrackEdit.trim(original, start: -1, end: 5))
        XCTAssertNil(TrackEdit.trim(original, start: 3, end: 3))
        XCTAssertNil(TrackEdit.trim(original, start: 0, end: 10))
        let split = TrackEdit.split(original, at: 4)
        XCTAssertEqual(split?.0, [0,1,2,3,4])
        XCTAssertEqual(split?.1, [4,5,6,7,8,9])
        XCTAssertNil(TrackEdit.split(original, at: 0))
        XCTAssertNil(TrackEdit.split(original, at: 9))
        XCTAssertEqual(original, Array(0...9))
    }
    private struct Point: Equatable {
        var time: Date
        var segmentStart = false
    }
    func testJoinMarksNewSegmentAndRejectsOverlap() throws {
        let points = (0..<6).map { Point(time: Date(timeIntervalSince1970: Double($0))) }
        let first = Array(points[0...2]), second = Array(points[3...5])
        func mark(_ point: Point) -> Point { var copy = point; copy.segmentStart = true; return copy }
        let joined = try XCTUnwrap(TrackEdit.join(first, second, timestamp: { $0.time }, startSegment: mark))
        XCTAssertEqual(joined.map(\.time), points.map(\.time))
        XCTAssertTrue(joined[3].segmentStart)
        XCTAssertFalse(second[0].segmentStart)
        XCTAssertNil(TrackEdit.join(first, Array(points[2...5]), timestamp: { $0.time }, startSegment: mark))
        XCTAssertNil(TrackEdit.join(second, first, timestamp: { $0.time }, startSegment: mark))
    }
}
