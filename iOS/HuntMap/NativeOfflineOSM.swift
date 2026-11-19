import Foundation
import HuntCore

/// A bounded, locally stored OpenStreetMap feature extract. This is not a raster basemap.
struct OSMOfflineLine: Codable, Identifiable {
    let id: Int64
    let kind: String
    let points: [GeoPoint]
}

struct OSMDownloadedRegion: Codable, Identifiable {
    let id: UUID
    let title: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let downloadedAt: Date
    let featureCount: Int
}

@MainActor final class NativeOfflineOSM: ObservableObject {
    @Published private(set) var lines: [OSMOfflineLine] = []
    @Published private(set) var regions: [OSMDownloadedRegion] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "Детальные дороги и тропы не загружены"
    @Published private(set) var revision = 0
    @Published private(set) var lastDownloadError: String? = nil
    @Published private(set) var lastHTTPStatus: Int? = nil
    @Published private(set) var lastServer: String? = nil
    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!
    ]
    private var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSMOffline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var legacyIndex: URL { directory.appendingPathComponent("features.json") }
    private var regionIndex: URL { directory.appendingPathComponent("regions.json") }
    private func file(for id: UUID) -> URL { directory.appendingPathComponent("region-\(id.uuidString).json") }

    init() { restore() }

    private func restore() {
        if let data = try? Data(contentsOf: regionIndex),
           let decoded = try? JSONDecoder().decode([OSMDownloadedRegion].self, from: data) {
            regions = decoded
        }
        rebuildLines()
        // Old v1.7.7 feature store remains readable, without rewriting or losing user data.
        if FileManager.default.fileExists(atPath: legacyIndex.path) {
            status = "Сохранённые районы: \(regions.count). Есть данные старой версии."
        }
    }

    private func rebuildLines() {
        var combined: [Int64: OSMOfflineLine] = [:]
        if let data = try? Data(contentsOf: legacyIndex),
           let old = try? JSONDecoder().decode([OSMOfflineLine].self, from: data) {
            for line in old { combined[line.id] = line }
        }
        for region in regions {
            guard let data = try? Data(contentsOf: file(for: region.id)),
                  let features = try? JSONDecoder().decode([OSMOfflineLine].self, from: data) else { continue }
            for line in features { combined[line.id] = line }
        }
        lines = combined.values.sorted { $0.id < $1.id }
        revision += 1
        status = "Локально: \(lines.count) объектов, районов: \(regions.count)"
    }

    func download(around point: GeoPoint, radiusMeters: Int = 1500, title: String = "") async {
        guard !busy else { return }
        busy = true
        lastDownloadError = nil
        lastHTTPStatus = nil
        lastServer = nil
        defer { busy = false }
        let radius = min(10_000, max(500, radiusMeters))
        guard (-85...85).contains(point.latitude), (-180...180).contains(point.longitude) else {
            lastDownloadError = "Некорректные координаты"
            status = lastDownloadError!
            return
        }
        // Large regions are fetched in bounded cells. Every successful cell is
        // committed independently, so a later server failure cannot lose progress.
        let cellRadius = 1200
        let strideMeters = 1700.0
        let steps = radius <= 1200 ? 0 : Int(ceil(Double(radius) / strideMeters))
        var cells: [(GeoPoint, Int)] = []
        if steps == 0 {
            cells = [(point, radius)]
        } else {
            for y in -steps...steps {
                for x in -steps...steps {
                    let east = Double(x) * strideMeters
                    let north = Double(y) * strideMeters
                    guard hypot(east, north) <= Double(radius) + 400 else { continue }
                    let lat = point.latitude + north / 111_195.0
                    let lon = point.longitude + east / (111_195.0 * max(0.2, cos(point.latitude * .pi / 180)))
                    cells.append((GeoPoint(lat, lon), cellRadius))
                }
            }
        }
        var saved = 0
        var failures: [String] = []
        for (index, cell) in cells.enumerated() {
            status = "Загрузка участка \(index + 1)/\(cells.count) · сохранено \(saved)"
            do {
                let features = try await fetchCell(at: cell.0, radius: cell.1)
                let encoded = try JSONEncoder().encode(features)
                guard encoded.count < 80_000_000 else { throw NSError(domain: "OSM", code: 4, userInfo: [NSLocalizedDescriptionKey: "Участок слишком большой"]) }
                let region = OSMDownloadedRegion(id: UUID(), title: "\(title.isEmpty ? "Район" : String(title.prefix(40))) \(index + 1)/\(cells.count)", latitude: cell.0.latitude, longitude: cell.0.longitude, radiusMeters: cell.1, downloadedAt: Date(), featureCount: features.count)
                try encoded.write(to: file(for: region.id), options: [.atomic, .completeFileProtectionUnlessOpen])
                do {
                    let updated = regions + [region]
                    try JSONEncoder().encode(updated).write(to: regionIndex, options: [.atomic, .completeFileProtectionUnlessOpen])
                    regions = updated
                } catch {
                    try? FileManager.default.removeItem(at: file(for: region.id))
                    throw error
                }
                saved += 1
                rebuildLines()
            } catch {
                failures.append("Участок \(index + 1): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { lastDownloadError = failures.prefix(4).joined(separator: " | ") }
        status = "Сохранено участков: \(saved)/\(cells.count), объектов: \(lines.count)" + (failures.isEmpty ? " · Доступно офлайн" : " · Ошибки: \(failures.count)")
    }

    private func fetchCell(at point: GeoPoint, radius: Int) async throws -> [OSMOfflineLine] {
        let query = "[out:json][timeout:45];(way[\"highway\"](around:\(radius),\(point.latitude),\(point.longitude));way[\"waterway\"](around:\(radius),\(point.latitude),\(point.longitude)););out geom;"
        var errors: [String] = []
        for endpoint in endpoints {
            let server = endpoint.host ?? "Overpass"
            lastServer = server
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "data", value: query)]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            request.timeoutInterval = 65
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NSError(domain: "OSM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не HTTP ответ"]) }
                lastHTTPStatus = http.statusCode
                guard http.statusCode == 200 else { throw NSError(domain: "OSM", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]) }
                guard data.count <= 20_000_000 else { throw NSError(domain: "OSM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ответ больше 20 МБ"]) }
                let parsed = try JSONDecoder().decode(OverpassResponse.self, from: data)
                var result: [Int64: OSMOfflineLine] = [:]
                for item in parsed.elements {
                    guard item.type == "way", let geometry = item.geometry, (2...20_000).contains(geometry.count) else { continue }
                    let coords = geometry.compactMap { p -> GeoPoint? in
                        guard p.lat.isFinite, p.lon.isFinite, (-90...90).contains(p.lat), (-180...180).contains(p.lon) else { return nil }
                        return GeoPoint(p.lat, p.lon)
                    }
                    guard coords.count >= 2 else { continue }
                    result[item.id] = OSMOfflineLine(id: item.id, kind: item.tags?["highway"] ?? item.tags?["waterway"] ?? "other", points: coords)
                }
                return result.values.sorted { $0.id < $1.id }
            } catch { errors.append("\(server): \(error.localizedDescription)") }
        }
        throw NSError(domain: "OSM", code: 3, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: " | ")])
    }

    func remove(_ region: OSMDownloadedRegion) {
        guard !busy else { return }
        do {
            let updated = regions.filter { $0.id != region.id }
            try JSONEncoder().encode(updated).write(to: regionIndex, options: [.atomic, .completeFileProtectionUnlessOpen])
            regions = updated
            try? FileManager.default.removeItem(at: file(for: region.id))
            rebuildLines()
        } catch { status = "Ошибка удаления: \(error.localizedDescription)" }
    }

    func clear() {
        guard !busy else { return }
        do {
            try JSONEncoder().encode([OSMDownloadedRegion]()).write(to: regionIndex, options: [.atomic, .completeFileProtectionUnlessOpen])
            for region in regions { try? FileManager.default.removeItem(at: file(for: region.id)) }
            if FileManager.default.fileExists(atPath: legacyIndex.path) { try FileManager.default.removeItem(at: legacyIndex) }
            regions = []
            rebuildLines()
            status = "Локальные дороги и тропы удалены"
        } catch { status = "Ошибка удаления: \(error.localizedDescription)" }
    }
}

private struct OverpassResponse: Decodable {
    let elements: [Element]
    struct Element: Decodable { let type: String; let id: Int64; let tags: [String: String]?; let geometry: [Point]? }
    struct Point: Decodable { let lat: Double; let lon: Double }
}
