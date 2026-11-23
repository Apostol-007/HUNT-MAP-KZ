import Foundation

/// Offline navigation strictly on OSM-tagged, topologically connected roads and paths.
/// No straight-line fallback, untagged GeoJSON lines, or arbitrary cross-road connectors.
public struct OfflineRouteGraph: Sendable {
    public enum TravelMode: String, Codable, Sendable {
        case foot
        case car
    }

    public enum RouteError: Error, LocalizedError {
        case invalidFormat, emptyNetwork, tooLarge, startOffNetwork, destinationOffNetwork, disconnected
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Нужен GeoJSON FeatureCollection с размеченными дорогами OSM."
            case .emptyNetwork: return "Для выбранного способа передвижения нет дорог с подтверждёнными тегами доступа."
            case .tooLarge: return "Сеть слишком большая для импорта (лимит 200 000 вершин)."
            case .startOffNetwork: return "До ближайшей разрешённой дороги от GPS больше допустимого расстояния."
            case .destinationOffNetwork: return "Точка назначения не находится рядом с разрешённой дорогой."
            case .disconnected: return "Нет непрерывного доступного маршрута по дорогам."
            }
        }
    }

    private struct Edge: Sendable { let to: Int; let distance: Double }
    private struct Segment: Sendable {
        let a: Int
        let b: Int
        let length: Double
        let forward: Bool
        let backward: Bool
    }
    private struct Snap {
        let segment: Int
        let fraction: Double
        let point: GeoPoint
        let distance: Double
    }

    public let vertices: [GeoPoint]
    private let edges: [[Edge]]
    private let segments: [Segment]
    public let mode: TravelMode
    public var count: Int { vertices.count }

    public init(geoJSON: Data, mode: TravelMode = .foot) throws {
        try self.init(geoJSONParts: [geoJSON], mode: mode)
    }

    /// Adjacent packs connect only via shared, six-decimal WGS84 nodes.
    /// Crossing geometries without a shared node are never treated as a junction.
    public init(geoJSONParts: [Data], mode: TravelMode = .foot) throws {
        guard !geoJSONParts.isEmpty else { throw RouteError.emptyNetwork }
        self.mode = mode
        var nodes: [GeoPoint] = []
        var adjacency: [[Edge]] = []
        var roads: [Segment] = []
        var ids: [String: Int] = [:]

        func insert(_ point: GeoPoint) throws -> Int {
            let key = String(format: "%.6f,%.6f", point.latitude, point.longitude)
            if let existing = ids[key] { return existing }
            guard nodes.count < 200_000 else { throw RouteError.tooLarge }
            let index = nodes.count
            nodes.append(point)
            adjacency.append([])
            ids[key] = index
            return index
        }

        func addLine(_ raw: Any, forward: Bool, backward: Bool) throws {
            guard let coordinates = raw as? [[Double]] else { return }
            var previous: Int?
            for coordinate in coordinates {
                guard coordinate.count >= 2 else { previous = nil; continue }
                let point = GeoPoint(coordinate[1], coordinate[0])
                guard point.valid else { previous = nil; continue }
                let index = try insert(point)
                if let last = previous, last != index {
                    let length = GeoMath.meters(nodes[last], nodes[index])
                    if length > 0 && length < 20_000 {
                        roads.append(Segment(a: last, b: index, length: length,
                                             forward: forward, backward: backward))
                        if forward { adjacency[last].append(Edge(to: index, distance: length)) }
                        if backward { adjacency[index].append(Edge(to: last, distance: length)) }
                    }
                }
                previous = index
            }
        }

        for part in geoJSONParts {
            guard let root = try JSONSerialization.jsonObject(with: part) as? [String: Any],
                  root["type"] as? String == "FeatureCollection",
                  let features = root["features"] as? [[String: Any]] else {
                throw RouteError.invalidFormat
            }
            for feature in features {
                let props = feature["properties"] as? [String: Any] ?? [:]
                let nested = props["tags"] as? [String: Any] ?? [:]
                func tag(_ key: String) -> String {
                    let raw = props[key] ?? nested[key]
                    return (raw.map { String(describing: $0) } ?? "").lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard Self.allowed(highway: tag("highway"),
                                   access: tag("access"), foot: tag("foot"),
                                   vehicle: tag("vehicle"), motorVehicle: tag("motor_vehicle"),
                                   motorcar: tag("motorcar"),
                                   construction: tag("construction"),
                                   mode: mode) else { continue }
                let oneway = tag("oneway")
                let reversed = mode == .car && oneway == "-1"
                let directed = mode == .car &&
                    (oneway == "yes" || oneway == "true" || oneway == "1" ||
                     reversed || tag("junction") == "roundabout")
                let forward = !reversed
                let backward = !directed || reversed

                guard let geometry = feature["geometry"] as? [String: Any],
                      let type = geometry["type"] as? String,
                      let coords = geometry["coordinates"] else { continue }
                if type == "LineString" {
                    try addLine(coords, forward: forward, backward: backward)
                } else if type == "MultiLineString", let lines = coords as? [Any] {
                    for line in lines { try addLine(line, forward: forward, backward: backward) }
                }
            }
        }
        guard !roads.isEmpty else { throw RouteError.emptyNetwork }
        vertices = nodes
        edges = adjacency
        segments = roads
    }

    /// Conservative: an untagged line has no proven access status and is not routable.
    /// OSM tags describe mapped accessibility, not legal permission or field conditions.
    private static func allowed(highway: String, access: String, foot: String,
                                vehicle: String, motorVehicle: String, motorcar: String,
                                construction: String, mode: TravelMode) -> Bool {
        guard !highway.isEmpty, highway != "construction", highway != "proposed",
              construction.isEmpty, !["no", "private", "agricultural", "forestry"].contains(access)
        else { return false }
        let walkable: Set<String> = [
            "footway", "path", "pedestrian", "steps", "track", "living_street",
            "residential", "service", "unclassified", "tertiary", "secondary",
            "primary", "road", "bridleway", "cycleway"
        ]
        let drivable: Set<String> = [
            "motorway", "motorway_link", "trunk", "trunk_link", "primary",
            "primary_link", "secondary", "secondary_link", "tertiary",
            "tertiary_link", "unclassified", "residential", "living_street",
            "service", "track", "road"
        ]
        if mode == .foot {
            guard walkable.contains(highway) else { return false }
            return !["no", "private", "use_sidepath"].contains(foot)
        }
        guard drivable.contains(highway) else { return false }
        return !["no", "private"].contains(vehicle) &&
               !["no", "private"].contains(motorVehicle) &&
               !["no", "private"].contains(motorcar)
    }

    /// Route endpoints are snapped to *real edges* (not only vertices).
    /// The returned polyline contains ONLY the actual traversed road geometry.
    /// It deliberately does not append off-road GPS/marker connectors.
    public func path(from start: GeoPoint, to destination: GeoPoint,
                     maxSnapMeters: Double = 50) throws -> [GeoPoint] {
        guard start.valid && destination.valid, maxSnapMeters >= 0 else { throw RouteError.invalidFormat }

        func snap(_ target: GeoPoint) -> Snap? {
            var best: Snap?
            let latScale = 111_200.0
            let lonScale = 111_200.0 * max(0.01, cos(target.latitude * .pi / 180))
            for (index, seg) in segments.enumerated() {
                let a = vertices[seg.a], b = vertices[seg.b]
                let dx = (b.longitude - a.longitude) * lonScale
                let dy = (b.latitude - a.latitude) * latScale
                let denominator = dx * dx + dy * dy
                guard denominator > 0 else { continue }
                let vx = (target.longitude - a.longitude) * lonScale
                let vy = (target.latitude - a.latitude) * latScale
                let t = max(0, min(1, (vx * dx + vy * dy) / denominator))
                let projected = GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                                         a.longitude + (b.longitude - a.longitude) * t)
                let d = GeoMath.meters(target, projected)
                if best == nil || d < best!.distance {
                    best = Snap(segment: index, fraction: t, point: projected, distance: d)
                }
            }
            return best
        }

        guard let from = snap(start), from.distance <= maxSnapMeters else {
            throw RouteError.startOffNetwork
        }
        guard let to = snap(destination), to.distance <= maxSnapMeters else {
            throw RouteError.destinationOffNetwork
        }

        var nodes = vertices
        var adjacency = edges

        func addEdge(_ a: Int, _ b: Int, _ distance: Double) {
            guard a != b else { return }
            adjacency[a].append(Edge(to: b, distance: distance))
        }

        func attach(_ snap: Snap) -> Int {
            let seg = segments[snap.segment]
            if snap.fraction <= 0.00000001 { return seg.a }
            if snap.fraction >= 0.99999999 { return seg.b }
            let node = nodes.count
            nodes.append(snap.point)
            adjacency.append([])
            let nearA = seg.length * snap.fraction
            let nearB = seg.length * (1 - snap.fraction)
            if seg.forward {
                addEdge(seg.a, node, nearA)
                addEdge(node, seg.b, nearB)
            }
            if seg.backward {
                addEdge(seg.b, node, nearB)
                addEdge(node, seg.a, nearA)
            }
            return node
        }

        let origin = attach(from)
        let goal = attach(to)
        if from.segment == to.segment && origin != goal {
            let seg = segments[from.segment]
            let dist = abs(from.fraction - to.fraction) * seg.length
            if from.fraction < to.fraction && seg.forward { addEdge(origin, goal, dist) }
            if from.fraction > to.fraction && seg.backward { addEdge(origin, goal, dist) }
        }
        if origin == goal { return [nodes[origin]] }

        // A* with admissible great-circle distance heuristic.
        var costs = [Double](repeating: .infinity, count: nodes.count)
        var previous = [Int](repeating: -1, count: nodes.count)
        var visited = [Bool](repeating: false, count: nodes.count)
        var heap: [(Double, Int)] = []

        func push(_ item: (Double, Int)) {
            heap.append(item)
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if heap[p].0 <= heap[i].0 { break }
                heap.swapAt(i, p)
                i = p
            }
        }
        func pop() -> (Double, Int)? {
            guard !heap.isEmpty else { return nil }
            let first = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let left = 2 * i + 1, right = left + 1
                    var minIndex = i
                    if left < heap.count && heap[left].0 < heap[minIndex].0 { minIndex = left }
                    if right < heap.count && heap[right].0 < heap[minIndex].0 { minIndex = right }
                    if minIndex == i { break }
                    heap.swapAt(i, minIndex)
                    i = minIndex
                }
            }
            return first
        }
        costs[origin] = 0
        push((GeoMath.meters(nodes[origin], nodes[goal]), origin))
        while let (_, current) = pop() {
            if visited[current] { continue }
            visited[current] = true
            if current == goal { break }
            for edge in adjacency[current] where !visited[edge.to] {
                let cost = costs[current] + edge.distance
                if cost < costs[edge.to] {
                    costs[edge.to] = cost
                    previous[edge.to] = current
                    push((cost + GeoMath.meters(nodes[edge.to], nodes[goal]), edge.to))
                }
            }
        }
        guard visited[goal] else { throw RouteError.disconnected }
        var reversed: [GeoPoint] = []
        var node = goal
        while node != -1 {
            reversed.append(nodes[node])
            node = previous[node]
        }
        return reversed.reversed()
    }
}
