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
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        CREATE TABLE IF NOT EXISTS active_track (
          track_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          started_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_fixes_track_id ON fixes(track_id, id);
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

    func begin(track: Track) {
        guard let db else { return }
        // This is called only after startup recovery. Keep the track metadata
        // in the same durable journal as its fixes, so a lost field.json
        // cannot strand an otherwise intact recording.
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        guard sqlite3_exec(db, "DELETE FROM fixes; DELETE FROM active_track;", nil, nil, nil) == SQLITE_OK else { return }
        let sql = "INSERT INTO active_track(track_id,title,started_at) VALUES(?,?,?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        let id = track.id.uuidString
        guard id.withCString({ sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK,
              track.name.withCString({ sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { return }
        sqlite3_bind_double(statement, 3, track.createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { return }
        committed = true
        activeTrackID = id
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

    /// Recover even when field.json was removed or cannot be decoded. Older
    /// journal databases without metadata are recovered from the fix track_id.
    func recoverableTrack() -> Track? {
        guard let db else { return nil }
        var id: UUID?
        var title = "Восстановленный GPS-маршрут"
        var created = Date()
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT track_id,title,started_at FROM active_track LIMIT 1;", -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW,
               let raw = sqlite3_column_text(statement, 0),
               let parsed = UUID(uuidString: String(cString: raw)) {
                id = parsed
                if let name = sqlite3_column_text(statement, 1) { title = String(cString: name) }
                created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            }
        }
        sqlite3_finalize(statement)
        if id == nil {
            statement = nil
            if sqlite3_prepare_v2(db, "SELECT track_id,MIN(timestamp) FROM fixes GROUP BY track_id ORDER BY MIN(id) LIMIT 1;", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW,
               let raw = sqlite3_column_text(statement, 0) {
                id = UUID(uuidString: String(cString: raw))
                created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            }
            sqlite3_finalize(statement)
        }
        guard let id else { return nil }
        let fixes = read(trackID: id)
        guard !fixes.isEmpty else { return nil }
        return Track(id: id, name: title, createdAt: created, fixes: fixes)
    }

    func clear() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM fixes; DELETE FROM active_track;", nil, nil, nil)
        activeTrackID = nil
    }
}
