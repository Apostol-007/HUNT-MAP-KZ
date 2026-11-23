import Foundation
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

    func route(from: GeoPoint, to: GeoPoint, mode: OfflineRouteGraph.TravelMode) throws -> [GeoPoint] {
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
        for leg in legs {
            guard let encoded = leg["shape"] as? String else {
                throw ValhallaRoutingError.invalidResponse
            }
            let coordinates = try ValhallaPolyline6.decode(encoded)
            if output.last == coordinates.first { output.append(contentsOf: coordinates.dropFirst()) }
            else { output.append(contentsOf: coordinates) }
        }
        guard output.count >= 2 else { throw ValhallaRoutingError.emptyRoute }
        return output
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
            status = "Ошибка импорта Valhalla: \(error.localizedDescription)"
        }
    }

    func route(from: GeoPoint, to: GeoPoint, mode: OfflineRouteGraph.TravelMode) async throws -> [GeoPoint] {
        try await engine.route(from: from, to: to, mode: mode)
    }
}
