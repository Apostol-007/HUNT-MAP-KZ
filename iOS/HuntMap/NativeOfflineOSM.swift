import Foundation
import HuntCore

/// Downloads OSM *features* (not public tile-server tiles), and stores them locally.
/// Small-area downloads are deliberately capped to protect Overpass public infrastructure.
struct OSMOfflineLine: Codable, Identifiable {
    let id: Int64
    let kind: String
    let points: [GeoPoint]
}

@MainActor final class NativeOfflineOSM: ObservableObject {
    @Published private(set) var lines: [OSMOfflineLine] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "Детальные дороги и тропы не загружены"
    @Published private(set) var revision = 0
    private let endpoint = URL(string: "https://overpass.kumi.systems/api/interpreter")!
    private var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSMOffline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var index: URL { directory.appendingPathComponent("features.json") }

    init() { restore() }

    private func restore() {
        guard let data = try? Data(contentsOf: index),
              let decoded = try? JSONDecoder().decode([OSMOfflineLine].self, from: data) else { return }
        lines = decoded
        status = "Локальные OSM-объекты: \(decoded.count)"
    }

    func download(around point: GeoPoint, radiusMeters: Int = 1500) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let radius = min(2500, max(500, radiusMeters))
        // Only highways (including footways/tracks) and waterways; no private user coordinates are persisted remotely.
        let query = "[out:json][timeout:45];(way[\"highway\"](around:\(radius),\(point.latitude),\(point.longitude));way[\"waterway\"](around:\(radius),\(point.latitude),\(point.longitude)););out geom;"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8)
        request.timeoutInterval = 65
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "OSM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сервер OSM недоступен или ограничил запрос. Попробуйте позже."])
            }
            guard data.count <= 15_000_000 else { throw NSError(domain: "OSM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Слишком большой ответ сервера"] ) }
            let parsed = try JSONDecoder().decode(OverpassResponse.self, from: data)
            var merged = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
            for item in parsed.elements {
                guard item.type == "way", let geometry = item.geometry, geometry.count >= 2,
                      geometry.count <= 20_000 else { continue }
                let coords = geometry.compactMap { p -> GeoPoint? in
                    guard (-90...90).contains(p.lat), (-180...180).contains(p.lon), p.lat.isFinite, p.lon.isFinite else { return nil }
                    return GeoPoint(p.lat, p.lon)
                }
                guard coords.count >= 2 else { continue }
                let kind = item.tags?["highway"] ?? item.tags?["waterway"] ?? "other"
                merged[item.id] = OSMOfflineLine(id: item.id, kind: kind, points: coords)
            }
            guard merged.count <= 4_000 else { throw NSError(domain: "OSM", code: 3, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит объектов. Выберите меньшую территорию."] ) }
            let updated = merged.values.sorted { $0.id < $1.id }
            let encoded = try JSONEncoder().encode(updated)
            guard encoded.count <= 80_000_000 else { throw NSError(domain: "OSM", code: 4, userInfo: [NSLocalizedDescriptionKey: "Недостаточно места для набора данных"] ) }
            try encoded.write(to: index, options: [.atomic, .completeFileProtectionUnlessOpen])
            lines = updated
            revision += 1
            status = "Сохранено \(updated.count) объектов OSM. Доступны без интернета."
        } catch {
            status = "Ошибка загрузки OSM: \(error.localizedDescription)"
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
            lines = []
            revision += 1
            status = "Локальные дороги и тропы удалены"
        } catch { status = "Ошибка удаления: \(error.localizedDescription)" }
    }
}

private struct OverpassResponse: Decodable { let elements: [Element]
    struct Element: Decodable { let type: String; let id: Int64; let tags: [String: String]?; let geometry: [Point]? }
    struct Point: Decodable { let lat: Double; let lon: Double }
}
