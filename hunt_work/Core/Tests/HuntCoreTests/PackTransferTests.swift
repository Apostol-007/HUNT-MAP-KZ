import XCTest
@testable import HuntCore

final class PackTransferTests: XCTestCase {
    func testValidFirstAndLastChunk() throws {
        try PackTransfer.validate(contentRange: "bytes 0-3/10", offset: 0, bytes: 4, total: 10, requested: 4)
        try PackTransfer.validate(contentRange: "bytes 8-9/10", offset: 8, bytes: 2, total: 10, requested: 4)
    }
    func testWrongOffsetRejected() {
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes 0-3/10", offset: 4, bytes: 4, total: 10, requested: 4))
    }
    func testWrongTotalRejected() {
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes 0-3/11", offset: 0, bytes: 4, total: 10, requested: 4))
    }
    func testWrongLengthRejected() {
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes 0-9/10", offset: 0, bytes: 4, total: 10, requested: 4))
    }
    func testMissingAndMalformedRangeRejected() {
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: nil, offset: 0, bytes: 4, total: 10, requested: 4))
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes */10", offset: 0, bytes: 4, total: 10, requested: 4))
    }
    func testZeroAndOversizedChunkRejected() {
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes 0-0/10", offset: 0, bytes: 0, total: 10, requested: 4))
        XCTAssertThrowsError(try PackTransfer.validate(contentRange: "bytes 0-4/10", offset: 0, bytes: 5, total: 10, requested: 4))
    }
}
