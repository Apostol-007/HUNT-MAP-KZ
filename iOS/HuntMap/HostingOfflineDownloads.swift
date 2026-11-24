import Foundation
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import HuntCore

/// Static HTTPS distribution: no server-side API, passwords, or remote executable content.
private enum HostingConfiguration {
    static let base = URL(string: "https://create.web-works.kz/maps/")!
}

private struct HostingMapCatalog: Decodable {
    let schema: String
    let packs: [HostingMapPack]
}
struct HostingMapPack: Decodable, Identifiable {
    struct Chunk: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    let id: String
    let name: String
    let type: String
    let bytes: Int64
    let sha256: String
    let chunks: [Chunk]
    let bounds: [Double]?
    let attribution: String?
}
private struct HostingRoutingCatalog: Decodable {
    let schema: String
    let packs: [HostingRoutingPack]
}
struct HostingRoutingPack: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let type: String
    let bounds: [Double]
    let bytes: Int64
    let sha256: String
    let feature_count: Int
}

private struct HostingZonesCatalog: Decodable {
    let schema: String
    let packs: [HostingZonePack]
}
struct HostingZonePack: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let type: String
    let bytes: Int64
    let sha256: String
    let feature_count: Int
}

@MainActor final class HostingOfflineDownloads: ObservableObject {
    @Published private(set) var maps: [HostingMapPack] = []
    @Published private(set) var routes: [HostingRoutingPack] = []
    @Published private(set) var zones: [HostingZonePack] = []
    @Published private(set) var installedRoutes: Set<String> = []
    @Published private(set) var installedZones: Set<String> = []
    @Published var searchText = ""
    @Published var onlyNotInstalled = false
    @Published private(set) var completedPacks = 0
    @Published private(set) var plannedPacks = 0
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Каталог не загружен"
    @Published private(set) var activePack = ""

