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
        let radius = min(2500, max(500, radiusMeters))
        guard point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else {
            status = "Ошибка: неверные координаты"; return
        }
        let query = "[out:json][timeout:45];(way[\"highway\"](around:\(radius),\(point.latitude),\(point.longitude));way[\"waterway\"](around:\(radius),\(point.latitude),\(point.longitude)););out geom;"
        do {
            var responseData: Data? = nil
            var failures: [String] = []
            for (index, endpoint) in endpoints.enumerated() {
                let serverName = endpoint.host ?? "Overpass"
                lastServer = serverName
                status = "Подключение к \(serverName) (\(index + 1)/\(endpoints.count))…"
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("HuntMapKZ/1.7.17 (offline OSM feature extract)", forHTTPHeaderField: "User-Agent")
                var components = URLComponents()
                components.queryItems = [URLQueryItem(name: "data", value: query)]
                request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
                request.timeoutInterval = 75
                do {
                    let (payload, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        failures.append("\(serverName): ответ не HTTP")
                        continue
                    }
                    lastHTTPStatus = http.statusCode
                    guard http.statusCode == 200 else {
                        let description = String(data: payload.prefix(300), encoding: .utf8)?
                            .replacingOccurrences(of: "\n", with: " ") ?? ""
                        failures.append("\(serverName): HTTP \(http.statusCode) \(description.prefix(80))")
                        continue
                    }
                    guard payload.count <= 15_000_000 else {
                        failures.append("\(serverName): ответ больше 15 МБ")
                        continue
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                          json["elements"] is [[String: Any]] else {
                        let explanation = String(data: payload.prefix(350), encoding: .utf8)?
                            .replacingOccurrences(of: "\n", with: " ") ?? "Неверный JSON"
                        failures.append("\(serverName): \(explanation.prefix(130))")
                        continue
                    }
                    if let remark = json["remark"] as? String, !remark.isEmpty {
                        failures.append("\(serverName): \(remark.prefix(130))")
                        continue
                    }
                    responseData = payload
                    break
                } catch {
                    failures.append("\(serverName): \(error.localizedDescription)")
                }
            }
            let lastFailure = failures.isEmpty ? "Серверы Overpass недоступны" : failures.joined(separator: " | ")
            guard let data = responseData else {
                throw NSError(domain: "OSM", code: 1, userInfo: [NSLocalizedDescriptionKey: lastFailure])
            }
            guard data.count <= 15_000_000 else { throw NSError(domain: "OSM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Слишком большой ответ сервера"] ) }
            let parsed = try JSONDecoder().decode(OverpassResponse.self, from: data)
            var result: [Int64: OSMOfflineLine] = [:]
            for item in parsed.elements {
                guard item.type == "way", let geometry = item.geometry, (2...20_000).contains(geometry.count) else { continue }
                let coords = geometry.compactMap { p -> GeoPoint? in
                    guard p.lat.isFinite, p.lon.isFinite, (-90...90).contains(p.lat), (-180...180).contains(p.lon) else { return nil }
                    return GeoPoint(p.lat, p.lon)
                }
                guard coords.count >= 2 else { continue }
                let kind = item.tags?["highway"] ?? item.tags?["waterway"] ?? "other"
                result[item.id] = OSMOfflineLine(id: item.id, kind: kind, points: coords)
            }
            guard result.count <= 4_000 else { throw NSError(domain: "OSM", code: 3, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит объектов. Выберите меньшую территорию."] ) }
            let extracted = result.values.sorted { $0.id < $1.id }
            let encoded = try JSONEncoder().encode(extracted)
            guard encoded.count <= 80_000_000 else { throw NSError(domain: "OSM", code: 4, userInfo: [NSLocalizedDescriptionKey: "Слишком большой набор данных"] ) }
            let region = OSMDownloadedRegion(id: UUID(), title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Район \(regions.count + 1)" : String(title.prefix(70)), latitude: point.latitude, longitude: point.longitude, radiusMeters: radius, downloadedAt: Date(), featureCount: extracted.count)
            // Commit region data before the index; if index write fails, no existing region is lost.
            try encoded.write(to: file(for: region.id), options: [.atomic, .completeFileProtectionUnlessOpen])
            do {
                let updated = regions + [region]
                try JSONEncoder().encode(updated).write(to: regionIndex, options: [.atomic, .completeFileProtectionUnlessOpen])
                regions = updated
            } catch {
                try? FileManager.default.removeItem(at: file(for: region.id))
                throw error
            }
            rebuildLines()
            status = extracted.isEmpty
                ? "Запрос выполнен, но дорог и водотоков в выбранном районе нет. Попробуйте другую точку."
                : "Район «\(region.title)»: \(extracted.count) объектов. Доступен без интернета."
        } catch {
            lastDownloadError = error.localizedDescription
            status = "Ошибка загрузки OSM: \(error.localizedDescription)"
        }
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
