import Foundation
import SwiftUI
import CryptoKit
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
    private func digest(_ file: URL) throws -> String {
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
    private func transfer(_ url: URL, bytes: Int64, hash: String, destination: URL) async throws {
        guard bytes > 0, hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw HostingError.invalidCatalog }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == bytes,
              try digest(temporary).lowercased() == hash.lowercased() else { throw HostingError.corrupt }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: temporary, to: destination)
    }
    func installRoute(_ pack: HostingRoutingPack) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
            try checkCapacity(pack.bytes)
            let target = folder.appendingPathComponent(pack.id + ".geojson")
            try await transfer(try remote("routing/" + pack.path), bytes: pack.bytes, hash: pack.sha256, destination: target)
            // Verify that the file can actually be used by the current Swift routing engine.
            _ = try OfflineRouteGraph(geoJSON: Data(contentsOf: target))
            installedRoutes.insert(pack.id)
            try persist(); progress = 1
            status = "Дорожная сеть установлена: \(pack.name)"
        } catch { status = "Сеть дорог: \(error.localizedDescription)" }
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
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var downloaded: Int64 = 0
            for chunk in pack.chunks {
                try Task.checkCancellation()
                let (tmp, reply) = try await URLSession.shared.download(from: try remote(chunk.path))
                guard (reply as? HTTPURLResponse)?.statusCode == 200,
                      (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == chunk.bytes,
                      try digest(tmp).lowercased() == chunk.sha256.lowercased() else { throw HostingError.corrupt }
                let input = try FileHandle(forReadingFrom: tmp)
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
            guard try digest(temp).lowercased() == pack.sha256.lowercased() else { throw HostingError.corrupt }
            // Existing installer checks SQLite metadata and persists the map to its canonical location.
            await tiles.importLocal(temp)
            status = tiles.message
        } catch { status = "Карта: \(error.localizedDescription)" }
    }
    func installZones(_ pack: HostingZonePack, model: FieldModel) async {
        guard !busy else { return }; busy = true; progress = 0; activePack = pack.name
        defer { busy = false; activePack = "" }
        do {
            guard pack.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw HostingError.invalidPath }
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
            progress = 1
            status = "Зоны импортированы: \(imported.count). Юридический статус не подтверждён."
        } catch { status = "Границы: \(error.localizedDescription)" }
    }
    func downloadAll(tiles: OfflineTileStore, model: FieldModel) async {
        for pack in maps {
            if Task.isCancelled { break }
            if tiles.installed.contains(where: { $0.sha256.lowercased() == pack.sha256.lowercased() }) { continue }
            await installMap(pack, tiles: tiles)
        }
        for pack in routes where !installedRoutes.contains(pack.id) {
            if Task.isCancelled { break }
            await installRoute(pack)
        }
        for pack in zones {
            if Task.isCancelled { break }
            await installZones(pack, model: model)
        }
    }
    func removeRoute(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".geojson"))
        installedRoutes.remove(id)
        try? persist()
        status = "Дорожная сеть удалена"
    }
    // Intentionally limited to a selected area: nationwide graph does not fit into a single
    // OfflineRouteGraph (200k vertices) and cannot be represented as one in-memory file.
    func graph(start: GeoPoint, destination: GeoPoint) throws -> OfflineRouteGraph {
        let matching = routes.filter { pack in
            guard installedRoutes.contains(pack.id), pack.bounds.count == 4 else { return false }
            func near(_ pt: GeoPoint) -> Bool {
                pt.longitude >= pack.bounds[0] - 0.02 && pt.longitude <= pack.bounds[2] + 0.02 &&
                pt.latitude >= pack.bounds[1] - 0.02 && pt.latitude <= pack.bounds[3] + 0.02
            }
            return near(start) && near(destination)
        }
        guard !matching.isEmpty else { throw HostingError.noRoute }
        // A single verified package is guaranteed to remain under the per-graph import limit.
        let input = try Data(contentsOf: folder.appendingPathComponent(matching[0].id + ".geojson"))
        return try OfflineRouteGraph(geoJSON: input)
    }
}

struct HostingOfflineSheet: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @EnvironmentObject private var model: FieldModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("HTTPS: https://create.web-works.kz/maps/")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("Обновить каталоги") { Task { await hosting.refresh() } }
                    Text(hosting.status).font(.caption).foregroundStyle(.secondary)
                    if hosting.busy { ProgressView(hosting.activePack, value: hosting.progress) }
                } header: { Text("Источник данных") }
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
                    if hosting.routes.isEmpty { Text("Опубликованной сети нет").foregroundStyle(.secondary) }
                    ForEach(hosting.routes) { pack in
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
                            Button("Импорт") { Task { await hosting.installZones(pack, model: model) } }
                                .disabled(hosting.busy)
                        }
                    }
                }
                Section {
                    let total = hosting.maps.reduce(Int64(0), { $0 + $1.bytes }) + hosting.routes.reduce(Int64(0), { $0 + $1.bytes }) + hosting.zones.reduce(Int64(0), { $0 + $1.bytes })
                    Text("Общий объём опубликованных пакетов: \(String(format: "%.2f", Double(total) / 1_073_741_824)) ГБ. Для установки может потребоваться более чем вдвое больше свободного места.")
                        .font(.caption)
                    Button("Скачать всё") { Task { await hosting.downloadAll(tiles: tiles, model: model) } }
                        .disabled(hosting.busy || (hosting.maps.isEmpty && hosting.routes.isEmpty && hosting.zones.isEmpty))
                    Text("© OpenStreetMap contributors (ODbL). Доступность троп и права прохода необходимо проверять на местности. Для построения маршрута нужны сети в районе старта и цели.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Офлайн с хостинга")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
            .task { if hosting.maps.isEmpty && hosting.routes.isEmpty { await hosting.refresh() } }
        }
    }
}