    // The public HTTPS origin is built into the app; FTP credentials are NEVER used on iOS.
    private var folder: URL {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routing/hosting", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    /// Last verified manifest receipt. A same-size file with a changed modification
    /// date is rehashed; even unchanged packages are audited again after seven days.
    private struct VerifiedReceipt: Codable {
        let sha256: String
        let size: Int64
        let modifiedAt: TimeInterval
        let validatedAt: TimeInterval
    }
    private var receipts: [String: VerifiedReceipt] = [:]
    private var receiptsURL: URL { folder.appendingPathComponent("verified-receipts.json") }
    private func validatedReceipt(_ file: URL, key: String, hash: String, size: Int64) -> Bool {
        guard let receipt = receipts[key],
              receipt.sha256 == hash.lowercased(), receipt.size == size,
              Date().timeIntervalSince1970 - receipt.validatedAt < 7 * 24 * 3600,
              let properties = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let actualSize = properties.fileSize,
              let modified = properties.contentModificationDate else { return false }
        return Int64(actualSize) == size &&
            abs(modified.timeIntervalSince1970 - receipt.modifiedAt) < 0.001
    }
    private func saveReceipt(_ file: URL, key: String, hash: String, size: Int64) {
        guard let properties = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let actualSize = properties.fileSize, Int64(actualSize) == size,
              let modified = properties.contentModificationDate else { return }
        receipts[key] = VerifiedReceipt(sha256: hash.lowercased(), size: size,
            modifiedAt: modified.timeIntervalSince1970,
            validatedAt: Date().timeIntervalSince1970)
        persistReceipts()
    }
    private func persistReceipts() {
        if let bytes = try? JSONEncoder().encode(receipts) {
            try? bytes.write(to: receiptsURL, options: .atomic)
        }
    }
    init() {
        if let bytes = try? Data(contentsOf: receiptsURL),
           let saved = try? JSONDecoder().decode([String: VerifiedReceipt].self, from: bytes) {
            receipts = saved
        }
        restore()
    }

    private func restore() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("maps-catalog.json")),
           let catalog = try? JSONDecoder().decode(HostingMapCatalog.self, from: data),
           catalog.schema == "hunt-map-kz-static-v1" {
            maps = catalog.packs.filter { $0.type == "raster-mbtiles" }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("zones-catalog.json")),
           let catalog = try? JSONDecoder().decode(HostingZonesCatalog.self, from: data),
           catalog.schema == "hunt-map-kz-zones-v1" {
            zones = catalog.packs.filter { $0.type == "hunting-zones-geojson" }
        }
        let zoneFolder = folder.appendingPathComponent("zones", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: zoneFolder.path) {
            installedZones = Set(names.filter { $0.hasSuffix(".geojson") }.map { String($0.dropLast(8)) })
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("installed.json")),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            installedRoutes = Set(ids.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".geojson").path) })
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("routing-catalog.json")),
           let catalog = try? JSONDecoder().decode(HostingRoutingCatalog.self, from: data),
           catalog.schema == "hunt-map-kz-routing-v1" {
            routes = catalog.packs
        }
    }
    private func persist() throws {
        try JSONEncoder().encode(Array(installedRoutes).sorted()).write(to: folder.appendingPathComponent("installed.json"), options: .atomic)
    }
    private func remote(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }),
              !relative.contains("\\") else { throw HostingError.invalidPath }
        return parts.reduce(HostingConfiguration.base) { $0.appendingPathComponent($1) }
    }
    enum HostingError: LocalizedError {
        case invalidPath, invalidCatalog, corrupt, noSpace, noRoute
        var errorDescription: String? {
            switch self {
            case .invalidPath: "Некорректный путь файла в каталоге"
            case .invalidCatalog: "Неверный или недоступный каталог пакетов"
            case .corrupt: "Размер или контрольная сумма загруженного пакета не совпадают"
            case .noSpace: "Недостаточно свободного места на iPhone"
            case .noRoute: "Для этой области офлайн-сеть ещё не загружена"
            }
        }
    }
    private func fetchData(_ path: String) async throws -> Data {
        var request = URLRequest(url: try remote(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        let (data, reply) = try await URLSession.shared.data(for: request)
        guard (reply as? HTTPURLResponse)?.statusCode == 200 else { throw HostingError.invalidCatalog }
        return data
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let mapData = try await fetchData("catalog.json")
            let mapCatalog = try JSONDecoder().decode(HostingMapCatalog.self, from: mapData)
            guard mapCatalog.schema == "hunt-map-kz-static-v1" else { throw HostingError.invalidCatalog }
            maps = mapCatalog.packs.filter { $0.type == "raster-mbtiles" }
            try mapData.write(to: folder.appendingPathComponent("maps-catalog.json"), options: .atomic)
            status = "Каталог карт обновлён: \(maps.count) пакетов"
        } catch {
            status = "Каталог карт недоступен: \(error.localizedDescription). Показаны ранее сохранённые пакеты."
        }
        do {
            let routeData = try await fetchData("routing/catalog.json")
            let catalog = try JSONDecoder().decode(HostingRoutingCatalog.self, from: routeData)
            guard catalog.schema == "hunt-map-kz-routing-v1" else { throw HostingError.invalidCatalog }
            routes = catalog.packs.filter { $0.type == "routing-geojson" }
            try routeData.write(to: folder.appendingPathComponent("routing-catalog.json"), options: .atomic)
            status = "Карты: \(maps.count), сети дорог: \(routes.count)"
        } catch {
            status += ". Сеть дорог: \(error.localizedDescription) (сохранённый каталог остаётся доступен)"
        }
        do {
            let data = try await fetchData("zones/catalog.json")
            let catalog = try JSONDecoder().decode(HostingZonesCatalog.self, from: data)
            guard catalog.schema == "hunt-map-kz-zones-v1" else { throw HostingError.invalidCatalog }
            zones = catalog.packs.filter { $0.type == "hunting-zones-geojson" }
            try data.write(to: folder.appendingPathComponent("zones-catalog.json"), options: .atomic)
        } catch {
            // Zones are optional; retain any previously cached catalog when offline.
        }
    }
    private func checkCapacity(_ bytes: Int64) throws {
        let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, Int64(available) < bytes * 2 + 50_000_000 { throw HostingError.noSpace }
    }
    nonisolated private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let part = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if part.isEmpty { break }
            hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func digestAsync(_ file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.digest(file)
        }.value
    }
    func needsRouteUpdateAsync(_ pack: HostingRoutingPack) async -> Bool {
        let file = folder.appendingPathComponent(pack.id + ".geojson")
        guard FileManager.default.fileExists(atPath: file.path),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize),
              Int64(size) == pack.bytes else { return true }
        if validatedReceipt(file, key: "route:" + pack.id, hash: pack.sha256, size: pack.bytes) { return false }
        guard let found = try? await digestAsync(file) else { return true }
        if found.lowercased() == pack.sha256.lowercased() {
            saveReceipt(file, key: "route:" + pack.id, hash: pack.sha256, size: pack.bytes)
            return false
        }
        return true
    }
    func needsZoneUpdateAsync(_ pack: HostingZonePack) async -> Bool {
        let file = folder.appendingPathComponent("zones/" + pack.id + ".geojson")
        guard FileManager.default.fileExists(atPath: file.path),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize),
              Int64(size) == pack.bytes else { return true }
        if validatedReceipt(file, key: "zone:" + pack.id, hash: pack.sha256, size: pack.bytes) { return false }
        guard let found = try? await digestAsync(file) else { return true }
        if found.lowercased() == pack.sha256.lowercased() {
            saveReceipt(file, key: "zone:" + pack.id, hash: pack.sha256, size: pack.bytes)
            return false
        }
        return true
    }
    private func transfer(_ url: URL, bytes: Int64, hash: String, destination: URL) async throws {
        guard bytes > 0, hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw HostingError.invalidCatalog }
        if FileManager.default.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == bytes,
           (try? await digestAsync(destination).lowercased()) == hash.lowercased() { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == bytes,
              try await digestAsync(temporary).lowercased() == hash.lowercased() else { throw HostingError.corrupt }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".incoming")
        try FileManager.default.copyItem(at: temporary, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
    // The synchronous UI queries never hash multi-GB packages. The async
    // verification path performs SHA-256 when the receipt is absent or expired.
    func needsRouteUpdate(_ pack: HostingRoutingPack) -> Bool {
        !validatedReceipt(folder.appendingPathComponent(pack.id + ".geojson"),
            key: "route:" + pack.id, hash: pack.sha256, size: pack.bytes)
    }
    func needsZoneUpdate(_ pack: HostingZonePack) -> Bool {
        !validatedReceipt(folder.appendingPathComponent("zones/" + pack.id + ".geojson"),
            key: "zone:" + pack.id, hash: pack.sha256, size: pack.bytes)
    }
    func installRoute(_ pack: HostingRoutingPack) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
            if !(await needsRouteUpdateAsync(pack)) {
                installedRoutes.insert(pack.id)
                status = "Дорожная сеть актуальна: \(pack.name)"; progress = 1; return
            }
            try checkCapacity(pack.bytes)
            let target = folder.appendingPathComponent(pack.id + ".geojson")
            try await transfer(try remote("routing/" + pack.path), bytes: pack.bytes, hash: pack.sha256, destination: target)
            // A pack can contain only roads or only footpaths; either travel mode is valid.
            let valid = try await Task.detached(priority: .utility) {
                let contents = try Data(contentsOf: target, options: .mappedIfSafe)
                let walkable = (try? OfflineRouteGraph(geoJSON: contents, mode: .foot)) != nil
                let drivable = (try? OfflineRouteGraph(geoJSON: contents, mode: .car)) != nil
                return walkable || drivable
            }.value
            guard valid else { throw OfflineRouteGraph.RouteError.emptyNetwork }
            installedRoutes.insert(pack.id)
            saveReceipt(target, key: "route:" + pack.id, hash: pack.sha256, size: pack.bytes)
            try persist(); progress = 1
            status = "Дорожная сеть установлена: \(pack.name)"
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Обновление дорог и троп", error: error, endpoint: "create.web-works.kz/maps/routing", usedCache: !installedRoutes.isEmpty)
            status = "Сеть дорог: \(error.localizedDescription)"
        }
    }
    func installMap(_ pack: HostingMapPack, tiles: OfflineTileStore) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        let temp = folder.appendingPathComponent("map-" + UUID().uuidString + ".mbtiles")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
            try checkCapacity(pack.bytes)
            guard !pack.chunks.isEmpty, pack.chunks.reduce(Int64(0), { $0 + $1.bytes }) == pack.bytes else { throw HostingError.invalidCatalog }
            // Each verified chunk persists across launches; failed chunks are downloaded again.
            // A completed MBTiles file is assembled only after all chunks pass SHA-256.
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var downloaded: Int64 = 0
            for chunk in pack.chunks {
                try Task.checkCancellation()
                guard chunk.bytes > 0,
                      chunk.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
                else { throw HostingError.invalidCatalog }
                let chunkFile = folder.appendingPathComponent("verified-chunks", isDirectory: true)
                    .appendingPathComponent(chunk.sha256.lowercased() + ".chunk")
                try await transfer(try remote(chunk.path), bytes: chunk.bytes, hash: chunk.sha256, destination: chunkFile)
                let input = try FileHandle(forReadingFrom: chunkFile)
                defer { try? input.close() }
                while true {
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                }
                downloaded += chunk.bytes
                progress = Double(downloaded) / Double(pack.bytes)
            }
            try output.synchronize()
            guard try await digestAsync(temp).lowercased() == pack.sha256.lowercased() else { throw HostingError.corrupt }
            // Existing installer checks SQLite metadata and persists the map to its canonical location.
            await tiles.importLocal(temp)
            status = tiles.message
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Установка MBTiles", error: error, endpoint: "create.web-works.kz/maps/packs")
            status = "Карта: \(error.localizedDescription)"
        }
    }
    func installZones(_ pack: HostingZonePack, model: FieldModel) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
            if !(await needsZoneUpdateAsync(pack)) {
                installedZones.insert(pack.id)
                status = "Границы актуальны: \(pack.name)"; progress = 1; return
            }
            try checkCapacity(pack.bytes)
            let target = folder.appendingPathComponent("zones/" + pack.id + ".geojson")
            try await transfer(try remote("zones/" + pack.path), bytes: pack.bytes, hash: pack.sha256, destination: target)
            // Import only validated polygon geometries; never substitute routing roads as hunting grounds.
            let directory = folder.appendingPathComponent("zones")
            let imported = try await Task.detached(priority: .utility) {
                var collected: [GeoZone] = []
                for file in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ) where file.pathExtension.lowercased() == "geojson" {
                    try Task.checkCancellation()
                    collected += try GeoJSONImport.load(file)
                }
                return collected
            }.value
            model.setImportedZones(imported)
            installedZones.insert(pack.id)
            saveReceipt(target, key: "zone:" + pack.id, hash: pack.sha256, size: pack.bytes)
            progress = 1
            status = "Зоны импортированы: \(imported.count). Юридический статус не подтверждён."
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Обновление границ", error: error, endpoint: "create.web-works.kz/maps/zones", usedCache: !installedZones.isEmpty)
            status = "Границы: \(error.localizedDescription)"
        }
    }
    func routePacks(in cells: [OfflineGridCell]) -> [HostingRoutingPack] {
        guard !cells.isEmpty else { return [] }
        return routes.filter { pack in cells.contains(where: { $0.intersects(pack.bounds) }) }
    }

    func mapPacks(in cells: [OfflineGridCell]) -> [HostingMapPack] {
        guard !cells.isEmpty else { return [] }
        return maps.filter { pack in
            guard let bounds = pack.bounds else { return false }
            return cells.contains(where: { $0.intersects(bounds) })
        }
    }

    /// Download only catalogue packages intersecting the selected WGS84 grid cells.
    /// GeoJSON roads and raster MBTiles remain different data types.
    func downloadGrid(cells: [OfflineGridCell], tiles: OfflineTileStore) async {
        guard !busy else { return }
        let chosenMaps = mapPacks(in: cells).filter { pack in
            !tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() })
        }
        let chosenRoutes = routePacks(in: cells).filter { !installedRoutes.contains($0.id) }
        plannedPacks = chosenMaps.count + chosenRoutes.count
        completedPacks = 0
        if plannedPacks == 0 {
            status = "В выбранной сетке нет новых пакетов с координатными границами"
            return
        }
        for pack in chosenMaps {
            if Task.isCancelled { break }
            await installMap(pack, tiles: tiles)
            completedPacks += 1
        }
        for pack in chosenRoutes {
            if Task.isCancelled { break }
            await installRoute(pack)
            completedPacks += 1
        }
        if Task.isCancelled {
            status = "Загрузка сетки остановлена, установленные файлы сохранены"
        } else {
            status += " · обработано \(completedPacks) из \(plannedPacks)"
        }
    }

    func downloadAll(tiles: OfflineTileStore, model: FieldModel) async {
        let pendingMaps = maps.filter { pack in
            !tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() })
        }
        let pendingRoutes = routes.filter { !installedRoutes.contains($0.id) }
        let pendingZones = zones.filter { !installedZones.contains($0.id) }
        plannedPacks = pendingMaps.count + pendingRoutes.count + pendingZones.count
        completedPacks = 0
        for pack in pendingMaps {
            if Task.isCancelled { break }
            await installMap(pack, tiles: tiles)
            completedPacks += 1
        }
        for pack in pendingRoutes {
            if Task.isCancelled { break }
            await installRoute(pack)
            completedPacks += 1
        }
        for pack in pendingZones {
            if Task.isCancelled { break }
            await installZones(pack, model: model)
            completedPacks += 1
        }
        if Task.isCancelled { status = "Загрузка остановлена; готовые пакеты сохранены" }
    }
    func reportLocalImportError(_ text: String) {
        status = "Ошибка выбора MBTiles: \(text)"
    }
    func removeZone(_ id: String, model: FieldModel) {
        guard id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { return }
        let target = folder.appendingPathComponent("zones/" + id + ".geojson")
        do {
            try FileManager.default.removeItem(at: target)
            installedZones.remove(id)
            receipts.removeValue(forKey: "zone:" + id)
            persistReceipts()
            var imported: [GeoZone] = []
            let directory = folder.appendingPathComponent("zones")
            for file in (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
                where file.pathExtension.lowercased() == "geojson" {
                imported += try GeoJSONImport.load(file)
            }
            model.setImportedZones(imported)
            status = "Пакет границ удалён"
        } catch { status = "Ошибка удаления зон: \(error.localizedDescription)" }
    }
    func removeRoute(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".geojson"))
        installedRoutes.remove(id)
        receipts.removeValue(forKey: "route:" + id)
        persistReceipts()
        try? persist()
        status = "Дорожная сеть удалена"
    }
    /// Return only downloaded GeoJSON files covering the visible map area.
    func installedRoadFiles(in bounds: [Double]) -> [URL] {
        guard bounds.count == 4 else { return [] }
        return routes.filter { pack in
            guard installedRoutes.contains(pack.id), pack.bounds.count == 4 else { return false }
            return pack.bounds[0] <= bounds[2] && pack.bounds[2] >= bounds[0] &&
                   pack.bounds[1] <= bounds[3] && pack.bounds[3] >= bounds[1]
        }.map { folder.appendingPathComponent($0.id + ".geojson") }
         .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Prepare the same bounded corridor graph away from UIKit. Both file reads
    /// and GeoJSON parsing are expensive for multi-megabyte offline networks.
    func graphAsync(start: GeoPoint, destination: GeoPoint,
                    mode: OfflineRouteGraph.TravelMode = .foot) async throws -> OfflineRouteGraph {
        let margin = 0.03
        let west = min(start.longitude, destination.longitude) - margin
        let east = max(start.longitude, destination.longitude) + margin
        let south = min(start.latitude, destination.latitude) - margin
        let north = max(start.latitude, destination.latitude) + margin
        let files = routes.filter { pack in
            guard installedRoutes.contains(pack.id), pack.bounds.count == 4 else { return false }
            return pack.bounds[0] <= east && pack.bounds[2] >= west &&
                   pack.bounds[1] <= north && pack.bounds[3] >= south
        }.map { folder.appendingPathComponent($0.id + ".geojson") }
        guard !files.isEmpty else { throw HostingError.noRoute }
        return try await Task.detached(priority: .userInitiated) {
            var parts: [Data] = []
            for file in files {
                try Task.checkCancellation()
                parts.append(try Data(contentsOf: file, options: .mappedIfSafe))
            }
            return try OfflineRouteGraph(geoJSONParts: parts, mode: mode)
        }.value
    }
}

