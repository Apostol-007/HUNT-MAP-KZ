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
    init() { restore() }

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
    private func transfer(_ url: URL, bytes: Int64, hash: String, destination: URL) async throws {
        guard bytes > 0, hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw HostingError.invalidCatalog }
        if FileManager.default.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == bytes,
           (try? await HuntBackgroundWork.digest(destination).lowercased()) == hash.lowercased() { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == bytes,
              try await HuntBackgroundWork.digest(temporary).lowercased() == hash.lowercased() else { throw HostingError.corrupt }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".incoming")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await HuntBackgroundWork.run {
            try FileManager.default.copyItem(at: temporary, to: staged)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
    func needsRouteUpdate(_ pack: HostingRoutingPack) async -> Bool {
        let file = folder.appendingPathComponent(pack.id + ".geojson")
        guard FileManager.default.fileExists(atPath: file.path),
              let found = try? await HuntBackgroundWork.digest(file) else { return true }
        return found.lowercased() != pack.sha256.lowercased()
    }
    func needsZoneUpdate(_ pack: HostingZonePack) async -> Bool {
        let file = folder.appendingPathComponent("zones/" + pack.id + ".geojson")
        guard FileManager.default.fileExists(atPath: file.path),
              let found = try? await HuntBackgroundWork.digest(file) else { return true }
        return found.lowercased() != pack.sha256.lowercased()
    }
    func installRoute(_ pack: HostingRoutingPack) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
            if !(await needsRouteUpdate(pack)) {
                installedRoutes.insert(pack.id)
                status = "Дорожная сеть актуальна: \(pack.name)"; progress = 1; return
            }
            try checkCapacity(pack.bytes)
            let target = folder.appendingPathComponent(pack.id + ".geojson")
            try await transfer(try remote("routing/" + pack.path), bytes: pack.bytes, hash: pack.sha256, destination: target)
            // A pack can contain only roads or only footpaths; either travel mode is valid.
            let valid = try await HuntBackgroundWork.run {
                let contents = try Data(contentsOf: target)
                if (try? OfflineRouteGraph(geoJSON: contents, mode: .foot)) != nil { return true }
                return (try? OfflineRouteGraph(geoJSON: contents, mode: .car)) != nil
            }
            guard valid else { throw OfflineRouteGraph.RouteError.emptyNetwork }
            installedRoutes.insert(pack.id)
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
            var downloaded: Int64 = 0
            for chunk in pack.chunks {
                try Task.checkCancellation()
                guard chunk.bytes > 0,
                      chunk.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
                else { throw HostingError.invalidCatalog }
                let chunkFile = folder.appendingPathComponent("verified-chunks", isDirectory: true)
                    .appendingPathComponent(chunk.sha256.lowercased() + ".chunk")
                try await transfer(try remote(chunk.path), bytes: chunk.bytes, hash: chunk.sha256, destination: chunkFile)
                try await HuntBackgroundWork.append(chunkFile, to: temp)
                downloaded += chunk.bytes
                progress = Double(downloaded) / Double(pack.bytes)
            }
            guard try await HuntBackgroundWork.digest(temp).lowercased() == pack.sha256.lowercased() else { throw HostingError.corrupt }
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
            if !(await needsZoneUpdate(pack)) {
                installedZones.insert(pack.id)
                status = "Границы актуальны: \(pack.name)"; progress = 1; return
            }
            try checkCapacity(pack.bytes)
            let target = folder.appendingPathComponent("zones/" + pack.id + ".geojson")
            try await transfer(try remote("zones/" + pack.path), bytes: pack.bytes, hash: pack.sha256, destination: target)
            // Import only validated polygon geometries; never substitute routing roads as hunting grounds.
            var imported: [GeoZone] = []
            let directory = folder.appendingPathComponent("zones")
            for file in (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
                where file.pathExtension.lowercased() == "geojson" {
                imported += try GeoJSONImport.load(file)
            }
            model.setImportedZones(imported)
            installedZones.insert(pack.id)
            progress = 1
            status = "Зоны импортированы: \(imported.count). Юридический статус не подтверждён."
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Обновление границ", error: error, endpoint: "create.web-works.kz/maps/zones", usedCache: !installedZones.isEmpty)
            status = "Границы: \(error.localizedDescription)"
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

    /// Merge only installed packages intersecting the start-to-destination corridor.
    /// A strict 200k-vertex limit prevents loading an entire nationwide graph into memory.
    func graph(start: GeoPoint, destination: GeoPoint, mode: OfflineRouteGraph.TravelMode = .foot) async throws -> OfflineRouteGraph {
        let margin = 0.03
        let west = min(start.longitude, destination.longitude) - margin
        let east = max(start.longitude, destination.longitude) + margin
        let south = min(start.latitude, destination.latitude) - margin
        let north = max(start.latitude, destination.latitude) + margin
        let matching = routes.filter { pack in
            guard installedRoutes.contains(pack.id), pack.bounds.count == 4 else { return false }
            return pack.bounds[0] <= east && pack.bounds[2] >= west &&
                   pack.bounds[1] <= north && pack.bounds[3] >= south
        }
        guard !matching.isEmpty else { throw HostingError.noRoute }
        let directory = folder
        let urls = matching.map { directory.appendingPathComponent($0.id + ".geojson") }
        return try await HuntBackgroundWork.run {
            // Bound input memory before decoding. Never silently omit missing road packs.
            var totalBytes: Int64 = 0
            for url in urls {
                try Task.checkCancellation()
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                totalBytes += Int64(size)
                guard totalBytes <= 32 * 1024 * 1024 else { throw OfflineRouteGraph.RouteError.tooLarge }
            }
            let parts = try urls.map {
                try Task.checkCancellation()
                return try Data(contentsOf: $0, options: .mappedIfSafe)
            }
            return try OfflineRouteGraph(geoJSONParts: parts, mode: mode)
        }
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