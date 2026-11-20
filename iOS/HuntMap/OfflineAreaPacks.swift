import Foundation
import CoreLocation
import MapLibre
import Combine

/// Native MapLibre offline packs. The map SDK stores the style, glyphs and tiles
/// required for the selected bounds. Use only with providers that permit offline use.
@MainActor final class OfflineAreaPacks: ObservableObject {
    @Published private(set) var packs: [MLNOfflinePack] = []
    @Published private(set) var status = "Выберите район для загрузки"
    @Published private(set) var busy = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var hasPacks = false
    @Published private(set) var hasCompletedPacks = false
    private var observations: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        for name in [Notification.Name.MLNOfflinePackProgressChanged,
                     Notification.Name.MLNOfflinePackError,
                     Notification.Name.MLNOfflinePackMaximumMapboxTilesReached] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.handle(notification) }
            }
            observations.append(token)
        }
    }
    deinit { for token in observations { NotificationCenter.default.removeObserver(token) } }

    func refresh() {
        packs = MLNOfflineStorage.shared.packs ?? []
        hasPacks = !packs.isEmpty
        // A pack being created or partially downloaded is NOT an offline map.
        hasCompletedPacks = packs.contains { $0.state == .complete }
    }

    /// A completed pack is usable only with the exact style it downloaded.
    /// A completed Bright pack must not make Liberty or Positron appear offline-ready.
    func hasCompletedPack(forStyle style: String) -> Bool {
        let safeStyle = ["liberty", "bright", "positron"].contains(style) ? style : "liberty"
        let expected = "https://tiles.openfreemap.org/styles/\(safeStyle)"
        return packs.contains { pack in
            guard pack.state == .complete,
                  let region = pack.region as? MLNTilePyramidOfflineRegion else { return false }
            return region.styleURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected
        }
    }

    func download(latitude: Double, longitude: Double, radiusMeters: Int, style: String) {
        guard !busy else { return }
        guard latitude.isFinite, longitude.isFinite,
              (-85...85).contains(latitude), (-180...180).contains(longitude) else {
            status = "Ошибка: координаты недоступны. Включите GPS или выберите точку на карте."
            return
        }
        let safeStyle = ["liberty", "bright", "positron"].contains(style) ? style : "liberty"
        let radius = Double(max(500, min(10_000, radiusMeters)))
        let latDelta = radius / 111_195
        let lonDelta = radius / max(1, 111_195 * cos(latitude * .pi / 180))
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: latitude - latDelta, longitude: longitude - lonDelta),
            ne: CLLocationCoordinate2D(latitude: latitude + latDelta, longitude: longitude + lonDelta))
        guard let url = URL(string: "https://tiles.openfreemap.org/styles/\(safeStyle)") else { return }
        let maximumZoom: Double = radius <= 1_000 ? 16 : radius <= 2_000 ? 15 : 14
        let region = MLNTilePyramidOfflineRegion(styleURL: url, bounds: bounds,
                                                  fromZoomLevel: 8, toZoomLevel: maximumZoom)
        busy = true
        fraction = 0
        status = "Подготовка офлайн-карты · радиус \(Int(radius)) м"
        let metadata = try? JSONSerialization.data(withJSONObject: [
            "title": "Район \(String(format: "%.4f", latitude)), \(String(format: "%.4f", longitude))",
            "created": ISO8601DateFormatter().string(from: Date()),
            "style": safeStyle
        ])
        MLNOfflineStorage.shared.addPack(for: region, withContext: metadata ?? Data()) { [weak self] pack, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.busy = false
                    self.status = "Ошибка создания пакета: \(error.localizedDescription)"
                    return
                }
                guard let pack else {
                    self.busy = false
                    self.status = "Не удалось создать офлайн-пакет"
                    return
                }
                self.refresh()
                self.status = "Загрузка карты…"
                pack.resume()
            }
        }
    }

    func pause(_ pack: MLNOfflinePack) {
        pack.suspend()
        busy = false
        status = "Загрузка приостановлена"
    }
    func resume(_ pack: MLNOfflinePack) {
        busy = true
        status = "Продолжаем загрузку…"
        pack.resume()
    }
    func remove(_ pack: MLNOfflinePack) {
        pack.suspend()
        MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.busy = false
                self?.status = error.map { "Ошибка удаления: \($0.localizedDescription)" } ?? "Офлайн-карта удалена"
            }
        }
    }
    private func handle(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack else { return }
        if notification.name == .MLNOfflinePackError {
            busy = false
            status = "Ошибка загрузки: \(notification.userInfo?["error"] ?? "проверьте соединение и ограничения провайдера")"
            return
        }
        if notification.name == .MLNOfflinePackMaximumMapboxTilesReached {
            busy = false
            status = "Достигнут лимит офлайн-тайлов. Уменьшите район."
            return
        }
        let progress = pack.progress
        if progress.countOfResourcesExpected > 0 {
            fraction = min(1, Double(progress.countOfResourcesCompleted) / Double(progress.countOfResourcesExpected))
        }
        if pack.state == .complete {
            busy = false
            fraction = 1
            status = "Карта загружена. Отключите интернет для проверки."
        } else {
            status = "Загружено \(progress.countOfResourcesCompleted) из \(progress.countOfResourcesExpected) ресурсов"
        }
        refresh()
    }
}
