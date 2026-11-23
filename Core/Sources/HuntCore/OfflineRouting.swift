import Foundation

/// An explicitly imported, topologically connected walking/trail graph.
/// Map tiles and polygon boundaries do not contain routing connectivity.
public struct OfflineRouteGraph: Sendable {
    public enum RouteError: Error, LocalizedError {
        case invalidFormat, emptyNetwork, tooLarge, startOffNetwork, destinationOffNetwork, disconnected
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: "Нужен GeoJSON FeatureCollection с LineString/MultiLineString (WGS84)."
            case .emptyNetwork: "В файле нет подходящих линий дорог или троп."
            case .tooLarge: "Сеть слишком большая для импорта (лимит 200 000 вершин)."
            case .startOffNetwork: "Начальная точка дальше 250 м от сети."
            case .destinationOffNetwork: "Метка дальше 250 м от сети."
            case .disconnected: "Связанного пути по этой сети нет."
            }
        }
    }
    private struct Edge: Sendable { let to: Int; let distance: Double }
    public let vertices: [GeoPoint]
    private let edges: [[Edge]]
    public var count: Int { vertices.count }

    /// Input geometry is [longitude, latitude]. Links share exactly matching
    /// quantized vertices; crossing un-noded lines are NOT implicitly connected.
    public init(geoJSON: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: geoJSON) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]] else { throw RouteError.invalidFormat }
        var nodes: [GeoPoint] = []
        var adjacency: [[Edge]] = []
        var ids: [String: Int] = [:]
        func insert(_ point: GeoPoint) throws -> Int {
            let key = String(format: "%.6f,%.6f", point.latitude, point.longitude)
            if let existing = ids[key] { return existing }
            guard nodes.count < 200_000 else { throw RouteError.tooLarge }
            let index = nodes.count
            nodes.append(point); adjacency.append([]); ids[key] = index
            return index
        }
        func addLine(_ raw: Any) throws {
            guard let coordinates = raw as? [[Double]] else { return }
            var previous: Int?
            for c in coordinates {
                guard c.count >= 2 else { previous = nil; continue }
                let point = GeoPoint(c[1], c[0])
                guard point.valid else { previous = nil; continue }
                let index = try insert(point)
                if let prior = previous, prior != index {
                    let length = GeoMath.meters(nodes[prior], nodes[index])
                    if length > 0 && length < 20_000 {
                        adjacency[prior].append(Edge(to: index, distance: length))
                        adjacency[index].append(Edge(to: prior, distance: length))
                    }
                }
                previous = index
            }
        }
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String, let coords = geometry["coordinates"] else { continue }
            if type == "LineString" { try addLine(coords) }
            else if type == "MultiLineString", let lines = coords as? [Any] {
                for line in lines { try addLine(line) }
            }
        }
        guard !nodes.isEmpty && adjacency.contains(where: { !$0.isEmpty }) else { throw RouteError.emptyNetwork }
        vertices = nodes; edges = adjacency
    }

    public func path(from start: GeoPoint, to destination: GeoPoint, maxSnapMeters: Double = 250) throws -> [GeoPoint] {
        guard start.valid && destination.valid else { throw RouteError.invalidFormat }
        func nearest(_ target: GeoPoint) -> (Int, Double) {
            var match = 0, distance = Double.infinity
            for (index, vertex) in vertices.enumerated() {
                let d = GeoMath.meters(target, vertex)
                if d < distance { match = index; distance = d }
            }
            return (match, distance)
        }
        let (origin, originDistance) = nearest(start)
        let (goal, goalDistance) = nearest(destination)
        guard originDistance <= maxSnapMeters else { throw RouteError.startOffNetwork }
        guard goalDistance <= maxSnapMeters else { throw RouteError.destinationOffNetwork }
        var costs = [Double](repeating: .infinity, count: vertices.count)
        var previous = [Int](repeating: -1, count: vertices.count)
        var visited = [Bool](repeating: false, count: vertices.count)
        // Binary min-heap of (estimated total cost, vertex), permits stale entries.
        var heap: [(Double, Int)] = []
        func push(_ entry: (Double, Int)) {
            heap.append(entry); var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent].0 <= heap[i].0 { break }
                heap.swapAt(i, parent); i = parent
            }
        }
        func pop() -> (Double, Int)? {
            guard !heap.isEmpty else { return nil }
            let result = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last; var i = 0
                while true {
                    let left = 2*i+1, right = left+1
                    var smallest = i
                    if left < heap.count && heap[left].0 < heap[smallest].0 { smallest = left }
                    if right < heap.count && heap[right].0 < heap[smallest].0 { smallest = right }
                    if smallest == i { break }
                    heap.swapAt(i, smallest); i = smallest
                }
            }
            return result
        }
        costs[origin] = 0
        push((GeoMath.meters(vertices[origin], vertices[goal]), origin))
        while let (_, current) = pop() {
            if visited[current] { continue }
            visited[current] = true
            if current == goal { break }
            for edge in edges[current] where !visited[edge.to] {
                let tentative = costs[current] + edge.distance
                if tentative < costs[edge.to] {
                    costs[edge.to] = tentative; previous[edge.to] = current
                    push((tentative + GeoMath.meters(vertices[edge.to], vertices[goal]), edge.to))
                }
            }
        }
        guard visited[goal] else { throw RouteError.disconnected }
        var pathIndices: [Int] = [], current = goal
        while current != -1 { pathIndices.append(current); current = previous[current] }
        pathIndices.reverse()
        return [start] + pathIndices.map { vertices[$0] } + [destination]
    }
}