struct HostingOfflineSheet: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @EnvironmentObject private var model: FieldModel
    @Environment(\.dismiss) private var dismiss
    @State private var bulkTask: Task<Void, Never>?
    @State private var importingLocalMap = false
    @AppStorage("hunt.onlineBasemap") private var onlineBasemap = true

    private var visibleRoutes: [HostingRoutingPack] {
        hosting.routes.filter { pack in
            (!hosting.onlyNotInstalled || !hosting.installedRoutes.contains(pack.id)) &&
            (hosting.searchText.isEmpty || pack.name.localizedCaseInsensitiveContains(hosting.searchText) || pack.id.localizedCaseInsensitiveContains(hosting.searchText))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("HTTPS: https://create.web-works.kz/maps/")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("Обновить каталоги") { Task { await hosting.refresh() } }
                    Text(hosting.status).font(.caption).foregroundStyle(.secondary)
                    if hosting.busy { ProgressView(hosting.activePack, value: hosting.progress) }
                    if hosting.plannedPacks > 0 {
                        Text("Обработано пакетов: \(hosting.completedPacks)/\(hosting.plannedPacks)")
                            .font(.caption.monospacedDigit())
                    }
                } header: { Text("Источник данных") }
                Section("Картографическая подложка") {
                    Toggle("Онлайн-подложка", isOn: $onlineBasemap)
                    Button("Импортировать MBTiles из файлов iPhone") { importingLocalMap = true }
                    Text("Установлено растровых MBTiles: \(tiles.installed.count). Дорожные GeoJSON не содержат изображение карты.")
                        .font(.caption).foregroundStyle(.secondary)
                    if tiles.installed.isEmpty {
                        Text("Офлайн-карта отсутствует. Публикуй MBTiles и catalog.json через Windows MAP MANAGER либо импортируй MBTiles локально. Скачивание только routing/catalog.json не создаёт подложку.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(tiles.message).font(.caption).foregroundStyle(.secondary)
                }
                Section("Офлайн-карты (MBTiles)") {
                    if hosting.maps.isEmpty { Text("Опубликованных карт нет").foregroundStyle(.secondary) }
                    ForEach(hosting.maps) { pack in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pack.name).font(.subheadline.bold())
                                Text("\(pack.bytes / 1_048_576) МБ").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() }) {
                                Label("Установлена", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            } else {
                                Button("Скачать") { Task { await hosting.installMap(pack, tiles: tiles) } }
                                    .disabled(hosting.busy)
                            }
                        }
                    }
                }
                Section("Дороги и тропы (OSM)") {
                    Toggle("Только неустановленные", isOn: $hosting.onlyNotInstalled)
                    TextField("Поиск по названию или ID", text: $hosting.searchText)
                        .textInputAutocapitalization(.never)
                    Text("Показано: \(visibleRoutes.count) из \(hosting.routes.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    if hosting.routes.isEmpty { Text("Опубликованной сети нет").foregroundStyle(.secondary) }
                    ForEach(visibleRoutes) { pack in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pack.name).font(.subheadline)
                                Text("\(pack.bytes / 1024) КБ").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hosting.installedRoutes.contains(pack.id) {
                                Button(role: .destructive) { hosting.removeRoute(pack.id) } label: { Image(systemName: "trash") }
                            } else {
                                Button("Скачать") { Task { await hosting.installRoute(pack) } }
                                    .disabled(hosting.busy)
                            }
                        }
                    }
                }
                Section("Границы охотугодий (только собственные источники)") {
                    if hosting.zones.isEmpty { Text("Подтверждённых пакетов границ нет").foregroundStyle(.secondary) }
                    ForEach(hosting.zones) { pack in
                        HStack {
                            Text(pack.name).font(.subheadline)
                            Spacer()
                            if hosting.installedZones.contains(pack.id) {
                                Button(role: .destructive) { hosting.removeZone(pack.id, model: model) } label: {
                                    Image(systemName: "trash")
                                }.disabled(hosting.busy)
                            } else {
                                Button("Импорт") { Task { await hosting.installZones(pack, model: model) } }
                                    .disabled(hosting.busy)
                            }
                        }
                    }
                }
                Section {
                    let total = hosting.maps.reduce(Int64(0), { $0 + $1.bytes }) + hosting.routes.reduce(Int64(0), { $0 + $1.bytes }) + hosting.zones.reduce(Int64(0), { $0 + $1.bytes })
                    Text("Общий объём опубликованных пакетов: \(String(format: "%.2f", Double(total) / 1_073_741_824)) ГБ. Для установки может потребоваться более чем вдвое больше свободного места.")
                        .font(.caption)
                    if bulkTask == nil {
                        Button("Скачать недостающие пакеты") {
                            bulkTask = Task {
                                await hosting.downloadAll(tiles: tiles, model: model)
                                bulkTask = nil
                            }
                        }
                        .disabled(hosting.busy || (hosting.maps.isEmpty && hosting.routes.isEmpty && hosting.zones.isEmpty))
                    } else {
                        Button("Остановить после текущего файла", role: .destructive) {
                            bulkTask?.cancel()
                        }
                    }
                    Text("© OpenStreetMap contributors (ODbL). Доступность троп и права прохода необходимо проверять на местности. Для построения маршрута нужны сети в районе старта и цели.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Офлайн с хостинга")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
            .task { if hosting.maps.isEmpty && hosting.routes.isEmpty { await hosting.refresh() } }
            .fileImporter(isPresented: $importingLocalMap,
                          allowedContentTypes: [UTType(filenameExtension: "mbtiles") ?? .data]) { result in
                switch result {
                case .success(let url): Task { await tiles.importLocal(url) }
                case .failure(let error): hosting.reportLocalImportError(error.localizedDescription)
                }
            }
        }
    }
}