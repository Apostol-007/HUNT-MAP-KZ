import Foundation
import SQLite3
import CryptoKit

/// The database is opened read-only, on a separate actor, only when searched.
actor OfflineAddressIndex {
    struct Hit: Sendable {
        let title: String
        let address: String
        let latitude: Double
        let longitude: Double
        let house: String?
    }

    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Addresses", isDirectory: true)
    private var file: URL { folder.appendingPathComponent("kazakhstan-addresses.sqlite") }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "QazAddressIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    func isInstalled() -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw failure("Не удалось открыть адресную базу")
        }
        return db
    }

    private func validate(_ url: URL) throws {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='schema'", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0),
              String(cString: value) == "qaz-address-v1" else {
            throw failure("Неподдерживаемый формат адресной базы")
        }
        sqlite3_finalize(stmt)
        stmt = nil
        guard sqlite3_prepare_v2(db, "SELECT rowid, title, address, house, lat, lon FROM addresses WHERE addresses MATCH 'test' LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            throw failure("В базе отсутствует поисковый индекс")
        }
    }

    func install(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: source, to: temp)
        try validate(temp)
        if isInstalled() {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: file) }
    }

    private struct Catalog: Decodable {
        let schema: String
        let file: Entry
        struct Entry: Decodable {
            let url: URL
            let bytes: Int64
            let sha256: String
        }
    }
    private var downloading = false
    func downloadFromHosting() async throws {
        guard !downloading else { throw failure("Загрузка уже выполняется") }
        downloading = true
        defer { downloading = false }
        let catalogURL = URL(string: "https://create.web-works.kz/maps/addresses/catalog.json")!
        var request = URLRequest(url: catalogURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else {
            throw failure("Каталог адресов недоступен")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let entry = catalog.file
        guard catalog.schema == "qaz-address-catalog-v1",
              entry.url.scheme == "https", entry.url.host == catalogURL.host,
              entry.url.path.hasPrefix("/maps/addresses/"),
              entry.url.lastPathComponent == "kazakhstan-addresses.sqlite",
              entry.bytes > 0, entry.bytes <= 2_147_483_648,
              entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw failure("Некорректный каталог адресной базы")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < entry.bytes * 2 + 64_000_000 {
            throw failure("Недостаточно свободного места для обновления адресов")
        }
        var download = URLRequest(url: entry.url)
        download.timeoutInterval = 120
        let (temporary, reply) = try await URLSession.shared.download(for: download)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (reply as? HTTPURLResponse)?.statusCode == 200,
              reply.url?.scheme == "https", reply.url?.host == catalogURL.host,
              Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == entry.bytes else {
            throw failure("Размер загруженной адресной базы не совпадает")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == entry.sha256.lowercased() else { throw failure("SHA-256 адресной базы не совпадает") }
        try Task.checkCancellation()
        try install(temporary)
    }

    func search(words: [String], house: String?) throws -> [Hit] {
        guard isInstalled(), !words.isEmpty || house != nil else { return [] }
        try Task.checkCancellation()
        let db = try open(file)
        defer { sqlite3_close(db) }
        let terms = words.prefix(12).flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        let text = terms.map { "\"\(String($0))\"*" }.joined(separator: " AND ")
        let houseTerm = house.map { "house : \"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        let match = ([text].filter { !$0.isEmpty } + [houseTerm].compactMap { $0 }).joined(separator: " AND ")
        guard !match.isEmpty else { return [] }
        let sql = "SELECT title,address,house,lat,lon FROM addresses WHERE addresses MATCH ?"
            + (house == nil ? "" : " AND house = ?") + " LIMIT 60"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw failure("Ошибка адресного индекса")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, match, -1, transient)
        if let house { sqlite3_bind_text(stmt, 2, house, -1, transient) }
        func string(_ col: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, col) else { return "" }
            return String(cString: value)
        }
        var results: [Hit] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let lat = sqlite3_column_double(stmt, 3), lon = sqlite3_column_double(stmt, 4)
            if lat.isFinite, lon.isFinite, (40...56).contains(lat), (46...88).contains(lon) {
                let number = string(2)
                results.append(Hit(title: string(0), address: string(1), latitude: lat, longitude: lon, house: number.isEmpty ? nil : number))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure("Ошибка чтения адресной базы") }
        return results
    }
}
