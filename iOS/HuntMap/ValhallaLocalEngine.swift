import Foundation
import CryptoKit
import HuntCore
import Valhalla
import ValhallaConfigModels

enum ValhallaRoutingError: Error, LocalizedError {
    case missingTiles, invalidArchive, emptyRoute, invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingTiles: "Офлайн-тайлы Valhalla не установлены. Импортируйте valhalla_tiles.tar."
        case .invalidArchive: "Файл не похож на архив Valhalla TAR. PMTiles и GeoJSON сюда не подходят."
        case .emptyRoute: "Valhalla не нашла проходимый маршрут в установленных дорожных данных."
        case .invalidResponse: "Valhalla вернула маршрут без корректных координат."
        }
    }
}

struct ValhallaManeuver {
    let instruction: String
    let beginIndex: Int
    let isDestination: Bool
    let endIndex: Int
    let durationSeconds: Double?

    static func shortInstruction(type: Int, exit: Int?) -> String {
        switch type {
        case 2, 9, 23, 37: return "Держитесь правее"
        case 3, 16, 24, 38: return "Держитесь левее"
        case 4, 5, 6: return "Вы приближаетесь к точке назначения"
        case 10: return "Поверните направо"
        case 11: return "Резко поверните направо"
        case 12, 13: return "Развернитесь"
        case 14: return "Резко поверните налево"
        case 15: return "Поверните налево"
        case 18, 20: return "Съезжайте направо"
        case 19, 21: return "Съезжайте налево"
        case 25: return "Влейтесь в поток"
        case 26:
            let exits = ["первый", "второй", "третий", "четвёртый", "пятый", "шестой", "седьмой", "восьмой"]
            if let exit, (1...exits.count).contains(exit) { return "На круге выберите \(exits[exit - 1]) съезд" }
            return "Въезжайте на круг"
        case 27: return "Съезжайте с круга"
        case 28: return "Въезжайте на паром"
        case 29: return "Съезжайте с парома"
        case 39: return "Воспользуйтесь лифтом"
        case 40: return "Следуйте по лестнице"
        case 41: return "Воспользуйтесь эскалатором"
        case 42: return "Войдите в здание"
        case 43: return "Выйдите из здания"
        case 1, 7, 8, 17, 22: return "Продолжайте прямо"
        default: return "Следуйте по маршруту"
        }
    }
}
struct ValhallaRouteResult {
    let path: [GeoPoint]
    let maneuvers: [ValhallaManeuver]
    let durationSeconds: Double?
}

