import Foundation
import HuntCore

/// Vector road overlay sourced exclusively from downloaded GeoJSON packages.
struct OfflineRoadLine: Sendable {
    let points: [GeoPoint]
    let isTrail: Bool
}

@MainActor final class OfflineRoadOverlayStore: ObservableObject {
    @Published private(set) var lines: [OfflineRoadLine] = []
    @Published private(set) var revision = 0
    @Published private(set) var status = "Нет видимых дорог"
    private var task: Task<Void, Never>?
    private var parser: Task<[OfflineRoadLine], Never>?
    private var key = ""

    func clear() {
        task?.cancel()
        parser?.cancel()
        key = ""
        if !lines.isEmpty { lines = []; revision += 1 }
    }

    func load(bounds: [Double], files: [URL]) {
        guard bounds.count == 4, bounds.allSatisfy({ $0.isFinite }) else { return }
        let next = bounds.map { String(format: "%.2f", $0) }.joined(separator: "/") +
            files.map(\.lastPathComponent).joined(separator: "|")
        guard next != key else { return }
        key = next
        task?.cancel()
        parser?.cancel()
        // Load the geographically closest file groups first on large regional catalogs.
        let sample = Array(files.sorted { a, b in
            // Catalog paths are opaque; keep stable alphabetical priority when no metadata is available.
            a.lastPathComponent < b.lastPathComponent
        }.prefix(80))
        let previous = parser
        let worker = Task.detached(priority: .utility) {
            _ = await previous?.value
            guard !Task.isCancelled else { return [OfflineRoadLine]() }
            return Self.parse(sample, bounds: bounds)
        }
        parser = worker
        task = Task { [weak self] in
            let parsed = await worker.value
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.lines = parsed
            self.revision += 1
            self.status = "Видимые дороги: \(parsed.count) линий, просмотрено \(sample.count) пакетов"
        }
    }

    nonisolated private static func parse(_ files: [URL], bounds: [Double]) -> [OfflineRoadLine] {
        var lines: [OfflineRoadLine] = []
        var vertices = 0
        for file in files {
            guard !Task.isCancelled else { return [] }
            guard lines.count < 1000 && vertices < 12000 else { break }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 && size < 30_000_000,
                  let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = root["features"] as? [[String: Any]] else { continue }
            for feature in features {
                guard !Task.isCancelled else { return [] }
                if lines.count >= 1000 || vertices >= 12000 { break }
                guard let geo = feature["geometry"] as? [String: Any],
                      let type = geo["type"] as? String else { continue }
                let props = feature["properties"] as? [String: Any] ?? [:]
                let nested = props["tags"] as? [String: Any] ?? [:]
                let highway = String(describing: props["highway"] ?? nested["highway"] ?? "").lowercased()
                let isTrail = ["path", "footway", "track", "steps", "bridleway", "cycleway", "pedestrian"].contains(highway)
                let chains: [Any]
                if type == "LineString" { chains = [geo["coordinates"] ?? []] }
                else if type == "MultiLineString" { chains = geo["coordinates"] as? [Any] ?? [] }
                else { continue }
                for chain in chains {
                    guard let raw = chain as? [[Double]], raw.count >= 2, raw.count <= 20000 else { continue }
                    // Preserve each independent road. Do not connect separate features.
                    let step = max(1, Int(ceil(Double(raw.count) / 180)))
                    var points: [GeoPoint] = []
                    for idx in Swift.stride(from: 0, to: raw.count, by: step) {
                        let coord = raw[idx]
                        guard coord.count >= 2 else { continue }
                        let p = GeoPoint(coord[1], coord[0])
                        if p.valid { points.append(p) }
                    }
                    if let last = raw.last, last.count >= 2 {
                        let p = GeoPoint(last[1], last[0])
                        if p.valid && points.last != p { points.append(p) }
                    }
                    guard points.count >= 2,
                          points.contains(where: { $0.longitude >= bounds[0] && $0.longitude <= bounds[2] &&
                                                   $0.latitude >= bounds[1] && $0.latitude <= bounds[3] })
                    else { continue }
                    lines.append(OfflineRoadLine(points: points, isTrail: isTrail))
                    vertices += points.count
                    if lines.count >= 1000 || vertices >= 12000 { break }
                }
            }
        }
        return lines
    }
}
