import Foundation
import MapLibre
import CoreLocation

/// Native MapLibre offline tile-pyramid packs include the complete style resources:
/// tiles, style document, sprites and glyphs (depending on the source).
/// Never use these APIs to bulk-cache a public tile server without permission.
@MainActor final class NativeOfflinePackStore: ObservableObject {
    @Published private(set) var status = "Сохранённые нативные пакеты"
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
        observer = NotificationCenter.default.addObserver(forName: .MLNOfflinePackProgressChanged,
                                                          object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in self?.onProgress(note.object as? MLNOfflinePack) }
        }
        errorObserver = NotificationCenter.default.addObserver(forName: .MLNOfflinePackError,
                                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.failed = true
                self?.status = (note.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error)?
                    .localizedDescription ?? "Ошибка скачивания тайлов"
            }
        }
        // Native offline storage is opened only when the map is requested.
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
                downloading = false
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
