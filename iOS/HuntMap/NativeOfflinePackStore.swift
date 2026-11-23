import Foundation
import MapLibre
import CoreLocation

/// Native MapLibre offline tile-pyramid packs include the complete style resources:
/// tiles, style document, sprites and glyphs (depending on the source).
/// Never use these APIs to bulk-cache a public tile server without permission.
@MainActor final class NativeOfflinePackStore: ObservableObject {
    @Published private(set) var status = "Выберите клетки для скачивания"
    @Published private(set) var progressResources: UInt64 = 0
    @Published private(set) var expectedResources: UInt64 = 0
    @Published private(set) var finishedCells = 0
    @Published private(set) var totalCells = 0
    @Published private(set) var downloading = false
    @Published private(set) var styleURL: URL?
    @Published private(set) var savedPacks = 0

    private var observer: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var pending: [MLNTilePyramidOfflineRegion] = []
    private var active: MLNOfflinePack?
    private var chosenStyle: URL?
    private var failed = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: MLNOfflinePackProgressChangedNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in self?.onProgress(note.object as? MLNOfflinePack) }
        }
        errorObserver = NotificationCenter.default.addObserver(forName: MLNOfflinePackErrorNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.failed = true
                self?.status = (note.userInfo?[MLNOfflinePackUserInfoKeyError] as? Error)?
                    .localizedDescription ?? "Ошибка скачивания тайлов"
            }
        }
        restore()
    }

    /// Must point to a licensed tile host with permission for persistent offline storage.
    static func permittedStyle() -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HuntOfflineStyleURL") as? String,
              let url = URL(string: value),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty, !host.contains("openfreemap.org")
        else { return nil }
        return url
    }

    func restore() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        savedPacks = packs.count
        for pack in packs {
            pack.requestProgress()
            if pack.state == .complete,
               let region = pack.region as? MLNTilePyramidOfflineRegion {
                styleURL = region.styleURL
            }
        }
    }

    func begin(cells: [OfflineGridCell], minZoom: Int, maxZoom: Int) {
        guard !downloading else { return }
        guard let url = Self.permittedStyle() else {
            status = "Нужен HTTPS-стиль источника, разрешающего офлайн-загрузку (HUNT_OFFLINE_STYLE_URL)."
            return
        }
        guard !cells.isEmpty, cells.count <= 25, 5...16 ~= minZoom,
              minZoom <= maxZoom, maxZoom <= 16 else {
            status = "Выберите 1–25 клеток, масштаб от 5 до 16"
            return
        }
        chosenStyle = url
        pending = cells.map { cell in
            let b = cell.bounds
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                ne: CLLocationCoordinate2D(latitude: b[3], longitude: b[2])
            )
            return MLNTilePyramidOfflineRegion(styleURL: url,
                bounds: bounds, fromZoomLevel: Double(minZoom), toZoomLevel: Double(maxZoom))
        }
        failed = false
        progressResources = 0
        expectedResources = 0
        finishedCells = 0
        totalCells = pending.count
        downloading = true
        next()
    }

    private func next() {
        guard !pending.isEmpty else {
            active = nil
            downloading = false
            savedPacks = (MLNOfflineStorage.shared.packs ?? []).count
            if !failed {
                styleURL = chosenStyle
                status = "Карта загружена: \(finishedCells) клеток с полными ресурсами стиля"
            }
            return
        }
        let region = pending.removeFirst()
        MLNOfflineStorage.shared.addPack(for: region, withContext: Data("HUNT_MAP_KZ".utf8)) {
            [weak self] pack, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let pack else {
                    self.failed = true
                    self.downloading = false
                    self.pending.removeAll()
                    self.status = error?.localizedDescription ?? "Не удалось создать пакет"
                    return
                }
                self.active = pack
                pack.resume()
            }
        }
    }

    private func onProgress(_ pack: MLNOfflinePack?) {
        guard let pack else { return }
        if pack === active {
            let p = pack.progress
            progressResources = p.countOfResourcesCompleted
            expectedResources = p.countOfResourcesExpected
            if pack.state == .complete {
                styleURL = (pack.region as? MLNTilePyramidOfflineRegion)?.styleURL
                finishedCells += 1
                active = nil
                status = "Сохранено клеток: \(finishedCells)/\(totalCells)"
                next()
            } else if pack.state == .active {
                status = "Клетка \(finishedCells + 1)/\(totalCells): ресурсы \(progressResources)/\(expectedResources)"
            }
        } else if pack.state == .complete,
                  let region = pack.region as? MLNTilePyramidOfflineRegion {
            styleURL = region.styleURL
        }
    }

    func pause() {
        active?.suspend()
        pending.removeAll()
        downloading = false
        status = "Загрузка приостановлена; ранее загруженные данные сохранены"
    }
}
