import Foundation
import XCTest
@testable import HuntCore

final class TrackPointJournalTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    func testRecoveryAfterCheckpointAndRetry() throws {
        let url = directory()
        defer { try? TrackPointJournal.remove(directory: url) }
        for index in 0..<100 {
            try TrackPointJournal.append(index, index: index, directory: url)
        }
        try TrackPointJournal.append(99, index: 99, directory: url)
        XCTAssertEqual(try TrackPointJournal.recover(Int.self, after: 0, directory: url), Array(0..<100))
        XCTAssertEqual(try TrackPointJournal.recover(Int.self, after: 90, directory: url), Array(90..<100))
        XCTAssertThrowsError(try TrackPointJournal.append(999, index: 99, directory: url))
        try TrackPointJournal.remove(directory: url)
        XCTAssertEqual(try TrackPointJournal.recover(Int.self, after: 0, directory: url), [])
    }
    func testMissingOrDamagedRecordIsNotSilentlySkipped() throws {
        let url = directory()
        defer { try? TrackPointJournal.remove(directory: url) }
        try TrackPointJournal.append(1, index: 1, directory: url)
        XCTAssertThrowsError(try TrackPointJournal.recover(Int.self, after: 0, directory: url))
        try Data("bad".utf8).write(to: url.appendingPathComponent("000000000001.json"))
        XCTAssertThrowsError(try TrackPointJournal.recover(Int.self, after: 1, directory: url))
    }
}