/// The Valhalla C++ actor is cached inside a Swift actor, never invoked on the main thread.
/// Only local Valhalla tile extracts are used; this config has NO remote tiles URL.
actor ValhallaLocalEngine {
    private var router: Valhalla?
    private let folder: URL
    private let archive: URL

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Valhalla", isDirectory: true)
        archive = folder.appendingPathComponent("valhalla_tiles.tar")
    }

    func hasTiles() -> Bool {
        FileManager.default.fileExists(atPath: archive.path)
    }

    func importArchive(from source: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: source)
        let header: Data
        do {
            try handle.seek(toOffset: 257)
            header = try handle.read(upToCount: 5) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard header == Data("ustar".utf8) else { throw ValhallaRoutingError.invalidArchive }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 1024 else { throw ValhallaRoutingError.invalidArchive }
        let temporary = folder.appendingPathComponent("new-valhalla-\(UUID().uuidString).tar")
        try FileManager.default.copyItem(at: source, to: temporary)
        do {
            router?.close()
            router = nil
            if FileManager.default.fileExists(atPath: archive.path) {
                _ = try FileManager.default.replaceItemAt(archive, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: archive)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func route(from: GeoPoint, to: GeoPoint, mode: OfflineRouteGraph.TravelMode) throws -> ValhallaRouteResult {
        guard hasTiles() else { throw ValhallaRoutingError.missingTiles }
        if router == nil {
            let config = try ValhallaConfig(tileExtractTar: archive)
            router = try Valhalla(config)
        }
        let request: [String: Any] = [
            "locations": [
                ["lat": from.latitude, "lon": from.longitude],
                ["lat": to.latitude, "lon": to.longitude]
            ],
            "costing": mode == .foot ? "pedestrian" : "auto",
            "shape_format": "polyline6",
            "language": "ru-RU",
            "directions_type": "instructions",
            "units": "kilometers"
        ]
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let payload = String(data: bytes, encoding: .utf8),
              let result = try router?.route(rawRequest: payload),
              let json = result.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let trip = root["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]] else {
            throw ValhallaRoutingError.invalidResponse
        }
        var output: [GeoPoint] = []
        var maneuvers: [ValhallaManeuver] = []
        for leg in legs {
            guard let encoded = leg["shape"] as? String else {
                throw ValhallaRoutingError.invalidResponse
            }
            let coordinates = try ValhallaPolyline6.decode(encoded)
            let overlap = output.last == coordinates.first ? 1 : 0
            let offset = output.count - overlap
            if overlap == 1 { output.append(contentsOf: coordinates.dropFirst()) }
            else { output.append(contentsOf: coordinates) }
            if let entries = leg["maneuvers"] as? [[String: Any]] {
                for entry in entries {
                    guard let localIndex = entry["begin_shape_index"] as? Int else { continue }
                    let type = entry["type"] as? Int ?? 0
                    let instruction = ValhallaManeuver.shortInstruction(type: type, exit: entry["roundabout_exit_count"] as? Int)
                    let position = offset + localIndex
                    if !instruction.isEmpty && (0..<output.count).contains(position) {
                        let end = offset + (entry["end_shape_index"] as? Int ?? localIndex)
                        let time = entry["time"] as? Double
                        maneuvers.append(ValhallaManeuver(instruction: instruction, beginIndex: position, isDestination: (4...6).contains(type), endIndex: end, durationSeconds: time))
                    }
                }
            }
        }
        guard output.count >= 2 else { throw ValhallaRoutingError.emptyRoute }
        let seconds = (trip["summary"] as? [String: Any])?["time"] as? Double
        return ValhallaRouteResult(path: output, maneuvers: maneuvers,
                                  durationSeconds: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }
}

/// Polyline6 decoder: Valhalla defaults to 1e6 coordinate precision, not Google's 1e5.
enum ValhallaPolyline6 {
    static func decode(_ encoded: String) throws -> [GeoPoint] {
        let bytes = Array(encoded.utf8)
        var position = 0
        func nextDelta() throws -> Int64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while position < bytes.count {
                let c = bytes[position]
                position += 1
                guard (63...126).contains(c), shift <= 55 else {
                    throw ValhallaRoutingError.invalidResponse
                }
                let chunk = UInt64(c - 63)
                value |= (chunk & 0x1f) << shift
                if chunk < 0x20 {
                    let sign = Int64(value >> 1)
                    return (value & 1) == 0 ? sign : ~sign
                }
                shift += 5
            }
            throw ValhallaRoutingError.invalidResponse
        }
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var result: [GeoPoint] = []
        while position < bytes.count {
            let latChange = try nextDelta()
            let lonChange = try nextDelta()
            latitude += latChange
            longitude += lonChange
            let point = GeoPoint(Double(latitude) / 1_000_000,
                                 Double(longitude) / 1_000_000)
            guard point.valid else { throw ValhallaRoutingError.invalidResponse }
            result.append(point)
        }
        return result
    }
}

@MainActor final class ValhallaRoutingStore: ObservableObject {
    @Published private(set) var tilesInstalled = false
    @Published private(set) var status = "Valhalla: тайлы не установлены"
    @Published private(set) var busy = false
    @Published private(set) var hostedDownloadStatus = ""
    private let engine = ValhallaLocalEngine()

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        tilesInstalled = await engine.hasTiles()
        status = tilesInstalled ? "Valhalla: офлайн-тайлы установлены" : "Valhalla: импортируйте valhalla_tiles.tar"
    }

    func install(_ url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await engine.importArchive(from: url)
            await refresh()
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Навигация", operation: "Установка Valhalla", error: error, usedCache: tilesInstalled)
            status = "Ошибка импорта Valhalla: \(error.localizedDescription)"
        }
    }

    /// Download full offline graph from the user's own HTTPS hosting with SHA-256 verification.
    /// The archive is never executed or routed until it is installed locally.
    func downloadFromHosting() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let catalogURL = URL(string: "https://create.web-works.kz/maps/valhalla/catalog.json")!
        do {
            var request = URLRequest(url: catalogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 25
            let (manifestData, reply) = try await URLSession.shared.data(for: request)
            guard (reply as? HTTPURLResponse)?.statusCode == 200,
                  manifestData.count < 100_000,
                  let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  object["schema"] as? String == "hunt-valhalla-v1",
                  let file = object["file"] as? [String: Any],
                  let path = file["url"] as? String,
                  let remote = URL(string: path),
                  remote.scheme == "https",
                  remote.host == catalogURL.host,
                  remote.path.hasSuffix("/valhalla_tiles.tar"),
                  let bytes = file["bytes"] as? Int64, bytes > 1024,
                  let expectedHash = file["sha256"] as? String, expectedHash.count == 64 else {
                throw NSError(domain: "HuntValhalla", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Каталог Valhalla недоступен или не соответствует схеме hunt-valhalla-v1"])
            }
            let stored = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Valhalla/valhalla_tiles.tar")
            let manifestPath = stored.deletingLastPathComponent().appendingPathComponent("installed-sha256.txt")
            if FileManager.default.fileExists(atPath: stored.path),
               let current = try? String(contentsOf: manifestPath, encoding: .utf8),
               current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedHash.lowercased(),
               let existingSize = (try? stored.resourceValues(forKeys: [.fileSizeKey]).fileSize),
               Int64(existingSize) == bytes {
                tilesInstalled = true
                status = "Valhalla: навигационные тайлы актуальны"
                return
            }
            status = "Valhalla: загружаю навигационные тайлы…"
            var downloadRequest = URLRequest(url: remote)
            downloadRequest.timeoutInterval = 120
            let (temporary, response) = try await URLSession.shared.download(for: downloadRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value,
                  size == bytes else {
                throw NSError(domain: "HuntValhalla", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Размер скачанного архива не совпадает"])
            }
            let stream = try FileHandle(forReadingFrom: temporary)
            defer { try? stream.close() }
            var sha = SHA256()
            while true {
                try Task.checkCancellation()
                let block = try stream.read(upToCount: 1_048_576) ?? Data()
                if block.isEmpty { break }
                sha.update(data: block)
            }
            let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedHash.lowercased() else {
                throw NSError(domain: "HuntValhalla", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "SHA-256 архива Valhalla не совпадает"])
            }
            try await engine.importArchive(from: temporary)
            try expectedHash.lowercased().write(to: manifestPath, atomically: true, encoding: .utf8)
            await refresh()
            hostedDownloadStatus = "Навигационная сеть Valhalla установлена из хостинга"
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Навигация", operation: "Синхронизация Valhalla", error: error, endpoint: "create.web-works.kz/maps/valhalla", usedCache: tilesInstalled)
            status = "Valhalla: \(error.localizedDescription)"
            hostedDownloadStatus = status
        }
    }

    func route(from: GeoPoint, to: GeoPoint, mode: OfflineRouteGraph.TravelMode) async throws -> ValhallaRouteResult {
        try await engine.route(from: from, to: to, mode: mode)
    }
}