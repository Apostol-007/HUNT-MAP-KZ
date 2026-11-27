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
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='schema_version'", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0),
              String(cString: value) == "1" else {
            throw failure("Неподдерживаемый формат адресной базы")
        }
        sqlite3_finalize(stmt)
        stmt = nil
        guard sqlite3_prepare_v2(db, "SELECT a.id, a.name, a.address, a.house, a.lat, a.lon FROM address_fts JOIN addresses a ON a.id=address_fts.rowid WHERE address_fts MATCH 'test' LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
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
        try? FileManager.default.removeItem(at: catalogReceipt)
    }

    private struct Catalog: Decodable {
        let schema_version: Int
        let country: String
        let file: String
        let size_bytes: Int64
        let sha256: String
        let records: Int
        let created_at: String
    }
    private var catalogReceipt: URL { folder.appendingPathComponent("installed-catalog.json") }
    func installedSummary() -> String {
        guard isInstalled() else { return "" }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if let data = try? Data(contentsOf: catalogReceipt),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            return "\(catalog.records.formatted()) записей · \(size) · \(catalog.created_at.prefix(10))"
        }
        return size + " · импортированная база"
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
        guard catalog.schema_version == 1, catalog.country == "KZ",
              catalog.file == "kazakhstan_addresses.sqlite",
              catalog.size_bytes > 0, catalog.size_bytes <= 2_147_483_648,
              catalog.records > 0, catalog.sha256.count == 64,
              catalog.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw failure("Некорректный каталог адресной базы")
        }
        if isInstalled(), let receipt = try? Data(contentsOf: catalogReceipt),
           let old = try? JSONDecoder().decode(Catalog.self, from: receipt),
           old.sha256.lowercased() == catalog.sha256.lowercased(),
           Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == catalog.size_bytes {
            return
        }
        let databaseURL = catalogURL.deletingLastPathComponent().appendingPathComponent(catalog.file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < catalog.size_bytes * 2 + 64_000_000 {
            throw failure("Недостаточно свободного места для обновления адресов")
        }
        var download = URLRequest(url: databaseURL)
        download.timeoutInterval = 120
        let (temporary, reply) = try await URLSession.shared.download(for: download)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (reply as? HTTPURLResponse)?.statusCode == 200,
              reply.url?.scheme == "https", reply.url?.host == catalogURL.host,
              Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == catalog.size_bytes else {
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
        guard actual == catalog.sha256.lowercased() else { throw failure("SHA-256 адресной базы не совпадает") }
        try Task.checkCancellation()
        try install(temporary)
        try data.write(to: catalogReceipt, options: .atomic)
    }

    func nearest(latitude: Double, longitude: Double) throws -> Hit? {
        guard isInstalled(), latitude.isFinite, longitude.isFinite,
              (40...56).contains(latitude), (46...88).contains(longitude) else { return nil }
        let db = try open(file)
        defer { sqlite3_close(db) }
        let scale = max(0.2, cos(latitude * .pi / 180))
        // Bounded local search. Do not return a distant building as the tapped address.
        let sql = """
            SELECT name,address,house,lat,lon FROM addresses
            WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
              AND house IS NOT NULL AND house <> ''
            ORDER BY (lat-?)*(lat-?) + (lon-?)*(lon-?)*?
            LIMIT 1
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw failure("Ошибка определения ближайшего адреса")
        }
        let radius = 0.003
        let values = [latitude-radius, latitude+radius, longitude-radius/scale, longitude+radius/scale,
                      latitude, latitude, longitude, longitude, scale*scale]
        for (i, value) in values.enumerated() { sqlite3_bind_double(stmt, Int32(i+1), value) }
        try Task.checkCancellation()
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func string(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        let lat = sqlite3_column_double(stmt, 3), lon = sqlite3_column_double(stmt, 4)
        guard lat.isFinite, lon.isFinite,
              hypot(lat-latitude, (lon-longitude)*scale)*111_320 <= 300 else { return nil }
        return Hit(title: string(0), address: string(1), latitude: lat, longitude: lon, house: string(2))
    }

    func search(words: [String], house: String?) throws -> [Hit] {
        guard isInstalled(), !words.isEmpty || house != nil else { return [] }
        try Task.checkCancellation()
        let db = try open(file)
        defer { sqlite3_close(db) }
        let terms = words.prefix(12).flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        let text = terms.map { "\"\(String($0))\"*" }.joined(separator: " AND ")
        // Match the numeric prefix in FTS; exact suffix equivalence is checked below.
        let houseTerms = (house ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { part in
                let digits = part.prefix(while: { $0.isNumber })
                return "\"\(digits.isEmpty ? String(part) : String(digits))\"*"
            }.joined(separator: " AND ")
        let match = [text, houseTerms].filter { !$0.isEmpty }.joined(separator: " AND ")
        guard !match.isEmpty else { return [] }
        let sql = "SELECT a.name,a.address,a.house,a.lat,a.lon FROM address_fts JOIN addresses a ON a.id=address_fts.rowid WHERE address_fts MATCH ?"
            + " ORDER BY rank LIMIT 500"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw failure("Ошибка адресного индекса")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, match, -1, transient)
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
                func normalize(_ value: String) -> String {
                    value.lowercased().replacingOccurrences(of: "а", with: "a")
                        .replacingOccurrences(of: "б", with: "b")
                        .replacingOccurrences(of: "в", with: "v")
                        .replacingOccurrences(of: "с", with: "c")
                        .filter { !$0.isWhitespace }
                }
                let normalized = normalize(number)
                if house == nil || normalized == house.map(normalize) {
                    results.append(Hit(title: string(0), address: string(1), latitude: lat, longitude: lon, house: number.isEmpty ? nil : normalized))
                    if results.count >= 60 { return results }
                }
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure("Ошибка чтения адресной базы") }
        return results
    }
}
