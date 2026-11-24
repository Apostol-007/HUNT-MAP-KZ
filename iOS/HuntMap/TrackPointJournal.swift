import Foundation
import SQLite3
import HuntCore

/// Crash-recoverable append-only GPS journal. The existing field.json remains
/// the compatibility and export format; finished tracks are still persisted there.
@MainActor final class TrackPointJournal {
    private var db: OpaquePointer?
    private let path: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        path = folder.appendingPathComponent("active-track.sqlite")
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            db = nil
            return
        }
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS fixes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          track_id TEXT NOT NULL,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          timestamp REAL NOT NULL,
          accuracy REAL NOT NULL,
          altitude REAL NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        try? (path as NSURL).setResourceValue(
            FileProtectionType.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey)
    }
    deinit {
        if let db { sqlite3_close(db) }
    }

    func begin(trackID: UUID) {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM fixes;", nil, nil, nil)
        // A single active track is stored; ownership is written on each append.
        activeTrackID = trackID.uuidString
    }

    private var activeTrackID: String?

    @discardableResult func append(_ fix: TrackFix) -> Bool {
        guard let db, let track = activeTrackID else { return false }
        let sql = "INSERT INTO fixes(track_id,latitude,longitude,timestamp,accuracy,altitude) VALUES(?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let bound = track.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 2, fix.point.latitude)
        sqlite3_bind_double(stmt, 3, fix.point.longitude)
        sqlite3_bind_double(stmt, 4, fix.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, fix.accuracy)
        sqlite3_bind_double(stmt, 6, fix.altitude)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func read(trackID: UUID) -> [TrackFix] {
        guard let db else { return [] }
        let sql = "SELECT latitude,longitude,timestamp,accuracy,altitude FROM fixes WHERE track_id=? ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        _ = trackID.uuidString.withCString {
            sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var result: [TrackFix] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let geo = GeoPoint(sqlite3_column_double(stmt, 0), sqlite3_column_double(stmt, 1))
            guard geo.valid else { continue }
            result.append(TrackFix(
                point: geo,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                accuracy: sqlite3_column_double(stmt, 3),
                altitude: sqlite3_column_double(stmt, 4)))
        }
        return result
    }

    func clear() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM fixes;", nil, nil, nil)
        activeTrackID = nil
    }
}
