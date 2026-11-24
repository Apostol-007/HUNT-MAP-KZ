import Foundation
import Network
import SQLite3

/// Read-only loopback XYZ endpoint for local raster MBTiles. MBTiles stores TMS rows.
final class LocalMBTilesServer {
    static let shared = LocalMBTilesServer()
    private let queue = DispatchQueue(label: "kz.huntmap.mbtiles.http")
    private var listener: NWListener?
    private var files: [String: URL] = [:]
    private var supportedFiles: Set<String> = []
    private var readers: [String: OpaquePointer] = [:]
    private(set) var port: UInt16?

    private init() { start() }

    private func start() {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                if case .ready = state, let p = listener?.port {
                    self?.queue.async {
                        self?.port = p.rawValue
                        DispatchQueue.main.async { NotificationCenter.default.post(name: .huntMBTilesReady, object: nil) }
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch { NSLog("HUNT MBTiles server: %@", error.localizedDescription) }
    }

    func register(_ urls: [URL]) -> [(String, URL)] {
        queue.sync {
            // Remove obsolete registrations when a pack is deleted or replaced.
            // Otherwise old URLs could remain reachable after switching maps.
            // All reads run on this serial queue. Close the previous readers
            // before switching the active package manifest.
            for (_, db) in readers { sqlite3_close(db) }
            readers.removeAll()
            files.removeAll()
            supportedFiles.removeAll()
            var registered: [(String, URL)] = []
            for (index, file) in urls.enumerated() where file.isFileURL && file.pathExtension.lowercased() == "mbtiles" {
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let key = "p\(index)"
                guard isRasterMBTiles(file) else { continue }
                var db: OpaquePointer?
                guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                      let db else {
                    if let db { sqlite3_close(db) }
                    continue
                }
                files[key] = file
                readers[key] = db
                supportedFiles.insert(key)
                registered.append((key, file))
            }
            return registered
        }
    }

    func tileTemplate(for key: String) -> String? {
        queue.sync {
            guard let port else { return nil }
            guard supportedFiles.contains(key) else { return nil }
            return "http://127.0.0.1:\(port)/tiles/\(key)/{z}/{x}/{y}"
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, let request = String(data: data, encoding: .utf8),
                  let first = request.components(separatedBy: "\r\n").first else {
                connection.cancel(); return
            }
            let components = first.split(separator: " ")
            guard components.count >= 2, components[0] == "GET" else {
                self.reply(connection, status: "405 Method Not Allowed", body: Data()); return
            }
            let parts = components[1].split(separator: "/")
            guard parts.count == 5, parts[0] == "tiles", let file = self.files[String(parts[1])],
                  let z = Int(parts[2]), let x = Int(parts[3]),
                  let y = Int(parts[4].split(separator: ".").first ?? ""),
                  (0...22).contains(z), x >= 0, y >= 0,
                  Int64(x) < (Int64(1) << z), Int64(y) < (Int64(1) << z) else {
                self.reply(connection, status: "404 Not Found", body: Data()); return
            }
            let tmsY = Int((Int64(1) << z) - 1 - Int64(y))
            guard let tile = self.readTile(file: file, z: z, x: x, y: tmsY) else {
                self.reply(connection, status: "404 Not Found", body: Data()); return
            }
            self.reply(connection, status: "200 OK", body: tile, contentType: self.mimeType(for: tile))
        }
    }

    private func readTile(file: URL, z: Int, x: Int, y: Int) -> Data? {
        // Reuse read-only SQLite handles while panning; this function only
        // executes on the server's serial queue, never concurrently.
        guard let key = files.first(where: { $0.value == file })?.key,
              let db = readers[key] else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(z))
        sqlite3_bind_int(statement, 2, Int32(x))
        sqlite3_bind_int(statement, 3, Int32(y))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, length < 5_000_000 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    /// MBTiles can contain vector PBF or raster PNG/JPEG/WebP. Raster layers
    /// must not be created for vector packs: they otherwise render blank.
    private func isRasterMBTiles(_ url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name='format' LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return false }
        return ["png", "jpg", "jpeg", "webp"].contains(String(cString: value).lowercased())
    }

    private func mimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return "application/octet-stream"
    }

    private func reply(_ connection: NWConnection, status: String, body: Data, contentType: String = "text/plain") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: public, max-age=3600\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension Notification.Name { static let huntMBTilesReady = Notification.Name("hunt.mbtiles.ready") }
