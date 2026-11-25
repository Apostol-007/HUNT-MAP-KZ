import Foundation
import SQLite3
import CryptoKit
import HuntCore

// A package is an MBTiles SQLite database. No remote tile URL is ever created here.
struct PublishedPack: Codable, Identifiable {
    let pack_id: String
    let scope: String
    let scope_id: String
    let size_bytes: Int64
    let sha256: String
    let source_version: String
    let license: String
    let verified: Bool
    let layers: [String]
    var id: String { pack_id }
}

@MainActor final class OfflineTileStore: ObservableObject {
    @Published private(set) var installed: [PublishedPack] = []
    @Published private(set) var available: [PublishedPack] = []
    @Published private(set) var message: String = "Нет загруженной карты"
    @Published private(set) var busy = false
    @Published private(set) var revision = 0
    @Published private(set) var progress: Double = 0
    // Set only to a trusted TLS deployment. Prototype localhost is intentionally not default.
    @Published var serviceURL = ""
    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMBTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var registryURL: URL { folder.appendingPathComponent("installed.json") }
    init() { restore() }
    private func restore() {
        if let data = try? Data(contentsOf: registryURL), let records = try? JSONDecoder().decode([PublishedPack].self, from: data) {
            installed = records.filter { FileManager.default.fileExists(atPath: path(for: $0).path) }
        }
    }
    private func persist() throws { try JSONEncoder().encode(installed).write(to: registryURL, options: [.atomic]) }
    func path(for pack: PublishedPack) -> URL { folder.appendingPathComponent(pack.pack_id + ".mbtiles") }
    var paths: [URL] { installed.map { path(for: $0) } }
    private func endpoint() throws -> URL {
        guard let url = URL(string: serviceURL), url.scheme == "https", url.host != nil else { throw StoreError.invalidEndpoint }
        return url
    }
    enum StoreError: LocalizedError {
        case invalidEndpoint, invalidManifest, badChecksum, unsupportedFormat, notEnoughStorage, badRange
        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Укажите HTTPS-адрес сервера карт"
            case .invalidManifest: "Некорректный манифест пакета"
            case .badChecksum: "Контрольная сумма файла не совпадает"
            case .unsupportedFormat: "Пакет не является MBTiles с растровыми тайлами"
            case .notEnoughStorage: "На устройстве недостаточно места"
            case .badRange: "Сервер вернул некорректный фрагмент файла"
            }
        }
    }
    func fetch(scope: String, id: String) async {
        busy = true; defer { busy = false }
        do {
            let base = try endpoint()
            guard let safeID = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "/v1/packs/manifest?scope=\(scope)&id=\(safeID)", relativeTo: base) else { throw StoreError.invalidManifest }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.invalidManifest }
            let items = try JSONDecoder().decode([PublishedPack].self, from: data)
            available = items.filter { $0.layers.contains("raster-mbtiles") && $0.pack_id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil }
            message = available.isEmpty ? "Нет опубликованных растровых пакетов для этого района" : "Доступно пакетов: \(available.count)"
        } catch { message = "Каталог: \(error.localizedDescription)" }
    }
    /// Resume is persisted in a .part file. Only a fully verified SQLite pack becomes visible.
    /// A partial file is bound to the expected content hash, so changed manifests cannot corrupt it.
    func install(_ pack: PublishedPack) async {
        guard !busy else { return }; busy = true; progress = 0; defer { busy = false }
        do {
            let base = try endpoint()
            guard pack.pack_id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
                  pack.size_bytes > 0, pack.size_bytes < Int64.max / 2,
                  pack.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                  pack.layers.contains("raster-mbtiles") else { throw StoreError.invalidManifest }
            let needed = pack.size_bytes * 2 + 100_000_000
            if let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               capacity < needed { throw StoreError.notEnoughStorage }
            guard let remote = URL(string: "/v1/packs/\(pack.pack_id)", relativeTo: base) else { throw StoreError.invalidEndpoint }
            let partial = folder.appendingPathComponent("\(pack.pack_id)-\(pack.sha256.lowercased()).part")
            // Drop stale partial files for older versions of this same logical package.
            let prefix = pack.pack_id + "-"
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "part" && file != partial {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var received = try handle.seekToEnd()
            if received > UInt64(pack.size_bytes) {
                try handle.truncate(atOffset: 0)
                received = 0
            }
            let blockSize: Int64 = 4 * 1024 * 1024
            while received < UInt64(pack.size_bytes) {
                try Task.checkCancellation()
                let offset = Int64(received)
                let length = Int(min(blockSize, pack.size_bytes - offset))
                var request = URLRequest(url: remote)
                request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
                request.setValue("\"\(pack.sha256.lowercased())\"", forHTTPHeaderField: "If-Range")
                let (chunk, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 206 else { throw StoreError.badRange }
                do {
                    try PackTransfer.validate(contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                              offset: offset, bytes: chunk.count,
                                              total: pack.size_bytes, requested: length)
                } catch { throw StoreError.badRange }
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                progress = Double(received) / Double(pack.size_bytes)
                message = "Скачано \(Int(progress * 100))% · \(pack.pack_id)"
            }
            try handle.synchronize()
            guard try await Self.sha256(file: partial).lowercased() == pack.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: partial)
                throw StoreError.badChecksum
            }
            guard RasterMBTiles.isSupported(partial) else { throw StoreError.unsupportedFormat }
            let staged = folder.appendingPathComponent("staging-\(UUID().uuidString).mbtiles")
            try await HuntBackgroundWork.run { try FileManager.default.copyItem(at: partial, to: staged) }
            let target = path(for: pack)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: target) }
            try? FileManager.default.removeItem(at: partial)
            installed.removeAll { $0.pack_id == pack.pack_id }
            installed.append(pack)
            try persist(); revision += 1
            message = "Карта установлена, SHA-256 проверен. Источник: \(pack.license)"
        } catch { message = "Установка: \(error.localizedDescription). Частичная загрузка сохранена для продолжения." }
    }
    /// Import a user-provided, licensed raster MBTiles archive without connecting to the server.
    /// Original files are not modified. This does not certify legal status or map accuracy.
    func importLocal(_ incoming: URL) async {
        guard !busy else { return }
        busy = true; progress = 0
        defer { busy = false }
        let access = incoming.startAccessingSecurityScopedResource()
        defer { if access { incoming.stopAccessingSecurityScopedResource() } }
        var staging: URL?
        do {
            guard incoming.pathExtension.lowercased() == "mbtiles" else { throw StoreError.unsupportedFormat }
            let attrs = try FileManager.default.attributesOfItem(atPath: incoming.path)
            guard let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { throw StoreError.unsupportedFormat }
            let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let capacity, Int64(capacity) < size.int64Value + 100_000_000 { throw StoreError.notEnoughStorage }
            let temp = folder.appendingPathComponent("import-\(UUID().uuidString).mbtiles")
            staging = temp
            try await HuntBackgroundWork.run { try FileManager.default.copyItem(at: incoming, to: temp) }
            guard RasterMBTiles.isSupported(temp) else { throw StoreError.unsupportedFormat }
            let digest = try await Self.sha256(file: temp)
            let id = "local-\(String(digest.prefix(24)))"
            let pack = PublishedPack(pack_id: id, scope: "ground", scope_id: "LOCAL", size_bytes: size.int64Value,
                                     sha256: digest, source_version: "user-import", license: "Не указана: ответственность пользователя",
                                     verified: false, layers: ["raster-mbtiles"])
            let destination = path(for: pack)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: temp, to: destination)
                staging = nil
            }
            if !installed.contains(where: { $0.pack_id == id }) { installed.append(pack) }
            try persist()
            revision += 1; progress = 1
            message = "Локальная карта импортирована. Источник и лицензия не подтверждены"
        } catch {
            message = "Ошибка импорта MBTiles: \(error.localizedDescription)"
        }
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    func remove(_ pack: PublishedPack) {
        try? FileManager.default.removeItem(at: path(for: pack))
        installed.removeAll { $0.pack_id == pack.pack_id }
        do { try persist(); revision += 1; message = "Карта удалена; личные точки и маршруты сохранены" }
        catch { message = "Не удалось обновить реестр: \(error.localizedDescription)" }
    }
    private static func sha256(file: URL) async throws -> String {
        try await HuntBackgroundWork.digest(file)
    }
}

// One readonly SQLite connection per tile read. SQLite handles parallel readers safely.
enum RasterMBTiles {
    static func isSupported(_ url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name='format' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return false }
        let format = String(cString: raw).lowercased()
        return format == "png" || format == "jpg" || format == "jpeg" || format == "webp"
    }
    static func tile(_ url: URL, z: Int, x: Int, y: Int) -> Data? {
        guard z >= 0 && z <= 22, x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z)); sqlite3_bind_int(stmt, 2, Int32(x))
        sqlite3_bind_int(stmt, 3, Int32((1 << z) - 1 - y)) // XYZ -> TMS
        guard sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, 0)))
    }
}

