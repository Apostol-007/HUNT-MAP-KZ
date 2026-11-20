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
    // Source provenance: installation must use the catalog that advertised this pack.
    var catalog_url: String? = nil
    // Distinguish identically named packages published by different catalogs.
    var id: String { "\(catalog_url ?? "local")|\(pack_id)|\(sha256)" }
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
    init() {
        restore()
        installBundledOverviewIfNeeded()
    }
    /// Low-resolution geographic overview is shipped with the app and requires no network.
    /// This does NOT contain hunting grounds, detailed paths or high-resolution imagery.
    private func installBundledOverviewIfNeeded() {
        guard let seed = Bundle.main.url(forResource: "Kazakhstan_Overview_NaturalEarth", withExtension: "mbtiles"),
              RasterMBTiles.isSupported(seed) else { return }
        let packID = "kz-geography-overview-v1"
        if installed.contains(where: { $0.pack_id == packID }) { return }
        let destination = folder.appendingPathComponent(packID + ".mbtiles")
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: seed, to: destination)
            }
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            let digest = try Self.sha256(file: destination)
            let pack = PublishedPack(pack_id: packID, scope: "country", scope_id: "KZ",
                size_bytes: size?.int64Value ?? 0, sha256: digest, source_version: "bundled-overview-1",
                license: "Basemap geographic boundary datasets; see README. Low-resolution overview only",
                verified: false, layers: ["raster-mbtiles"])
            installed.append(pack)
            try persist()
            revision += 1
            message = "Базовая обзорная карта Казахстана доступна офлайн (масштаб 3–5)"
        } catch {
            message = "Не удалось установить обзорную карту: \(error.localizedDescription)"
        }
    }
    private func restore() {
        if let data = try? Data(contentsOf: registryURL), let records = try? JSONDecoder().decode([PublishedPack].self, from: data) {
            installed = records.filter { pack in
                let scoped = scopedPath(for: pack)
                let legacy = folder.appendingPathComponent(pack.pack_id + ".mbtiles")
                return FileManager.default.fileExists(atPath: scoped.path) ||
                    FileManager.default.fileExists(atPath: legacy.path)
            }
        }
    }
    private func persist() throws { try JSONEncoder().encode(installed).write(to: registryURL, options: [.atomic]) }
    private func scopedPath(for pack: PublishedPack) -> URL {
        guard let source = pack.catalog_url, !source.isEmpty else {
            return folder.appendingPathComponent(pack.pack_id + ".mbtiles")
        }
        let namespace = String(SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        return folder.appendingPathComponent("\(namespace)-\(pack.pack_id).mbtiles")
    }
    func path(for pack: PublishedPack) -> URL {
        let scoped = scopedPath(for: pack)
        if FileManager.default.fileExists(atPath: scoped.path) { return scoped }
        let legacy = folder.appendingPathComponent(pack.pack_id + ".mbtiles")
        // Legacy fallback only for the same registered package and content digest.
        if installed.contains(where: { $0.id == pack.id }) &&
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return scoped
    }
    var paths: [URL] { installed.map { path(for: $0) } }
    /// Coverage comes from the MBTiles metadata, not from a guessed radius around the user.
    func covering(latitude: Double, longitude: Double) -> [PublishedPack] {
        installed.filter { RasterMBTiles.covers(path(for: $0), latitude: latitude, longitude: longitude) }
    }
    func coveringDescription(latitude: Double, longitude: Double) -> String {
        let matches = covering(latitude: latitude, longitude: longitude)
        guard !matches.isEmpty else {
            return "Нет подтверждённого покрытия. Импортируйте подробный растровый MBTiles для выбранного района."
        }
        let detailed = matches.filter { (RasterMBTiles.zoomRange(path(for: $0))?.upperBound ?? 0) >= 12 }
        if detailed.isEmpty {
            let ranges = matches.compactMap { RasterMBTiles.zoomRange(path(for: $0)) }
                .map { "z\($0.lowerBound)–z\($0.upperBound)" }.joined(separator: ", ")
            return "Есть только обзорная карта (\(ranges)). Детальные улицы и тропы не загружены."
        }
        return "Подробные MBTiles найдены: \(detailed.count). Проверьте отображение нужного масштаба офлайн."
    }
    private func endpoint(_ raw: String? = nil) throws -> URL {
        guard let url = URL(string: raw ?? serviceURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw StoreError.invalidEndpoint }
        return url
    }
    /// Search independent catalogs concurrently so a slow server cannot delay others.
    /// Each request has its own timeout; responses are size-limited before decoding.
    func fetchAtPointFromCatalogs(latitude: Double, longitude: Double, catalogs: [String]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        available = []
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            message = "Некорректные координаты"
            return
        }
        let sources = Array(Set(catalogs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        guard !sources.isEmpty else {
            message = "Настройте хотя бы один HTTPS-каталог"
            return
        }
        var found: [PublishedPack] = []
        var keys = Set<String>()
        var failures = 0
        await withTaskGroup(of: Result<[PublishedPack], Error>.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        guard let base = URL(string: source), base.scheme == "https",
                              base.host != nil, base.user == nil, base.password == nil,
                              base.query == nil, base.fragment == nil,
                              var components = URLComponents(url: base.appendingPathComponent("v1/packs/at-point"), resolvingAgainstBaseURL: false)
                        else { throw StoreError.invalidEndpoint }
                        components.queryItems = [URLQueryItem(name: "lat", value: String(latitude)),
                                                 URLQueryItem(name: "lon", value: String(longitude))]
                        guard let url = components.url else { throw StoreError.invalidEndpoint }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 12
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              data.count <= 2_000_000 else { throw StoreError.invalidManifest }
                        return .success(try JSONDecoder().decode([PublishedPack].self, from: data).compactMap { item in
                            guard item.layers.contains("raster-mbtiles"),
                                  item.pack_id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
                                  item.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
                                  item.size_bytes > 0 else { return nil }
                            var pack = item
                            pack.catalog_url = base.absoluteString
                            return pack
                        })
                    } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let packs):
                    for pack in packs {
                        let key = "\(pack.catalog_url ?? "")|\(pack.pack_id)|\(pack.sha256)"
                        if keys.insert(key).inserted { found.append(pack) }
                    }
                case .failure: failures += 1
                }
            }
        }
        available = found.sorted { ($0.pack_id, $0.catalog_url ?? "") < ($1.pack_id, $1.catalog_url ?? "") }
        message = "Найдено пакетов: \(found.count) · ошибок источников: \(failures)"
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
    /// Search a licensed catalog for packages containing a map tap coordinate.
    /// An empty result is honest: a server is not a source of arbitrary tiles.
    func fetchAtPoint(latitude: Double, longitude: Double) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let base = try endpoint()
            guard (-90...90).contains(latitude), (-180...180).contains(longitude),
                  var components = URLComponents(url: base.appendingPathComponent("v1/packs/at-point"), resolvingAgainstBaseURL: false) else {
                throw StoreError.invalidEndpoint
            }
            components.queryItems = [URLQueryItem(name: "lat", value: String(latitude)), URLQueryItem(name: "lon", value: String(longitude))]
            guard let url = components.url else { throw StoreError.invalidEndpoint }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.invalidManifest }
            let items = try JSONDecoder().decode([PublishedPack].self, from: data)
            available = items.filter { $0.layers.contains("raster-mbtiles") && $0.pack_id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil }
            message = available.isEmpty ? "На сервере нет опубликованной карты для выбранной точки" : "Для точки найдено пакетов: \(available.count)"
        } catch { message = "Поиск по точке: \(error.localizedDescription)" }
    }
    /// Resume is persisted in a .part file. Only a fully verified SQLite pack becomes visible.
    /// A partial file is bound to the expected content hash, so changed manifests cannot corrupt it.
    func install(_ pack: PublishedPack) async {
        guard !busy else { return }; busy = true; progress = 0; defer { busy = false }
        do {
            let base = try endpoint(pack.catalog_url)
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
            guard try Self.sha256(file: partial).lowercased() == pack.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: partial)
                throw StoreError.badChecksum
            }
            guard RasterMBTiles.isSupported(partial) else { throw StoreError.unsupportedFormat }
            let staged = folder.appendingPathComponent("staging-\(UUID().uuidString).mbtiles")
            try FileManager.default.copyItem(at: partial, to: staged)
            let target = scopedPath(for: pack)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: target) }
            try? FileManager.default.removeItem(at: partial)
            installed.removeAll { $0.id == pack.id }
            installed.append(pack)
            try persist(); revision += 1
            message = "Карта установлена, SHA-256 проверен. Источник: \(pack.license)"
        } catch { message = "Установка: \(error.localizedDescription). Частичная загрузка сохранена для продолжения." }
    }
    /// Download a direct HTTPS raster MBTiles file inside the app, then validate and import it.
    /// Never fetches public OSM tile endpoints or pretends vector MBTiles are raster.
    func importFromHTTPS(_ rawURL: String) async {
        guard !busy else { return }
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil,
              url.pathExtension.lowercased() == "mbtiles" else {
            message = "Нужна прямая HTTPS-ссылка на растровый файл .mbtiles"
            return
        }
        busy = true
        defer { busy = false }
        progress = 0
        message = "Скачивание MBTiles…"
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 90
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            temporary = downloaded
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme?.lowercased() == "https" else { throw StoreError.unsupportedFormat }
            let size = (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= 2_000_000_000 else { throw StoreError.unsupportedFormat }
            guard RasterMBTiles.isSupported(downloaded) else {
                message = "Файл не является растровым MBTiles (PNG/JPEG/WebP). Векторный MBTiles пока не поддерживается."
                return
            }
            let digest = try Self.sha256(file: downloaded)
            let packID = "web-" + String(digest.prefix(24))
            let pack = PublishedPack(pack_id: packID, scope: "region", scope_id: "REMOTE",
                size_bytes: size, sha256: digest, source_version: "direct-https",
                license: "Лицензия источника не проверена", verified: false,
                layers: ["raster-mbtiles"])
            let destination = scopedPath(for: pack)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let capacity, Int64(capacity) < size + 100_000_000 { throw StoreError.notEnoughStorage }
                try FileManager.default.copyItem(at: downloaded, to: destination)
            }
            if !installed.contains(where: { $0.id == pack.id }) { installed.append(pack) }
            try persist()
            revision += 1
            progress = 1
            message = "Карта загружена и установлена. Проверьте лицензию источника."
        } catch {
            message = "Не удалось скачать карту: \(error.localizedDescription)"
        }
    }

    struct StaticCatalog: Decodable {
        let schema: String
        let packs: [StaticPack]
    }
    struct StaticPack: Decodable, Identifiable {
        struct Chunk: Decodable {
            let path: String
            let bytes: Int
            let sha256: String
        }
        let id: String
        let name: String
        let bounds: [Double]
        let bytes: Int64
        let sha256: String
        let chunks: [Chunk]
        let minzoom: Int
        let maxzoom: Int
        let attribution: String
    }
    @Published private(set) var staticPacks: [StaticPack] = []
    @Published var staticCatalogURL: String = ""

    private func staticCatalogEndpoint() throws -> URL {
        let value = staticCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.lastPathComponent == "catalog.json" else { throw StoreError.invalidEndpoint }
        return url
    }

    func loadStaticCatalog() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try staticCatalogEndpoint()
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", data.count < 5_000_000 else { throw StoreError.invalidManifest }
            let catalog = try JSONDecoder().decode(StaticCatalog.self, from: data)
            guard catalog.schema == "hunt-map-kz-static-v1" else { throw StoreError.invalidManifest }
            staticPacks = catalog.packs.filter { pack in
                pack.id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil &&
                pack.bytes > 0 && pack.bytes <= 20_000_000_000 &&
                pack.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil &&
                pack.bounds.count == 4 && pack.minzoom <= pack.maxzoom &&
                !pack.chunks.isEmpty && pack.chunks.count <= 100_000 &&
                pack.chunks.allSatisfy { $0.path.range(of: "^packs/[A-Za-z0-9_-]{1,80}/[0-9]{6}\\.part$", options: .regularExpression) != nil &&
                    $0.path.hasPrefix("packs/\(pack.id)/") && $0.bytes > 0 &&
                    $0.bytes <= 32 * 1024 * 1024 &&
                    $0.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil } &&
                pack.chunks.reduce(Int64(0)) { $0 + Int64($1.bytes) } == pack.bytes
            }
            message = "На хостинге найдено карт: \(staticPacks.count)"
        } catch { message = "Ошибка каталога: \(error.localizedDescription)" }
    }

    func installStaticPack(_ pack: StaticPack) async {
        guard !busy else { return }
        busy = true; progress = 0
        defer { busy = false }
        do {
            let catalogURL = try staticCatalogEndpoint()
            guard staticPacks.contains(where: { $0.id == pack.id && $0.sha256 == pack.sha256 }) else {
                throw StoreError.invalidManifest
            }
            let root = catalogURL.deletingLastPathComponent()
            let temp = folder.appendingPathComponent("static-\(pack.id)-\(pack.sha256).part")
            if !FileManager.default.fileExists(atPath: temp.path) {
                _ = FileManager.default.createFile(atPath: temp.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            var position = try handle.seekToEnd()
            if position > UInt64(pack.bytes) {
                try handle.truncate(atOffset: 0); position = 0
            }
            // A partial file is accepted only at a complete chunk boundary.
            var boundary: UInt64 = 0
            var startIndex = 0
            for (index, chunk) in pack.chunks.enumerated() {
                if boundary == position { startIndex = index }
                boundary += UInt64(chunk.bytes)
            }
            if position == UInt64(pack.bytes) { startIndex = pack.chunks.count }
            else if position != pack.chunks.prefix(startIndex).reduce(UInt64(0), { $0 + UInt64($1.bytes) }) {
                try handle.truncate(atOffset: 0); position = 0; startIndex = 0
            }
            for index in startIndex..<pack.chunks.count {
                try Task.checkCancellation()
                let chunk = pack.chunks[index]
                guard let url = URL(string: chunk.path, relativeTo: root)?.absoluteURL,
                      url.scheme == "https", url.host == root.host else { throw StoreError.invalidEndpoint }
                var request = URLRequest(url: url)
                request.timeoutInterval = 90
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", http.url?.host == root.host,
                      data.count == chunk.bytes,
                      Self.sha256(data: data).lowercased() == chunk.sha256.lowercased() else {
                    throw StoreError.badChecksum
                }
                try handle.write(contentsOf: data)
                position += UInt64(data.count)
                progress = Double(position) / Double(pack.bytes)
                message = "\(pack.name): \(Int(progress * 100))%"
            }
            try handle.synchronize()
            guard try Self.sha256(file: temp).lowercased() == pack.sha256.lowercased(),
                  RasterMBTiles.isSupported(temp) else { throw StoreError.badChecksum }
            let installedPack = PublishedPack(pack_id: pack.id, scope: "region", scope_id: "STATIC",
                size_bytes: pack.bytes, sha256: pack.sha256, source_version: "static-v1",
                license: pack.attribution, verified: true, layers: ["raster-mbtiles"],
                catalog_url: catalogURL.absoluteString)
            let target = scopedPath(for: installedPack)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else { try FileManager.default.moveItem(at: temp, to: target) }
            installed.removeAll { $0.pack_id == installedPack.pack_id && $0.catalog_url == installedPack.catalog_url }
            installed.append(installedPack)
            try persist(); revision += 1; progress = 1
            message = "Карта \(pack.name) установлена, SHA-256 проверен"
        } catch { message = "Загрузка карты: \(error.localizedDescription)" }
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            try FileManager.default.copyItem(at: incoming, to: temp)
            guard RasterMBTiles.isSupported(temp) else { throw StoreError.unsupportedFormat }
            let digest = try Self.sha256(file: temp)
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
        installed.removeAll { $0.id == pack.id }
        do { try persist(); revision += 1; message = "Карта удалена; личные точки и маршруты сохранены" }
        catch { message = "Не удалось обновить реестр: \(error.localizedDescription)" }
    }
    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var sha = SHA256()
        while true { let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data(); if chunk.isEmpty { break }; sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// One readonly SQLite connection per tile read. SQLite handles parallel readers safely.
enum RasterMBTiles {
    /// Read actual zoom limits: geographical bounds alone do not imply street-level coverage.
    static func zoomRange(_ url: URL) -> ClosedRange<Int>? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              sqlite3_column_type(stmt, 1) != SQLITE_NULL else { return nil }
        let lower = Int(sqlite3_column_int(stmt, 0))
        let upper = Int(sqlite3_column_int(stmt, 1))
        guard (0...22).contains(lower), (0...22).contains(upper), lower <= upper else { return nil }
        return lower...upper
    }
    /// MBTiles bounds are west,south,east,north in WGS84. Missing/invalid metadata is unknown coverage.
    static func covers(_ url: URL, latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name='bounds' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return false }
        let values = String(cString: raw).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4 else { return false }
        let (west, south, east, north) = (values[0], values[1], values[2], values[3])
        guard values.allSatisfy(\.isFinite), (-180...180).contains(west), (-180...180).contains(east),
              (-90...90).contains(south), (-90...90).contains(north), south <= north else { return false }
        let inLongitude = west <= east ? longitude >= west && longitude <= east : longitude >= west || longitude <= east
        return inLongitude && latitude >= south && latitude <= north
    }
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

