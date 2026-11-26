import Foundation
import XCTest
@testable import HuntCore

final class TrackExportCleanupTests: XCTestCase {
    func testOnlyExpiredOwnedExportsAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("route-\(UUID()).gpx")
        let fresh = folder.appendingPathComponent("route-\(UUID()).gpx")
        let unrelated = folder.appendingPathComponent("route-other.gpx")
        let map = folder.appendingPathComponent("offline.pmtiles")
        for url in [old,fresh,unrelated,map] { try Data("test".utf8).write(to: url) }
        let now = Date()
        let expired = now.addingTimeInterval(-8 * 24 * 3600)
        for url in [old,unrelated,map] {
            try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: url.path)
        }
        XCTAssertEqual(try TrackExportCleanup.removeExpired(in: folder, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [fresh,unrelated,map] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }
}
