import Foundation

struct RouteWidgetSnapshot: Codable {
    var title: String
    var status: String
    var distanceMeters: Double
    var elapsedSeconds: TimeInterval
    var pointCount: Int
    var speedKmh: Double? = nil
    var averagePaceSecondsPerKm: Double? = nil
    var updatedAt: Date
    static let empty = RouteWidgetSnapshot(title: "Маршрут не записывается", status: "Откройте HUNT MAP KZ", distanceMeters: 0, elapsedSeconds: 0, pointCount: 0, updatedAt: .now)
}

enum RouteWidgetStorage {
    static let suite = "group.kz.huntmap.field"
    static let key = "routeWidgetSnapshotV1"
    static func read() -> RouteWidgetSnapshot {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(RouteWidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
    static func write(_ snapshot: RouteWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suite)?.set(data, forKey: key)
    }
}
